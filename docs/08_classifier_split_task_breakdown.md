# 08 — Classifier-split: task breakdown

*Derived from [`07`](07_classifier_split_architecture.md) (the grilled design). This is the build plan:
ordered, dependency-aware, atomic tasks with acceptance criteria. Section refs (§) point back to `07`.*

> **Two repos.** Tasks tagged **[C]** live in the Credence clone (`../credence`); **[T]** in this repo
> (`:tunex`). The three **[C]** tasks ship as **one Credence PR** and unblock most of the Tunex work.

> **Golden rule from `07`:** every phase is gated on a **console-Δ measurement** — the console token bucket is
> the only ground truth (`mix tunex.budget`). The in-band ledger is now trustworthy too (Phase 0).

---

## Critical path (at a glance)

```
Phase 0  config + measurement basis        ─┐
Phase 1  [C] Credence PR (ast/covers?/revert-fix) ─┤→ both unblock everything downstream
Phase 2  log plumbing (sentinel/distill/APPLIED_RULES parse + grep→path)
Phase 3  classifier (prompt/parse/validate/option-shape/outcome-fork)
Phase 4  deterministic lanes (:reverted lane · novelty pre-check)
Phase 5  implementer (loop/seed/output-contract/naming/bounds)
Phase 6  router + outcomes + orchestrator wiring  ← ties 3·4·5 together, end-to-end
Phase 7  PROVE (land 2–3 rules) → teardown (delete harness + agentic gen)
Phase 8  MEASURE vs 4–8× target
```
Phases 0 and 1 are independent and can run in parallel. 2→3→4→5 layer on the log+Credence primitives. 6 is the
integration. **Do not delete anything (Phase 7) until 2–3 rules land end-to-end.**

---

## Phase 0 — Config + measurement basis (`07` §3.1, §11.0)

| # | Files | Task | Acceptance |
|---|---|---|---|
| **T0.1** | `lib/tunex/config.ex`, `config/config.exs` | Add `:classify` + `:implement` to `stages` + `stage_max_tokens` (both → `:xiaomi_mimo_2_5_pro`; floors TBD-tuning, start classify 16k / implement 16k). **Relax** the `when stage in [:translate, :solve]` guards in `provider_for/1` + `stage_max_tokens/1` to include the two new stages. | `LLM.for_stage(:classify, …)` / `(:implement, …)` resolve a provider + floor without raising; `TUNEX_CLASSIFY_PROVIDER` override works. |
| **T0.2** | `lib/tunex/llm.ex`, `lib/tunex/budget.ex` | Thread the **stage atom** `for_stage → call → Budget.record` (replace hardcoded `kind: :chat` in `maybe_record_usage`). | `mix tunex.usage` by-stage split shows `classify` / `implement` / `solve` separately. |
| **T0.3** | — (measurement) | Run one row, compare `mix tunex.usage` vs console Δ (`mix tunex.diag`). **Expect ≈1×** (not 20–50× — that undercount dies with the harness). | Documented ratio ≈1×; if not, investigate provider cache billing before proceeding. **No `summed_usage` port.** |

---

## Phase 1 — [C] Credence PR (`07` §3.7, §3.9, §6)

> One PR to `../credence`. **No revert-gate fix** — an earlier draft proposed one but it was based on a wrong
> premise: `Pattern.fix_with_trace` (`pattern.ex:52`) skips the whole pipeline unless the source compiles, so
> `:reverted` is **already** a clean compiling→non-compiling broken-rule signal. T1.3 is now an *optional*
> visibility tweak only.

