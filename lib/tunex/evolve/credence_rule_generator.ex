defmodule Tunex.Evolve.CredenceRuleGenerator do
  @moduledoc """
  Drives the Claude-Code agent (Mimo) to generate/extend/fix a Credence rule,
  then routes the outcome by **tree state + the three-way DECISION** (plan #15).

  Runs on EVERY row (not gated on issues) — the most valuable rows are clean,
  passing, and non-idiomatic with zero issues. The agent reads/greps rule files
  off the filesystem itself (no rule-body injection); the prompt is just the
  row's raw log + the full `decisions.md` ledger + an open-ended task.

  Routing (the **Gate**, not the agent's self-report, decides commit/reject):

    | tree  | DECISION         | ledger | log        |
    | clean | no_opportunity   | —      | delete     |
    | clean | gave_up          | append | escalated/ |
    | clean | rule_proposal    | append | escalated/ |  (phantom)
    | dirty | (any)            | —/app  | Gate → commit / reject |

  The orchestrator (this module), not the agent, writes every ledger entry.
  Returns a result map: `%{outcome, usage, decision}` (usage → Budget in M5).
  """

  require Logger

  alias Tunex.{ClaudeCode, Config, RowLog}
  alias Tunex.Evolve.{Gate, Git, Ledger}

  @task ~S"""
  You are improving Credence — an Elixir AST linter — by writing, extending, or
  fixing rules. You are running inside the credence repo (your cwd). Read/Grep
  rule files under lib/{pattern,syntax,semantic} as needed; the phase
  dispatchers are lib/{pattern,syntax,semantic}.ex and helpers are
  lib/rule_helpers.ex / lib/function_matcher.ex.

  Below is the full raw log of ONE converted SFT row: the Elixir solution our
  local model produced, plus Credence's before/after fix trace (the
  APPLIED_RULES line). The most valuable signal is CLEAN, PASSING,
  NON-IDIOMATIC code — code that compiles, passes its tests, and trips no
  Credence issue, yet a human Elixir expert would deterministically rewrite.

  Task: do you see ANY opportunity, even the smallest, to deterministically
  improve this output code with a NEW or EXTENDED rule? Or any bug in an
  existing rule visible in the fix trace?

  If yes: implement it (Edit/Write under lib/), add a regression test under
  test/ that FAILS without your rule (ideally also a must-NOT-fire-on-good-code
  case), iterate with `mix test test/<phase>/<rule>_test.exs`, and run the full
  `mix test` once before finishing. Do NOT run git — you cannot commit.

  End your FINAL message with EXACTLY ONE of these lines:
    DECISION: no_opportunity
    DECISION: gave_up: <pattern + minimal snippet>
    DECISION: <one-line description of the rule you added/extended/fixed>
  """

  @doc """
  Run the rule-gen agent for a completed row and route the outcome.
  `index` is the row index (drives RowLog). `clone` defaults to config.
  """
  def run(index, clone \\ Config.credence_clone()) do
    RowLog.filesync()
    log = File.read!(RowLog.path(index))
    prompt = build_prompt(log, Ledger.read())

    case ClaudeCode.run(prompt, cwd: clone) do
      {:ok, result} ->
        route(index, clone, result)

      {:error, reason} ->
        Logger.error("[CredenceRuleGenerator] CC error: #{inspect(reason)} — discarding + escalating")
        Gate.discard(clone)
        Ledger.append("## row #{index} — cc_error\n#{inspect(reason)}")
        RowLog.escalate(index)
        %{outcome: :cc_error, usage: nil, decision: nil}
    end
  end

  @doc "Build the rule-gen prompt: task + ledger + raw row log."
  def build_prompt(row_log, ledger) do
    ledger_section = if String.trim(ledger) == "", do: "none", else: ledger

    """
    #{@task}

    ## Dead-ends already tried (do NOT retry these)
    #{ledger_section}

    ## Row log
    #{row_log}
    """
  end

  # ── Routing ─────────────────────────────────────────────────────────

  defp route(index, clone, result) do
    if tree_dirty?(clone) do
      route_dirty(index, clone, result)
    else
      route_clean(index, result)
    end
  end

  defp route_dirty(index, _clone, result) do
    case Gate.check() do
      {:ok, summary} ->
        :ok = Git.commit_and_push(index, summary, decision: decision_text(result.decision))
        save_transcript(index, result)
        RowLog.commit(index)
        %{outcome: :committed, usage: result.usage, decision: result.decision}

      {:reject, reason} ->
        # Gate already discarded the tree.
        Ledger.gate_reject(index, reason, decision_text(result.decision))
        RowLog.escalate(index)
        %{outcome: {:rejected, reason}, usage: result.usage, decision: result.decision}
    end
  end

  defp route_clean(index, result) do
    case result.decision do
      :no_opportunity ->
        RowLog.close(index)
        %{outcome: :no_opportunity, usage: result.usage, decision: result.decision}

      {:gave_up, detail} ->
        Ledger.gave_up(index, detail)
        RowLog.escalate(index)
        %{outcome: :gave_up, usage: result.usage, decision: result.decision}

      {:rule_proposal, _line} ->
        # Phantom: claimed a rule but produced no diff.
        Ledger.phantom(index, decision_text(result.decision))
        RowLog.escalate(index)
        %{outcome: :phantom, usage: result.usage, decision: result.decision}
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────

  defp tree_dirty?(clone) do
    {out, _} = System.cmd("git", ["status", "--porcelain"], cd: clone, stderr_to_stdout: true)
    String.trim(out) != ""
  end

  defp decision_text(:no_opportunity), do: "no_opportunity"
  defp decision_text({:gave_up, detail}), do: "gave_up: #{String.slice(detail, 0, 80)}"
  defp decision_text({:rule_proposal, line}), do: String.slice(line, 0, 80)

  defp save_transcript(index, result) do
    path = Path.join(Config.run_path("committed"), "#{index}.json")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(result.raw))
  end
end
