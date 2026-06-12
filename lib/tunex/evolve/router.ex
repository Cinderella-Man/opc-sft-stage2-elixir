defmodule Tunex.Evolve.Router do
  @moduledoc """
  The classifier-split spine (07 §2/§6.1; 08 T6.1) — replaces the agentic
  `CredenceRuleGenerator`. Per row that reached solve:

      parse APPLIED_RULES
        ├─ :reverted culprit? ─► implementer BUGFIX (broke-compile), SKIP classifier
        └─ else ─► CLASSIFY
                     ├─ NO_ACTION          → no_action/
                     ├─ SWITCH_PROPOSAL    → switch_proposals/  (record, no build)
                     ├─ BUGFIX_RULE        → implementer bugfix → Gate
                     └─ POTENTIAL_NEW_RULE → novelty (covers)
                                              ├─ COVERED → duplicate/
                                              └─ NOVEL → equiv (trichotomy)
                                                   ├─ DIVERGES → behaviour_diverged/
                                                   ├─ REPAIR   → build (repair sub-mode) → Gate
                                                   └─ EQUIVALENT(minset) → build → Gate

  The implementer (Phase 5) + Gate + outcome dirs are wired here. `classify`/
  `implement` are injectable for testing (the LLM-driven stages).

  Returns `%{outcome, decision}` (the orchestrator logs it).
  """

  require Logger

  alias Tunex.{AppliedRules, Budget, Config, Credence, Equiv, Novelty, RowLog, RulePaths, SwitchProposal, TransientAttempts}
  alias Tunex.Classify
  alias Tunex.Implement
  alias Tunex.Implement.Naming
  alias Tunex.Evolve.{Gate, Git, Ledger}

  def run(index, solve_outcome, clone \\ Config.credence_clone(), opts \\ []) do
    RowLog.filesync()
    log = File.read!(RowLog.path(index))
    entries = AppliedRules.parse(log)

    case AppliedRules.reverted(entries) do
      [culprit | _] -> reverted_lane(index, culprit, log, clone, opts)
      [] -> classify_and_dispatch(index, log, solve_outcome, entries, clone, opts)
    end
  end

  # ── :reverted deterministic bugfix lane (07 §3.9) ───────────────────────

  defp reverted_lane(index, culprit, log, clone, opts) do
    Logger.info("[Router] :reverted culprit #{inspect(culprit)} — deterministic bugfix, no classifier")

    case RulePaths.resolve(culprit, clone) do
      {:ok, r} ->
        ctx = bugfix_ctx(r, :broke_compile, nil, log, clone)
        build_and_gate(index, ctx, "bugfix(broke_compile): #{r.rule_path}", clone, opts)

      {:error, reason} ->
        Logger.warning("[Router] :reverted culprit unresolved: #{inspect(reason)}")
        Ledger.gave_up(index, "reverted culprit unresolved: #{inspect(reason)}")
        RowLog.escalate(index)
        outcome(:gave_up, nil)
    end
  end

  # ── Classify + dispatch ─────────────────────────────────────────────────

  defp classify_and_dispatch(index, log, solve_outcome, entries, clone, opts) do
    classify = Keyword.get(opts, :classify, &Classify.run/3)
    closed = AppliedRules.modules(entries)

    case classify.(log, solve_outcome, closed_set: closed, clone: clone) do
      {:ok, spec} ->
        dispatch(index, spec, log, clone, opts)

      {:error, {:classifier_errors, reason, _raw}} ->
        # A transient LLM timeout / fatal auth error is handled don't-consume /
        # halt (Fix 1); a genuine malformed-spec falls through to :other.
        case rulegen_abort(index, reason, clone, opts, false) do
          :other ->
            Logger.warning("[Router] classifier error: #{inspect(reason)}")
            RowLog.classifier_errors(index)
            outcome(:classifier_error, nil)

          out ->
            out
        end
    end
  end

  defp dispatch(index, %{decision: :no_action}, _log, _clone, _opts) do
    RowLog.no_action(index)
    outcome(:no_action, :no_action)
  end

  defp dispatch(index, %{decision: :switch_proposal} = spec, _log, _clone, _opts) do
    SwitchProposal.record(index, spec)
    RowLog.switch_proposal(index)
    outcome(:switch_proposal, :switch_proposal)
  end

  defp dispatch(index, %{decision: :bugfix_rule} = spec, log, clone, opts) do
    {:ok, r} = RulePaths.resolve(spec.rule_name, clone)
    ctx = bugfix_ctx(r, :over_fire, spec, log, clone)
    build_and_gate(index, ctx, "bugfix(over_fire): #{r.rule_path}", clone, opts)
  end

  defp dispatch(index, %{decision: :potential_new_rule} = spec, log, clone, opts) do
    # docs/10: the synthetic-`before` covers check is UNSOUND as a SKIP gate — it
    # flags rules that never fired on the real code (a check re-run on a tidied-up
    # snippet), which suppressed genuinely-novel rules. If the idiom survived this
    # row's solve (which already ran Credence.fix), it was NOT handled in practice
    # → build it. `covers` is kept only as a NON-BLOCKING overlap note.
    novelty = Keyword.get(opts, :novelty, &Novelty.check/2)

    if novelty.(spec.before, clone) == :covered do
      Logger.info("[Router] note: an existing rule may overlap this idiom (non-blocking) — building anyway")
    end

    new_rule_after_equiv(index, spec, log, clone, opts)
  end

  defp new_rule_after_equiv(index, spec, log, clone, opts) do
    equiv = Keyword.get(opts, :equiv, fn s -> Equiv.check(s, clone: clone) end)

    case equiv.(spec) do
      {:diverges, detail} ->
        Logger.info("[Router] equiv: DIVERGES (#{detail}) — behaviour_diverged")
        RowLog.behaviour_diverged(index)
        outcome(:behaviour_diverged, :potential_new_rule)

      verdict ->
        build_new_rule(index, spec, verdict, log, clone, opts)
    end
  end

  # ── Build a NEW rule (scaffold → seed → implementer → Gate) ─────────────

  defp build_new_rule(index, spec, verdict, log, clone, opts) do
    {repair?, repair_evidence} =
      case verdict do
        {:repair, ev} -> {true, ev}
        _ -> {false, nil}
      end

    minimal_set =
      case verdict do
        {:equivalent, set} -> set
        _ -> []
      end

    case Naming.resolve_and_scaffold(spec.proposed_name, spec.phase, clone) do
      {:ok, scaffold} ->
        ctx = new_ctx(spec, scaffold, minimal_set, repair?, repair_evidence, log, clone)
        build_and_gate(index, ctx, "new(#{spec.phase}): #{scaffold.snake}", clone, opts)

      {:error, reason} ->
        Logger.warning("[Router] scaffold failed: #{inspect(reason)}")
        # No files written yet on a gen.rule abort — nothing to discard.
        Ledger.gave_up(index, "scaffold failed: #{inspect(reason)}")
        RowLog.escalate(index)
        outcome(:gave_up, :potential_new_rule)
    end
  end

  # ── Shared: run implementer, then Gate ──────────────────────────────────

  defp build_and_gate(index, ctx, decision_text, clone, opts) do
    implement = Keyword.get(opts, :implement, &Implement.run/1)

    case implement.(ctx) do
      {:ok, _result} ->
        gate(index, decision_text, clone)

      {:gave_up, reason} ->
        # A transient LLM timeout / fatal auth error is handled don't-consume /
        # halt (Fix 1) — both still discard the dirty clone. A genuine give-up
        # (retries_exhausted, ceiling, scaffold) falls through to :other.
        case rulegen_abort(index, reason, clone, opts, true) do
          :other ->
            Logger.info("[Router] implementer gave_up: #{inspect(reason)}")
            # The generator wrote stubs BEFORE the loop (new mode), so discard the
            # clone tree on every post-scaffold abort (07 §5.0 dirty-tree path).
            Gate.discard(clone)
            Ledger.gave_up(index, "implementer gave_up: #{inspect(reason)}")
            RowLog.escalate(index)
            outcome(:gave_up, nil)

          out ->
            out
        end
    end
  end

  # ── Rule-gen LLM-error handling (docs/10 Fix 1) ─────────────────────────

  # Classify a (possibly exhausted) rule-gen error. For a transient timeout:
  # don't-consume (`:transient_abort`) until the per-row limit, then give up to
  # `too_slow/`. For a fatal auth error: graceful halt (symmetric with
  # orchestrator `stage/2`). A non-LLM error returns `:other` — the caller keeps
  # its existing escalate / classifier_errors path. `discard?` is true on the
  # implement path (a dirty scaffold/bugfix tree must be reverted).
  defp rulegen_abort(index, reason, clone, opts, discard?) do
    case rulegen_error_class(reason) do
      :other ->
        :other

      :fatal ->
        if discard?, do: Gate.discard(clone)
        shutdown = Keyword.get(opts, :shutdown, &Tunex.shutdown/1)
        shutdown.({:fatal_api, reason})
        outcome(:fatal_abort, nil)

      :transient ->
        if discard?, do: Gate.discard(clone)
        bump = Keyword.get(opts, :transient_attempts, &TransientAttempts.bump/1)
        n = bump.(index)

        if n >= Config.transient_row_limit() do
          Logger.warning("[Router] transient timeout — row #{index} hit limit (#{n}) → too_slow")
          RowLog.too_slow(index)
          outcome(:too_slow, nil)
        else
          Logger.info("[Router] transient timeout — row #{index} (attempt #{n}) → not consuming")
          RowLog.transient(index)
          outcome(:transient_abort, nil)
        end
    end
  end

  # The Router has already destructured `{:llm_error, inner}` out of both
  # `{:classifier_errors, reason, _}` and `{:gave_up, reason}`, so one clause
  # covers both stages. Anything else (validation re-ask, retries_exhausted,
  # ceilings, scaffold) is `:other`.
  defp rulegen_error_class({:llm_error, inner}), do: Budget.classify_error(inner)
  # A pi/agent timeout (wall or idle) is infra/transient, NOT a dead-end idea —
  # don't poison decisions.md with it; re-run next pass (bounded by the per-row
  # too_slow limit) like any transient (docs/10).
  defp rulegen_error_class({:pi, r}) when r in ["timeout", "idle_timeout"], do: :transient
  defp rulegen_error_class({:cc, r}) when r in ["timeout", "idle_timeout"], do: :transient
  defp rulegen_error_class(_), do: :other

  defp gate(index, decision_text, clone) do
    case Gate.check(clone) do
      {:ok, summary} ->
        :ok = Git.commit_and_push(index, summary, decision: decision_text)
        Tunex.Workspace.recompile_credence()
        RowLog.commit(index)
        outcome(:committed, decision_text)

      {:reject, reason} ->
        # Gate already discarded the working tree.
        Ledger.gate_reject(index, reason, decision_text)
        RowLog.escalate(index)
        outcome({:rejected, reason}, decision_text)
    end
  end

  # ── ctx builders (the implementer seed ingredients) ─────────────────────

  defp new_ctx(spec, scaffold, minimal_set, repair?, repair_evidence, log, clone) do
    %{
      mode: :new,
      phase: spec.phase,
      spec: %{before: spec.before, after: spec.after, rationale: spec.rationale, assumptions: spec.assumptions},
      scaffold: scaffold,
      scaffold_files: scaffold.files,
      clone: clone,
      minimal_set: minimal_set,
      repair?: repair?,
      repair_evidence: repair_evidence
    }
    |> add_ast(spec)
    |> add_diagnostic(spec, log)
  end

  defp add_ast(%{phase: :syntax} = ctx, _spec), do: ctx

  defp add_ast(ctx, spec) do
    ctx
    |> Map.put(:ast_before, Credence.ast(spec.before, ctx.clone))
    |> Map.put(:ast_after, Credence.ast(spec.after, ctx.clone))
  end

  defp add_diagnostic(%{phase: :semantic} = ctx, _spec, log) do
    Map.put(ctx, :real_diagnostic, extract_diagnostic(log))
  end

  defp add_diagnostic(ctx, _spec, _log), do: ctx

  defp bugfix_ctx(r, sub_shape, spec, log, clone) do
    test_files = Map.new(r.test_paths, fn rel -> {rel, read_rel(clone, rel)} end)

    %{
      mode: :bugfix,
      phase: String.to_atom(r.phase),
      spec: bugfix_spec(spec),
      clone: clone,
      minimal_set: [],
      repair?: false,
      bugfix: %{
        module: r.module,
        rule_path: r.rule_path,
        rule_src: read_rel(clone, r.rule_path),
        test_files: test_files,
        sub_shape: sub_shape
      }
    }
    |> add_ast_bugfix(spec, r)
    |> add_diagnostic_bugfix(r, log)
  end

  defp bugfix_spec(nil), do: %{before: "(see the row log / reverted diff)", after: "(repair the fix)", rationale: "broke compilation (:reverted)", assumptions: []}
  defp bugfix_spec(spec), do: %{before: spec.before, after: spec.after, rationale: spec.rationale, assumptions: spec.assumptions}

  defp add_ast_bugfix(ctx, nil, _r), do: ctx
  defp add_ast_bugfix(%{phase: :syntax} = ctx, _spec, _r), do: ctx
  defp add_ast_bugfix(ctx, spec, _r) do
    ctx
    |> Map.put(:ast_before, Credence.ast(spec.before, ctx.clone))
    |> Map.put(:ast_after, Credence.ast(spec.after, ctx.clone))
  end

  defp add_diagnostic_bugfix(%{phase: :semantic} = ctx, _r, log), do: Map.put(ctx, :real_diagnostic, extract_diagnostic(log))
  defp add_diagnostic_bugfix(ctx, _r, _log), do: ctx

  # ── Helpers ──────────────────────────────────────────────────────────────

  # Pull the real `%{message, position, severity, ...}` from the last
  # `[credence_fix] no rule matched diagnostic: %{…}` line (T1.3b).
  defp extract_diagnostic(log) do
    Regex.scan(~r/no rule matched diagnostic:\s*(%\{.*\})/, log)
    |> List.last()
    |> case do
      [_, diag] -> diag
      _ -> nil
    end
  end

  defp read_rel(clone, rel) do
    case File.read(Path.join(clone, rel)) do
      {:ok, content} -> content
      _ -> ""
    end
  end

  defp outcome(o, d), do: %{outcome: o, decision: d}
end