| # | Files (credence) | Task | Acceptance |
|---|---|---|---|
| **T1.1** | `lib/mix/tasks/credence.ast.ex` (new) | `mix credence.ast` — reads code (stdin/file), prints **two views**: raw `inspect(Sourceror.parse_string!(code), pretty, limit: :infinity)` (incl. `{:__block__,_,[lit]}` wrappers) + layout-stripped. **Never** emit `normalize_sourceror_ast`/unwrapped form. | **Dogfood:** run on a snippet a known rule matches; dump matches what that rule's `check/2` pattern-matches. |
| **T1.2** | `lib/mix/tasks/credence.covers.ex` (new) | `mix credence.covers?` — reads a snippet, runs `Credence.fix` + `analyze`; prints `COVERED` iff `result.code != input` **or** `result.issues != []`, else `NOVEL`. Accepts **non-parsing** input (Credence.fix handles it). Names no rule. | A snippet an existing rule fixes → `COVERED`; a genuinely novel snippet → `NOVEL`. |
| **T1.3** *(optional)* | `lib/pattern.ex` (`apply_or_revert` revert branch) | **Visibility only:** call `RuleHelpers.log_diff(name, source, fixed)` in the revert branch (today only the keep-branch logs the diff) so a reverted fix's before/after lands in the row log for the implementer seed. **Do NOT touch the revert *logic*** — `:reverted` is already correct. | Reverted fixes show a before/after diff in the log; full credence suite green. Skippable — the seed can be reconstructed from solve-attempt code + `APPLIED_RULES`. |

---

## Phase 2 — Log plumbing: distillation + `APPLIED_RULES` (`07` §7, §Q1)

| # | Files | Task | Acceptance |
|---|---|---|---|
| **T2.1** | `lib/tunex/orchestrator.ex` | Emit `Logger.info("===SOLVE_BOUNDARY===")` **immediately before** the solve stage (unconditional, every row). | Sentinel present in every row log above the first `[Solve attempt 1]`. |
| **T2.2** | `lib/tunex/distill.ex` (new) | `distill/1`: drop everything **before** the sentinel (Python/translate/round-trip/reference); keep solve attempts + every `[Validator.run]`/`[credence_fix]`/`APPLIED_RULES` trace. Sentinel is an invariant — no absent-marker handling. | Distilled output contains zero reference-solution lines; contains all solve attempts + fix traces. |
| **T2.3** | `lib/tunex/applied_rules.ex` (new) | `parse/1`: row log → `[{module_atom, count \| :reverted}]` from `APPLIED_RULES:` lines (un-deduped across attempts). | Parses the real `APPLIED_RULES: [{Credence.Semantic.UnusedVariable, 1}, …]` format incl. `:reverted`. |
| **T2.4** | `lib/tunex/rule_paths.ex` (new) | `resolve/2`: module atom → `grep -rl "defmodule <Mod> do" lib/` in clone → exactly one `lib/<phase>/<name>.ex`; test glob `test/<phase>/<name>*_test.exs`. 0 or >1 matches → error. | Resolves a known module to its file + ≥1 test path; errors on a bogus module. |

---

## Phase 3 — Classifier (`07` §3, §4)  · *depends: T0.1, T2.2, T2.3*

| # | Files | Task | Acceptance |
|---|---|---|---|
| **T3.1** | `lib/tunex/classify/prompt.ex` (new) | Build prompt: distilled log + `APPLIED_RULES` (path-resolved closed set) + whole ledger + convention prefixes (`no_/prefer_/avoid_`). **Outcome-forked lens** (solved → idiomatic residual; failed → unfixed-issue) sharing one output-contract core. ~200-tok system prompt. | Prompt contains the closed set, ledger, prefixes; lens matches solve outcome; no rule-name index. |
| **T3.2** | `lib/tunex/classify/parser.ex` (new) | Parse marker output (`===DECISION===`/`===RULE_NAME===`\|`===PROPOSED_NAME===`/`===PHASE===`/`===BEFORE===`/`===AFTER===`\|`===CHECK_ONLY===`/`===RATIONALE===`/`===END===`) → struct. | Round-trips a valid spec; tolerant of stray whitespace. |
| **T3.3** | `lib/tunex/classify.ex` (new) | Orchestrate: option-shaping (empty closed set → no BUGFIX); `LLM.for_stage(:classify)`; validation gates (decision ∈ offered; `rule_name` ∈ closed set **and** grep-resolves; `proposed_name` snake_case; **phase-conditional** `before` parse/compile per §3.8; `before`/`after` full `defmodule`; `after` over-cap → check-only). **One re-ask** (full re-send + specific error) → else `classifier_errors/`. | Valid spec → struct; each invalid-spec class → one re-ask → `classifier_errors/` on second failure. |

