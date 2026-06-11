defmodule Tunex.Preflight do
  @moduledoc """
  Boot preflight (plan #14): verify every precondition and **halt with
  actionable guidance** on any miss — never crash-loop.

  Order: static checks (clone/branch/CLI/secrets) → reconciliation → runtime
  checks (clean tree, implement-driver smoke, Mimo chat reachable, classify
  reachable, local solve endpoint reachable, credence HEAD suite green). The
  implement-driver smoke validates the agent end-to-end — for `:pi`, a one-shot
  `pi` session (CLI + Mimo provider extension + key + reachability) — so a broken
  rule-builder fails *boot*, not every row. The solve-endpoint check catches a
  down local Qwen server before the first paid row reaches the Solve stage.
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

    # Only the :pi driver needs an external CLI on PATH (the pi coding agent).
    # :llm runs entirely over the chat endpoint. CC is no longer an implement path.
    if Config.implement_driver() == :pi, do: pi_static!()

    check_secrets!()
  end

  defp pi_static! do
    unless System.find_executable("pi") do
      fail("""
      `pi` CLI not found on PATH (implement_driver: :pi).
      Fix: install it (npm i -g @earendil-works/pi-coding-agent) and ensure `pi`
      is on PATH, or set implement_driver: :llm to use the single-call driver.
      """)
    end

    ext = Config.pi_extension()

    unless File.exists?(ext) do
      fail("""
      pi provider extension not found at #{ext}.
      Expected pi/mimo_provider.ts in the project (registers Mimo for pi).
      """)
    end
  end

  defp check_secrets! do
    secret_providers = Application.get_env(:tunex, :secret_providers, %{})
    has_chat = get_in(secret_providers, [:xiaomi_mimo_2_5_pro, :headers, :Authorization]) != nil
    # The CC token is only needed for the (legacy) Claude Code path; :pi reuses
    # the chat key via the env-injected extension, :llm uses the chat endpoint.
    needs_cc = Config.implement_driver() == :claude_code
    has_cc = Application.get_env(:tunex, :claude_code_auth_token) != nil

    unless has_chat and (has_cc or not needs_cc) do
      fail("""
      Missing credentials in config/secrets.exs.
      Need: secret_providers.xiaomi_mimo_2_5_pro.headers.Authorization (chat)#{if needs_cc, do: "\n            claude_code_auth_token (Claude Code → Mimo)", else: ""}
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

    # The Gate + the implement agent (pi) run `mix test` directly in the clone, so
    # the clone's own deps must be present (not just the workspace's path-dep build).
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

    rule_gen_smoke!()
    mimo_chat_reachable!()
    solve_endpoint_reachable!()
    classify_endpoint_reachable!()
    credence_suite_green!(clone)
  end

  # The classifier (07 §3.1) carries the single hardest judgment and may be
  # pointed at a DISTINCT vendor (Anthropic Opus) with a separate, expirable
  # key. Unlike the remote-solve skip (which shares Mimo's already-proven host),
  # ALWAYS smoke whatever `stages.classify` resolves to so a stale/missing
  # classifier key fails *boot*, not mid-run (08 T0.4). One-token call.
  defp classify_endpoint_reachable! do
    provider = Config.provider_for(:classify)

    case LLM.for_stage(:classify, "reply with exactly: OK", "", max_tokens: 16) do
      {tag, _content, _usage} when tag in [:ok, :truncated] ->
        Logger.info("[Preflight] classify endpoint reachable (#{provider})")

      {:error, reason} ->
        fail("""
        Classifier endpoint unreachable / unauthorized: provider #{provider} → #{inspect(reason)}
        The classifier (stages.classify = #{provider}) did not answer. If this is a
        distinct vendor (e.g. :anthropic_opus), check its secret_providers header /
        OpenAI-compatible base_url. Or repoint: TUNEX_CLASSIFY_PROVIDER=xiaomi_mimo_2_5_pro
        """)

      other ->
        Logger.warning("[Preflight] classify endpoint returned #{inspect(other)} (continuing)")
    end
  end

  # Smoke the IMPLEMENT driver end-to-end so a broken agent fails *boot*, not
  # every row mid-run. :pi runs a one-shot pi session in a temp dir (proves CLI +
  # extension + Mimo key + Mimo reachable through pi); :llm is already covered by
  # the chat-endpoint smokes below (implement uses the same provider as classify).
  defp rule_gen_smoke! do
    if Config.implement_driver() == :pi, do: pi_smoke!()
  end

  defp pi_smoke! do
    tmp = Path.join(System.tmp_dir!(), "tunex_pi_smoke_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    try do
      case Tunex.Pi.run("Reply with exactly: OK", cwd: tmp, timeout_ms: 90_000) do
        {:ok, %{result_text: text}} ->
          Logger.info("[Preflight] pi smoke OK: #{String.slice(text, 0, 40)}")

        other ->
          fail("""
          pi agent smoke test failed: #{inspect(other)}
          Check: `pi` on PATH, pi/mimo_provider.ts, the Mimo Authorization header in
          config/secrets.exs (injected as TUNEX_MIMO_KEY), and that Mimo is reachable.
          Or set implement_driver: :llm to use the single-call driver.
          """)
      end
    after
      File.rm_rf!(tmp)
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

  # The Mimo paths are covered by cc_smoke!/mimo_chat_reachable!, but a LOCAL
  # solve endpoint (vLLM Qwen on the 3090) is a separate server that can be down
  # while Mimo is fine — and it only fails once the first row hits Solve, deep
  # into a paid run. Smoke-test it here, but ONLY for a local (localhost) URL so
  # we never burn a paid call: a remote solve provider shares Mimo's host, which
  # mimo_chat_reachable! already proved.
  defp solve_endpoint_reachable! do
    provider = Config.provider_for(:solve)
    url = Application.get_env(:tunex, :providers, %{}) |> get_in([provider, :url]) || ""

    if local_url?(url) do
      case LLM.for_stage(:solve, "reply with exactly: OK", "", max_tokens: 16) do
        {tag, _content, _usage} when tag in [:ok, :truncated] ->
          Logger.info("[Preflight] solve endpoint reachable (#{provider} @ #{url})")

        other ->
          fail("""
          Solve endpoint unreachable: provider #{provider} @ #{url} → #{inspect(other)}
          The configured solve stage uses a LOCAL model, but nothing answered there.
          Fix: start the vLLM/OpenAI-compatible Qwen server at #{url}, or point solve
          at the remote fallback: TUNEX_SOLVE_PROVIDER=xiaomi_mimo_2_5
          """)
      end
    end
  end

  defp local_url?(url),
    do: String.contains?(url, "localhost") or String.contains?(url, "127.0.0.1")

  # HEAD must be fully GREEN before the run — not just compile. A pre-existing
  # red suite (e.g. a landed rule missing a test) otherwise makes the Gate's
  # full-suite check reject EVERY new rule via :full_suite_red and poison
  # decisions.md with valid proposals (docs/10). Failing boot here turns that
  # silent stall into a loud, actionable halt, and guarantees a runtime
  # :full_suite_red is genuinely the new rule's regression.
  defp credence_suite_green!(clone) do
    {out, code} =
      System.cmd("mix", ["test"], cd: clone, stderr_to_stdout: true, env: [{"MIX_ENV", "test"}])

    unless code == 0 do
      tail = out |> String.split("\n") |> Enum.take(-40) |> Enum.join("\n")

      fail("""
      Credence HEAD suite is NOT green in #{clone} (mix test exit #{code}).
      A red HEAD makes the Gate reject every rule (:full_suite_red). Fix the clone
      (add the missing test / revert the offending rule), then re-run. Tail:
      #{tail}
      """)
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

  defp git(clone, args), do: System.cmd("git", args, cd: clone, stderr_to_stdout: true)

  @spec fail(String.t()) :: no_return()
  defp fail(guidance) do
    Logger.error("[Preflight] FAILED:\n#{guidance}")
    IO.puts(:stderr, "\n=== Tunex preflight failed ===\n#{guidance}")
    System.halt(1)
  end
end
