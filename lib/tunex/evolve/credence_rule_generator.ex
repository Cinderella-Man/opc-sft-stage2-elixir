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
  You improve Credence — an Elixir AST linter — by writing/extending/fixing
  deterministic rules. You run inside the credence repo (your cwd). You have a
  LIMITED turn budget and the model is slow — be DECISIVE and EFFICIENT. Reading
  many files wastes the whole budget; don't.

  Follow this order strictly:

  1. STUDY THE GENERATED CODE in the "Row log" section below (the Elixir solution
     our local model produced, plus Credence's before/after fix trace). The most
     valuable signal is CLEAN, PASSING, NON-IDIOMATIC code — it compiles, passes
     its tests, trips no Credence issue, yet a human expert would deterministically
     rewrite it. Decide the SINGLE most promising deterministic rewrite, or that
     there is none. Micro-rules ARE welcome — a genuine deterministic improvement
     is worth a rule even if small (a Gate + mutation test validate it before it
     lands, so err toward proposing). But do NOT invent a rule for code that is
     already idiomatic and correct.

     Apply the idiomatic-Elixir lens hard: would an expert express this with
     `Enum.sum/all?/any?/map/reduce/with_index`, a comprehension, the pipe,
     pattern matching, or guards? This INCLUDES rewrites that change a function's
     PARAMETER SHAPE — e.g. a fixed-size list destructured only to aggregate its
     elements (`def f([a, b, c, d]), do: a + b + c + d`) can take the list
     directly and use `Enum.sum`. Do NOT dismiss an improvement merely because the
     bound variables are reused — consider restructuring the head. BUT a linter
     PRESERVES the computation exactly: never propose an ALGORITHMIC/mathematical
     optimization that relies on domain insight (e.g. "just check the largest
     element" instead of all of them) — that changes behavior-by-reasoning, not
     form, and is out of scope.

  2. The "Existing rules" section below lists EVERY rule by name (they are named
     for what they forbid). Scan it. If a rule already covers your idea → there is
     no opportunity. Otherwise Read AT MOST 2-3 rule files — only the ones whose
     names look related — to confirm novelty and learn the rule + test format
     (the phase dispatchers are lib/{pattern,syntax,semantic}.ex; helpers are
     lib/rule_helpers.ex / lib/function_matcher.ex). DO NOT browse all rules.

  3. If your idea is novel, deterministic, and SAFE (must never rewrite already-
     idiomatic correct code): implement the rule under lib/<phase>/, add a
     regression test under test/<phase>/ that FAILS without the rule (ideally also
     a must-NOT-fire-on-good-code case), run `mix test test/<phase>/<rule>_test.exs`
     until green, then run the full `mix test` ONCE. You cannot run git.

  4. Reserve `no_opportunity` for code that is genuinely ALREADY idiomatic. If you
     SEE a real idiomatic/deterministic gap but cannot land a clean,
     behavior-preserving rule for it, answer `gave_up: <pattern + snippet>` — it
     is escalated for a human to review (valuable, not a failure). Don't keep
     reading files just to be sure.

  End your FINAL message with EXACTLY ONE of these lines:
    DECISION: no_opportunity     (the code is genuinely already idiomatic)
    DECISION: gave_up: <pattern + minimal snippet>   (real gap, no clean rule landed)
    DECISION: <one-line description of the rule you added/extended/fixed>
  """

  @doc """
  Run the rule-gen agent for a completed row and route the outcome.
  `index` is the row index (drives RowLog). `clone` defaults to config.
  """
  def run(index, clone \\ Config.credence_clone()) do
    RowLog.filesync()
    log = File.read!(RowLog.path(index))
    prompt = build_prompt(log, Ledger.read(), rule_index(clone))

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

  @doc "Build the rule-gen prompt: task + rule index + ledger + raw row log."
  def build_prompt(row_log, ledger, rule_index) do
    ledger_section = if String.trim(ledger) == "", do: "none", else: ledger

    """
    #{@task}

    ## Existing rules (by name — scan this, do NOT read them all)
    #{rule_index}

    ## Dead-ends already tried (do NOT retry these)
    #{ledger_section}

    ## Row log
    #{row_log}
    """
  end

  @doc "Compact index of existing rules: `<phase>/<rule_name>` per line."
  def rule_index(clone) do
    for phase <- ~w(pattern syntax semantic),
        file <- Path.wildcard(Path.join(clone, "lib/#{phase}/*.ex")) do
      "#{phase}/#{Path.basename(file, ".ex")}"
    end
    |> Enum.sort()
    |> Enum.join("\n")
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