---

## Phase 4 — Deterministic lanes (`07` §3.7, §3.9)  · *depends: T1.2, T1.3, T2.3, T2.4*

| # | Files | Task | Acceptance |
|---|---|---|---|
| **T4.1** | router (see T6.1) | **`:reverted` lane** — BEFORE the classifier: if `APPLIED_RULES` has any `{Mod, :reverted}` → route to implementer **bugfix mode** (culprit `Mod`, broke-compile sub-shape), **skip classifier**. First culprit only. Works against current Credence (no gate fix). | A row with a `:reverted` culprit never calls the classifier; goes straight to bugfix. |
| **T4.2** | `lib/tunex/novelty.ex` (new) | **Novelty pre-check** — for `POTENTIAL_NEW_RULE` only: shell `mix credence.covers?` in clone on `before`. `COVERED` → `duplicate/`, skip implementer. `NOVEL` → proceed. (Runs after the classifier, before naming/implementer.) | A `before` an existing rule covers → `duplicate/`, no implementer run; novel → proceeds. |

---

## Phase 5 — Implementer (`07` §5, §6)  · *depends: T1.1, T2.4*

| # | Files | Task | Acceptance |
|---|---|---|---|
| **T5.1** | `lib/tunex/implement/seed.ex` (new) | **Phase-conditional seed**: pattern/semantic → AST dumps (shell `mix credence.ast` on before+after) + rule/test exemplar; syntax → templated before/after module strings + `Credence.Syntax.Rule` exemplar (no AST dump). Bugfix → + offending rule full source + all globbed tests. Path-convention line. | Seed for each phase contains the right primitives; never runs the AST helper on a syntax (non-parsing) snippet. |
| **T5.2** | `lib/tunex/implement/output.ex` (new) | **File-keyed parser**: generic `===KEY===`→`%{key=>content}`. New = `RULE`/`CHECK_TEST`/`FIX_TEST`(iff fixable). Bugfix = `RULE` + `TEST:<path>` (each ⊆ glob, modify-only; reject new/renamed). | New-mode + bugfix-mode samples parse; out-of-glob `TEST:` path rejected. |
| **T5.3** | `lib/tunex/implement.ex` (new) | **Solver loop in the clone**: emit → write files → focused `mix test` → trimmed `Report.format_errors` feedback → **flat** retry prompt (seed + last attempt + last failures) → retry ≤ `rule_gen_max_retries`. **Local size ceiling** (`rule_gen_input_ceiling`/`_output_ceiling`) → abort to `gave_up`. No tools, no token breaker. | Lands a rule on a happy-path spec; aborts on a pathological oversize row; writes only to clone. |
| **T5.4** | `lib/tunex/implement/naming.ex` (new) | Orchestrator-owned naming: `proposed_name` → first free suffix (`_2`, module `Name2`) → final module + exact paths handed to the loop. | Collision with an existing name → `_2` variant; loop receives final paths, never picks them. |
| **T5.5** | `config/config.exs`, `lib/tunex/config.ex` | Knobs: `rule_gen_max_retries` (~5), `rule_gen_input_ceiling`, `rule_gen_output_ceiling`. | Readable via `Config`; defaults present. |

---

## Phase 6 — Router + outcomes + orchestrator wiring (`07` §2, §8, §Q10)  · *depends: 3, 4, 5*

