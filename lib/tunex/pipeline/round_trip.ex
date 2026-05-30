defmodule Tunex.Pipeline.RoundTrip do
  @moduledoc """
  Round-trip blacklist filter + the single per-row translation `Cache.put`.

  Runs the Elixir **reference** against the translated **tests** with a
  **fix-free runner** (`mix compile --warnings-as-errors` + `mix test` ONLY — no
  Credence/credo/format). That makes the verdict a pure function of
  `(reference, tests)`, immune to the evolving rule set. PASS is required before
  Solve.

  `ensure/2` is the row entry point. It consults the cache first; on a miss it
  translates, round-trip checks, **re-translates once** on failure, and writes
  exactly one `Cache.put` carrying the final `(payload, verdict, reason)`:

    * `{:ok, payload, :cache_hit | :fresh}` — reference passes; proceed to Solve
    * `{:blacklist, :roundtrip_fail | :untranslatable}` — skip the row
    * `{:error, reason}` — bubbled API error (not cached; Budget classifies)

  `:untranslatable` dominates `:roundtrip_fail` (a truncated re-translation can't
  be round-tripped at all).
  """

  require Logger

  alias Tunex.{Cache, Workspace}
  alias Tunex.Pipeline.Translate

  @doc """
  Resolve a row's translation through the cache + round-trip filter.
  `workspace` defaults to the single shared workspace.
  """
  def ensure(row, workspace \\ Workspace.default_path()) do
    key = Translate.cache_key(row)

    case Cache.get(key) do
      %{verdict: :ok} = rec ->
        Logger.info("[RoundTrip] cache hit (:ok)")
        {:ok, payload(rec), :cache_hit}

      %{verdict: :blacklist} = rec ->
        Logger.info("[RoundTrip] cache hit (:blacklist/#{rec.reason})")
        {:blacklist, rec.reason}

      nil ->
        fresh(row, key, workspace, false)
    end
  end

  # ── Fresh translation + round-trip (with one re-translate) ──────────

  defp fresh(row, key, workspace, retried?) do
    case Translate.translate(row) do
      {:error, reason} ->
        {:error, reason}

      :untranslatable ->
        blacklist(key, :untranslatable)

      {:ok, payload} ->
        if roundtrip_pass?(payload, workspace) do
          Cache.put(key, %{
            verdict: :ok,
            reason: nil,
            instruction: payload.instruction,
            test: payload.test,
            reference: payload.reference
          })

          {:ok, payload, :fresh}
        else
          if retried? do
            blacklist(key, :roundtrip_fail)
          else
            Logger.warning("[RoundTrip] reference failed tests — re-translating once")
            fresh(row, key, workspace, true)
          end
        end
    end
  end

  defp blacklist(key, reason) do
    Cache.put(key, %{verdict: :blacklist, reason: reason})
    {:blacklist, reason}
  end

  defp payload(rec), do: %{instruction: rec.instruction, test: rec.test, reference: rec.reference}

  # ── Fix-free runner (compile + test only) ───────────────────────────

  defp roundtrip_pass?(payload, workspace) do
    mod_path = Path.join(workspace, "lib/solution.ex")
    test_path = Path.join(workspace, "test/solution_test.exs")

    Workspace.clean_workspace(workspace)
    File.write!(mod_path, payload.reference)
    File.write!(test_path, ensure_exunit_case(payload.test))

    {compile_out, compile_code} =
      System.cmd("mix", ["compile", "--warnings-as-errors", "--force"],
        cd: workspace,
        stderr_to_stdout: true,
        env: [{"MIX_ENV", "test"}]
      )

    if compile_code != 0 do
      Logger.info("[RoundTrip] reference failed to compile:\n#{compile_out}")
      false
    else
      {test_out, test_code} =
        System.cmd("mix", ["test", "test/solution_test.exs", "--no-deps-check"],
          cd: workspace,
          stderr_to_stdout: true,
          env: [{"MIX_ENV", "test"}]
        )

      if test_code == 0 do
        Logger.info("[RoundTrip] reference PASSED tests")
        true
      else
        Logger.info("[RoundTrip] reference FAILED tests:\n#{test_out}")
        false
      end
    end
  end

  defp ensure_exunit_case(test_code) do
    if String.contains?(test_code, "use ExUnit.Case") do
      test_code
    else
      Regex.replace(
        ~r/(defmodule\s+\S+\s+do\s*\n)/,
        test_code,
        "\\1  use ExUnit.Case, async: false\n",
        global: false
      )
    end
  end
end
