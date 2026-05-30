defmodule Tunex.Preflight do
  @moduledoc """
  Boot preflight (plan #14): verify every precondition and **halt with
  actionable guidance** on any miss — never crash-loop.

  Order: static checks (clone/branch/CLI/secrets) → reconciliation → runtime
  checks (clean tree, CC smoke test against Mimo, Mimo chat reachable, credence
  compiles). The CC smoke test validates base URL + token + model end-to-end so
  a bad rule-gen auth doesn't masquerade as "agent always gives up".
  """

  require Logger

  alias Tunex.{Config, LLM, Workspace}

  @branch "evolution"

  @doc "Run all checks + reconciliation. Halts the VM on any failure."
  def run! do
    Logger.info("[Preflight] starting")

    static_checks!()
    reconcile!()
    runtime_checks!()

    Logger.info("[Preflight] all checks passed")
    :ok
  end

  # ── Static checks ───────────────────────────────────────────────────

  defp static_checks! do
    clone = Config.credence_clone()

    unless File.dir?(clone) and File.dir?(Path.join(clone, ".git")) do
      fail("""
      Credence clone not found at #{clone}.
      Fix: git clone git@github.com:Cinderella-Man/credence.git #{clone}
      """)
    end

    branch = current_branch(clone)

    unless branch == @branch do
      fail("""
      Credence clone is on branch '#{branch}', expected '#{@branch}'.
      Fix: cd #{clone} && git checkout -b #{@branch} && git push -u origin #{@branch}
      """)
    end

    unless claude_available?() do
      fail("""
      `claude` CLI not found on PATH (or `claude --version` failed).
      Fix: install Claude Code (Node 18+) and ensure `claude` is on PATH.
      """)
    end

    check_secrets!()
  end

  defp check_secrets! do
    secret_providers = Application.get_env(:tunex, :secret_providers, %{})
    has_chat = get_in(secret_providers, [:xiaomi_mimo_2_5_pro, :headers, :Authorization]) != nil
    has_cc = Application.get_env(:tunex, :claude_code_auth_token) != nil

    unless has_chat and has_cc do
      fail("""
      Missing credentials in config/secrets.exs.
      Need: secret_providers.xiaomi_mimo_2_5_pro.headers.Authorization (chat)
            claude_code_auth_token (Claude Code → Mimo)
      Copy config/secrets.dummy.exs → config/secrets.exs and fill in real values.
      """)
    end
  end

  # ── Reconciliation ──────────────────────────────────────────────────

  @doc """
  Boot reconciliation: reset to HEAD (keep un-pushed commits, discard WIP),
  best-effort push catch-up, force-recompile credence.
  """
  def reconcile! do
    clone = Config.credence_clone()
    Logger.info("[Preflight] reconciling clone at #{clone}")

    git(clone, ["reset", "--hard", "HEAD"])
    git(clone, ["clean", "-fd"])
    set_git_identity(clone)

    local = rev(clone, "HEAD")
    origin = rev(clone, "origin/#{@branch}")
    {ahead, _} = git(clone, ["rev-list", "--count", "origin/#{@branch}..HEAD"])
    Logger.info("[Preflight] #{@branch} at #{local}, origin at #{origin}, #{String.trim(ahead)} ahead")

    case git(clone, ["push", "origin", @branch]) do
      {_o, 0} -> Logger.info("[Preflight] push catch-up OK")
      {o, c} -> Logger.warning("[Preflight] push catch-up failed (exit #{c}, non-fatal): #{o}")
    end

    # The Gate + the CC agent run `mix test` directly in the clone, so the
    # clone's own deps must be present (not just the workspace's path-dep build).
    System.cmd("mix", ["deps.get"], cd: clone, stderr_to_stdout: true)

    Workspace.setup()
    Workspace.recompile_credence()
    :ok
  end

  # ── Runtime checks ──────────────────────────────────────────────────

  defp runtime_checks! do
    clone = Config.credence_clone()

    {status, _} = git(clone, ["status", "--porcelain"])

    unless String.trim(status) == "" do
      fail("Clone tree not clean after reconciliation — unexpected. Inspect #{clone}.")
    end

    cc_smoke!()
    mimo_chat_reachable!()
    credence_compiles!(clone)
  end

  defp cc_smoke! do
    case Tunex.ClaudeCode.run("reply with exactly: OK", max_turns: 1) do
      {:ok, %{result_text: text}} ->
        Logger.info("[Preflight] CC smoke OK: #{text}")

      other ->
        fail("""
        Claude Code smoke test failed: #{inspect(other)}
        Check ANTHROPIC_BASE_URL/AUTH_TOKEN/MODEL (Mimo /anthropic endpoint) in config + secrets.
        """)
    end
  end

  defp mimo_chat_reachable! do
    case LLM.for_stage(:translate, "reply with exactly: OK", "", max_tokens: 16) do
      {tag, _content, _usage} when tag in [:ok, :truncated] ->
        Logger.info("[Preflight] Mimo chat reachable")

      {:error, reason} ->
        fail("""
        Mimo chat endpoint unreachable / unauthorized: #{inspect(reason)}
        Check the xiaomi_mimo_2_5_pro provider URL + secrets Authorization header.
        """)

      other ->
        Logger.warning("[Preflight] Mimo chat returned #{inspect(other)} (continuing)")
    end
  end

  defp credence_compiles!(clone) do
    {out, code} =
      System.cmd("mix", ["compile"], cd: clone, stderr_to_stdout: true, env: [{"MIX_ENV", "test"}])

    unless code == 0 do
      fail("Credence does not compile in #{clone}:\n#{out}")
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────

  # Set the clone's commit identity from config (noreply email — see config.exs)
  # so the bot's commits push cleanly even after a fresh re-clone.
  defp set_git_identity(clone) do
    identity = Config.git_identity()
    if identity[:name], do: git(clone, ["config", "user.name", identity[:name]])
    if identity[:email], do: git(clone, ["config", "user.email", identity[:email]])
    :ok
  end

  defp current_branch(clone), do: rev_parse(clone, ["--abbrev-ref", "HEAD"])
  defp rev(clone, ref), do: rev_parse(clone, [ref]) |> String.slice(0, 12)

  defp rev_parse(clone, args) do
    {out, _} = git(clone, ["rev-parse" | args])
    String.trim(out)
  end

  defp claude_available? do
    case System.cmd("claude", ["--version"], stderr_to_stdout: true) do
      {_o, 0} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp git(clone, args), do: System.cmd("git", args, cd: clone, stderr_to_stdout: true)

  defp fail(guidance) do
    Logger.error("[Preflight] FAILED:\n#{guidance}")
    IO.puts(:stderr, "\n=== Tunex preflight failed ===\n#{guidance}")
    System.halt(1)
  end
end