| # | Files | Task | Acceptance |
|---|---|---|---|
| **T6.1** | `lib/tunex/evolve/router.ex` (new — replaces agentic routing) | The spine: parse `APPLIED_RULES` → `:reverted` lane (T4.1) **else** classify (T3.3) → `NO_ACTION`\|BUGFIX\|`POTENTIAL_NEW_RULE`(→novelty T4.2→naming T5.4) → implementer (T5.3) → **Gate (unchanged)** → commit + `Workspace.recompile_credence/1`, or reject. One decision per row. | End-to-end on a real row: each decision path reaches its correct outcome dir / commit. |
| **T6.2** | `lib/tunex/row_log.ex` | `close/1`'s delete → **move to `no_action/`**; add `duplicate/1` + `classifier_errors/1` (same shape as `escalate/1`). | Each outcome moves the log to the right dir; nothing deleted. |
| **T6.3** | `lib/tunex/evolve/ledger.ex` + callers | Write-sites move into the router: **implementer-failed + gate_reject only**. **Retire `phantom`.** `duplicate/` + `classifier_errors/` do **not** ledger. | Ledger appends on the two failure paths only; stays near-empty on a clean run. |
| **T6.4** | `lib/tunex/orchestrator.ex` | Call the router (not `CredenceRuleGenerator`) on **every row that reached solve (success AND failed)**; pass the solve outcome (for the lens fork). | Failed-solve rows reach the classifier with the failed lens. |
| **T6.5** | `lib/tunex/row_log.ex` (`ensure_ready`), `lib/mix/tasks/tunex.reset.ex` | Create + reset `no_action/`, `duplicate/`, `classifier_errors/`. | `mix tunex.reset` clears them; boot creates them. |

---

## Phase 7 — Prove, then tear down (`07` §9)

| # | Files | Task | Acceptance |
|---|---|---|---|
| **T7.1** | — | **PROVE:** run live until **2–3 rules land + push** end-to-end (new + bugfix + ideally a `:reverted`-lane fix). | Rules on `evolution`; Gate + recompile + outcomes all correct in logs. |
| **T7.2** | delete `lib/tunex/claude_code.ex`; gut agentic `credence_rule_generator.ex` (`@task`/`build_prompt`/`route`); remove `max_turns` (config+plumbing) + per-session token breaker (`runaway_ceiling_usd`) | **Only after T7.1.** No harness, no flag fallback. | `mix test` + boot green with the harness gone; no dangling refs. |

---

## Phase 8 — Measure (`07` §11.6)

| # | Task | Acceptance |
|---|---|---|
| **T8.1** | Measure combined cut vs the **4–8×** target: console Δ/row (per-stage via T0.2), **and committed rows/day must NOT drop**. | Documented Δ vs target; rule-yield not regressed. If short of 4–8× → the §15 follow-ups (marker-fencing distillation, etc.). |

---

## Independent / deferred (not on the critical path)

- **`credence_failed` off-machine escalation archive** — **UNBUILT** (doc-06 design; no code). Orthogonal —
  failures already land in local `escalated/`. Land any time, or never. Not a prereq.
- **Tuning items (`07` §14)** — NOT tasks; live iteration once the pipeline runs: classifier prompt wording +
  single-issue-isolation discipline; the two outcome-lenses; `after`-cap threshold; `rule_gen_max_retries`;
  the input/output ceilings; `no_action/` retention.
- **§15 "not this round"** — full marker-fencing distillation; automated second-opinion shadow;
  focused-agentic escalation; Sourceror cheatsheet; migrating existing rules to split tests.

---

## The one load-bearing unknown (call it out, measure it first)

Whether a **one-shot Mimo-pro classifier** can make the "clean-but-non-idiomatic" call at acceptable precision
**without tools** is empirical, not structural — settled only by the live `no_action/` human audit (`07` §12),
which is the first thing to watch once Phase 6 runs. Everything else is built to make this the *only* real
unknown.
