# Tunex log-review fixes (escalated + 3 other buckets)

## Context
User ran the v2 pipeline 24/7 (local Qwen solver) and collected per-row dead-end logs in
`logs/{escalated,behaviour_diverged,classifier_errors,duplicate}/`. PRIMARY GOAL = more/better
Credence rules; the dataset run is just a workload surfacing weaknesses. Reviewing every bucket shows
the dead-ends are dominated by **tunex plumbing that discards rows which already had a
classifier-approved rule** (lost rule opportunities), plus one recurring semantic theme — **module
attributes before `defmodule`** — whose true root cause is a *miscategorized Credence rule* (a
Credence problem, documented below, NOT fixed here).

The run used credence branch **`evolution`** (only branch carrying the `credence.covers`/`credence.equiv`
tasks). Confirmed facts (re-verified against the code 2026-06-10): `Tunex.shutdown` → `System.halt(1)`
(hard halt, no supervisor restart, by design); `Progress.mark_done` is unconditional after rule-gen; all
four model stages (translate/solve/**classify/implement**) funnel through the single `Tunex.LLM.call/3`
(`Req.post`), which wraps timeouts as `{:error, {:network, _}}`. **NB: `CLAUDE.md` is stale** — it still
describes rule-gen as a Claude Code CLI subprocess; the classifier-split rebuild deleted that and
`classify.ex`/`implement.ex` now both call `LLM.for_stage/3`. The single LLM timeout is a hardcoded
`receive_timeout: 600_000` (10 min) in `llm.ex:54`, applied to every provider.

**Root-cause correction (2026-06-10):** the 26/28 + classifier_error "timeouts" are NOT network blips —
they are slow `implement` generations cut off at the 10-min ceiling. That reframes Fix 1 entirely
(primary fix = raise the timeout, not retry). Evidence + revised design in Fix 1 below.

## Implementation status — DONE 2026-06-10 (code landed; probe pending)
All code in "Concrete steps" is implemented; `mix test --exclude integration` = **82 tests, 0 failures**;
`mix compile --warnings-as-errors` clean. Files touched: `config/config.exs` + `config.ex` (knobs),
`llm.ex` (timeout knob), `parser.ex` (public `strip_outer_fences/1`), `implement/output.ex` +
`classify/parser.ex` (strip every block), `implement/seed.ex` (no-fence contract line), `row_log.ex`
(`transient/` + `too_slow/` dirs + movers), **new** `transient_attempts.ex`, `evolve/router.ex`
(`rulegen_error_class` + `rulegen_abort` → transient/fatal/too_slow), `orchestrator.ex` (don't-consume +
breaker + `breaker_step/3`), `classify/prompt.ex` (`@phase_taxonomy`).
- **Deviations (minor):** (a) the per-row counter is injectable via `opts[:transient_attempts]` and the
  halt via `opts[:shutdown]` (cleaner test seams than stubbing the modules); (b) `tunex.reset` needed NO
  change — its `rm_rf var/run` wipes `transient_attempts.json` and `outcome_dirs/0` now recreates
  `transient/` + `too_slow/`; (c) the breaker is a **pure** `Orchestrator.breaker_step/3` (unit-tested);
  the full GenServer don't-consume wiring is covered indirectly (RouterTest), since booting the
  Orchestrator runs Preflight + dataset load.
- **Test gap (accepted):** the *implement-path* transient/`Gate.discard` branch isn't unit-tested
  (reaching `build_and_gate` needs a real Credence clone for scaffold); it shares `rulegen_abort/5` with
  the classify path, which IS fully tested (transient_abort / too_slow / fatal / other).
- **STILL PENDING (not code):** the **30-min probe** to measure the real completion-time ceiling and set
  the production `budget.llm_timeout_ms` (currently the probe value `1_800_000`). See Verification.

## What the buckets actually contain (reviewed ALL files)
| bucket | n | terminal verdict | root cause |
|---|---|---|---|
| escalated | 26/28 | `gave_up {:llm_error,{:network,…:timeout}}` | **NOT a blip** — the `implement` call ran to the 600s ceiling (Mimo succeeded earlier in the SAME row 28/28) → slow generation cut off → permanent give-up. **Fix = raise the timeout.** |
| escalated | 2/28 | `gave_up {:retries_exhausted, …unexpected token "`"}` | implementer wrote a rule `.ex` starting with ```` ```elixir ```` → won't compile (it was trying to build the syntax/semantic attr-rule) |
| classifier_errors | 1/1 | `classifier error {:llm_error,{:network,…:timeout}}` | SAME 600s cut-off, hit once in Classify |
| behaviour_diverged | 4/5 | `equiv: DIVERGES (after-does not compile…)` | model proposed a **non-compiling AFTER** — phases verified: syntax(20700,80015), semantic(41620), **pattern(56907)**. Only the pattern one is the Fix-3 mis-phase; the other 3 are a broken-AFTER problem the taxonomy won't fix. All dead-end cheaply at the LOCAL `equiv` check (no Mimo spend). |
| behaviour_diverged | 1/5 | `DIVERGES (input=[] before={:ok,false} after={:ok,true})` | (59586, pattern) **genuine** divergence — correct rejection, no action |
| duplicate | ~28 | `novelty: COVERED — duplicate` | a SUBSET are false dupes (the attr-rule below blocks generation); the REST are legitimately covered — no action |

## In-scope fixes (tunex)

### Fix 1 — Raise the LLM timeout (escalated 26/28 + classifier_errors); the rest is rare-residual resilience
**Root cause — re-investigated 2026-06-10; this REPLACES the original "transient blip → retry" reading.**
The timeouts are not network blips; they are slow `implement` generations cut off at the 10-min ceiling.
Measured from the logs:
- All 28 timed-out calls ran to the **600s ceiling** (`llm.ex:54 receive_timeout: 600_000`): 600,108–
  605,006 ms. **None failed fast** — no sub-minute errors.
- **28/28** of those rows had a SUCCESSFUL Mimo call earlier in the same row; **25/28** had both a Mimo
  success AND the terminal timeout in the same log → the network, server, and auth cookie were demonstrably
  fine. This is not a dead connection.
- The cut-offs were **312:1 in `implement`** (the hardest stage — writing the rule under the `[1m]`
  context), essentially never in classify/translate.
- Successful Mimo calls: min 5.9s · avg 69s · **max 270s (4.5 min)** — but that 4.5-min ceiling is a
  **selection artifact**: anything that would take >10 min was censored by the timeout and can never appear
  in the success sample.

Conclusion: Mimo was working; the hard rule-writing generation simply takes **longer than 10 minutes** and
we hang up on it. (Cost note: billing is by **tokens, not wall-clock** — a 15-min call costs the same as a
3-min call for equal output. Cutting off at 10 min means we *paid for* the reasoning tokens already
generated and threw the answer away. A generous timeout has **no token-budget downside**, only throughput.)

Design (decided 2026-06-10):

- **PRIMARY FIX — raise the timeout.** Replace the hardcoded `600_000` with a config knob
  `budget.llm_timeout_ms`. Single global value is fine (Qwen maxes at 41s, so a longer ceiling can't hurt
  it). Expected to recover ~26/28 by itself. **First run a 30-min probe** (`1_800_000`) over the 28
  timed-out rows to find the TRUE completion-time ceiling (**30, not 20**, to avoid re-censoring the data:
  a 20-min cap would again report "timeout" on anything in the 22–25-min tail). Then set the production
  value to the observed ceiling **+ ~30% margin**. `LLM.call` already logs `elapsed_ms` (and `Diag` records
  it), so the probe yields the real distribution directly.

- **NO retry.** The original plan's transient-retry on classify/implement is **DROPPED**. Its only
  justification was "absorb a brief blip", but these are slow completions — a retry just times out again
  (6×10min = 60min wasted, then give up anyway). Genuine blips (none observed here) are already covered by
  don't-consume below: the row simply re-runs next pass, free (translate cached, solve local Qwen).
  `stage/2`'s **existing** retry for translate/solve is untouched (not implicated; also benefits from the
  raised global timeout).

- **Don't-consume on a (rare) residual timeout.** A row that *still* times out at the raised ceiling is
  RECOVERABLE (slow ≠ impossible), so it must not be discarded. The Router classifies the rule-gen error:
  - **transient** (network / timeout / 5xx) → `:transient_abort`: skip BOTH the SFT append and `mark_done`
    (row re-runs next pass); the **implement-path also `Gate.discard(clone)`** (both modes — the router
    wrote scaffold stubs before `Implement.run`, and a prior bugfix attempt may have written files; skipping
    discard leaks a dirty tree into the next row's `Gate`/`Git`); **no `Ledger`** (decisions.md stops
    accruing network spam); move the log to a new `transient/` bucket. The classify-path writes nothing →
    no discard.
  - **fatal** (`401/402/403`, `429`-streak) → `Tunex.shutdown({:fatal_api, reason})` — same as `stage/2`.
    Closes a silent-collapse gap: a dead cookie on a cache-warm run would otherwise 401 in classify and
    silently consume the whole pending list as `classifier_errors` with no halt.
  - **other** (re-ask validation failure, `retries_exhausted` fence, input/output ceiling, scaffold) →
    existing escalate / classifier_errors consume path, unchanged.
  - Predicate: `rulegen_error_class({:llm_error, inner}) -> Budget.classify_error(inner)`; else `:other`.
    One helper works for both branches — the Router already destructures `{:llm_error, inner}` out of
    `{:classifier_errors, reason, _}` and `{:gave_up, reason}`.

- **Per-row give-up bound (NEW — the loop the longer-timeout world introduces).** Don't-consume means a row
  that CONSISTENTLY exceeds even the raised timeout would re-run and time out **forever** (the breaker only
  catches a storm, not one stuck row among successes). Track a PERSISTENT per-row abort count in
  `var/run/transient_attempts.json` (index→count, regenerable, cleared by `tunex.reset`): on each
  `:transient_abort` bump it; at `budget.transient_row_limit` (default **3**) give up → move the log to a
  new **`too_slow/`** bucket, **`mark_done`** (consume — stop looping), append SFT if solve succeeded, and
  `Gate.discard` (implement path). (A consumed row never re-runs, so its stale count is harmless.)

- **Circuit-breaker (outage protection — kept).** Orchestrator threads `consecutive_transient` through
  state: **+1** on `:transient_abort`; **reset to 0** on any real rule-gen outcome (committed/duplicate/
  no_action/behaviour_diverged/switch_proposal/escalated/classifier_error/too_slow/`:raised`); **unchanged**
  on a *blacklisted* row (never reaches Mimo → no outage signal; resetting on it would let an outage
  sprinkled with cache-blacklist rows never trip). At `budget.transient_storm_limit` (default 5) →
  `Tunex.shutdown({:transient_storm, idx})`. A real Mimo outage (still possible, just absent from these
  logs) halts cleanly instead of churning the pending list. `run_row`/`do_row` must surface the outcome to
  `handle_info(:next)` (return currently discarded — new wiring).

- SFT: skip the append + `mark_done` ONLY on `:transient_abort` (the row re-runs and appends exactly once).
  `:too_slow` and every other outcome append + `mark_done` as today. No dedupe tooling needed. Minor wart:
  a row that aborts then later lands leaves a stale `transient/<idx>.log` beside its final bucket —
  harmless, cleared by `tunex.reset`.

### Fix 2 — Strip markdown fences from generated rule files (escalated 2/28; also unblocks syntax/semantic rule generation)
Implementer emits a `.ex` body wrapped in ```` ```elixir … ``` ````; the rule-gen parse path
(`lib/tunex/implement/output.ex` `Output.parse` → `lib/tunex/markers.ex`) only `String.trim`s, leaving
the fence → `SyntaxError: unexpected token "`"` → 5 retries → `retries_exhausted`. Both fence-error rows
(15097, 111209) were the implementer building the attr/`prefer_defmodule_wrapper` rule and **reached
`implement`** (i.e. passed novelty as NOVEL) — Fix 2 is their unblocker.

**Root cause is the seed's own formatting, not just stray model behaviour.** `implement/seed.ex:188`
`defp fence(content), do: "```\n…\n```"` wraps **every** input example (spec before/after, the scaffold
files the model is told to FILL, AST dumps, the diagnostic, bugfix source/tests) in ```` ``` ````, while
the output-contract examples (`seed.ex:183-186`) show bare `===RULE===\n<whole file>`. The model mirrors
the fenced examples into its emitted blocks. So Fix 2 is **three changes**:

1. **Defensive strip (must-have).** Extract the existing private `strip_outer_fences/1`
   (`lib/tunex/parser.ex:219-224`) to public and apply it **uniformly to every section** in `Output.parse`
   (right after `Markers.split`, before role-mapping) — all implement blocks are code, so a uniform strip
   is safe and simplest. Use **`strip_outer_fences`** (first+last fence only), **NOT** `strip_fences` (the
   `/m` variant would corrupt a rule whose `@moduledoc` contains a mid-file ```` ``` ````). A
   whole-output single fence is already handled by `Markers` (leading fence precedes the first marker →
   dropped; trailing fence rides the dropped `===END===` block).
2. **Cut the cause.** Add one line to the seed output contract: "Emit each block's raw file content — do
   NOT wrap it in ``` code fences." Reduces fence emissions (and the retry churn they cause).
3. **Symmetric classify defence.** `classify/parser.ex` does not strip either; a fenced `BEFORE`/`AFTER`
   fails the `parses?` gate → re-ask → possible `classifier_error` (unobserved so far, but same cheap
   reuse). Mirror the strip there too.

### Fix 3 — Teach the classifier the three-round taxonomy (mis-phase prevention)
`lib/tunex/classify/prompt.ex` names the phases only in the output contract
(`===PHASE=== pattern | syntax | semantic`) and never DEFINES them, so the model can't know that
"parses-but-won't-compile" code (e.g. `@attr` before `defmodule`) is **Semantic**, nor that a
**Pattern rule's fix only runs on compiling code** (proposing Pattern for non-compiling input yields a
rule whose fix is gated forever). Add an explicit taxonomy block:

```
## Choosing PHASE — Credence runs 3 ordered rounds; pick by the INPUT's parse/compile status
- syntax   — `before` WON'T PARSE (Sourceror fails); fixes raw text. e.g. `n*(n+1) div 2` → `div(n*(n+1), 2)`.
- semantic — `before` PARSES but the COMPILER rejects/warns (error- or warning-level diagnostics).
             e.g. `@attr` ABOVE `defmodule` ("cannot invoke @/1 outside module"), unused var,
             undefined function. A semantic rule matches a COMPILER DIAGNOSTIC, not an AST shape.
- pattern  — `before` COMPILES and runs but is non-idiomatic; deeper AST rewrites.
HARD: a Pattern rule's fix ONLY runs on code that COMPILES. If `before` does not compile you MUST
choose syntax or semantic — NEVER pattern (a Pattern rule there detects but its fix is skipped forever).
```

**Do NOT mirror into the implementer seed** (the original plan's optional companion is dropped). The
implementer does not choose the phase — the Router calls `Naming.resolve_and_scaffold(spec.proposed_name,
spec.phase, clone)` with classify's phase *before* `Implement.run`, and the seed already gives
phase-specific guidance (`diagnostic_block` for semantic, `ast_block` for pattern/semantic). Phase is a
*classification* concern; the seed mirror would add tokens without changing implementer behaviour.

**Honest yield:** classify-prompt-only. The taxonomy text is *accurate* (verified against `pattern.ex`'s
`compiles?` skip and `semantic.ex`'s compile-failed handling; `n*(n+1) div 2` genuinely won't parse), but
it is **preventive, not corrective** — it directly addresses ~1 observed row (behaviour_diverged 56907,
the only pattern-on-non-compiling case) and otherwise just stops *future* Pattern proposals on
non-compiling code. It will NOT move the escalated/duplicate buckets, and does NOT unblock the
attr-before-defmodule rows while the miscategorized Credence rule still false-COVERs them (Credence fix
below). Keep it — it is a cheap, correct prompt addition — with these expectations.

## Credence fix — DONE 2026-06-10 (`credence@evolution`, working tree; not committed)
Investigating the redundant rules surfaced a **deeper bug than the rule duplication**, now fixed.

### What was actually wrong
The tunex evolution runs generated **6 rules for one concern** (module attrs / code outside a
`defmodule`): 3 in `syntax/` + 3 in `semantic/`, all wrapping bare source in `defmodule Solution`. Testing
the **real `Credence.fix/2` pipeline** (not the rules' own unit tests) showed **all 6 were DEAD** — none
ever fired in production:
- **Syntax round** *skips parseable source* ("source already parses, skipping") — and `@doc/@spec/def`
  outside a module DOES parse → the syntax rules never ran.
- **Semantic round** got **0 diagnostics**: `cannot invoke @/1 outside module` is *raised* by the compiler,
  and `RuleHelpers.compile_and_capture/1` caught the exception but **threw the message away** (returned
  `{:error, []}`), so no rule's `match?` was ever called.
- **Pattern round** skips non-compiling source.

So the rules passed their own unit tests (which call `match?`/`fix` directly) and the tunex gate, but did
nothing in the real pipeline. The 6-way duplication was the *symptom* (the classifier kept re-deriving an
unfixable rule across rounds — Fix 3's unclear taxonomy); the *root cause* was the swallowed diagnostic.

### What was done (working tree on `evolution`; `mix test` = 4403 tests, 0 failures)
1. **Fixed `RuleHelpers.compile_and_capture/1`** — when the compiler *raises*, synthesize an `:error`
   diagnostic from the exception (`%{severity: :error, message: Exception.message(e), position: line}`) and
   return it, instead of `{:error, []}`. Now semantic rules can match raised compile errors. (Safe:
   `{:ok,…}`/`compiles?` paths unchanged; unmatched raised errors still no-op, just logged.)
2. **Consolidated the 6 → 1 canonical `Semantic.RequireDefmoduleWrapper`** (broadest diagnostic match +
   the already-wraps guard). Deleted the other 5 rules + their 10 test files (−881/+56 lines).
3. **Hardened the keeper** — its `fix` now **declines (no-op) when a `defmodule` already exists** so it can't
   produce a broken *nested* wrap; that "attrs above an existing module" case is left for a future
   move-into-module rule. Verified end-to-end: bare snippet → wrapped + compiles; attrs-above-module →
   unchanged.

### Follow-up done 2026-06-10 (same working tree)
4. **Moved `Pattern.NoAttrBeforeDefmodule`'s logic into the semantic rule + deleted the dead pattern rule.**
   `RequireDefmoduleWrapper.fix` is now **move-or-wrap-or-decline**: doc/spec attrs orphaned ABOVE an
   existing `defmodule` are MOVED inside it (the pattern rule's `move_attrs`/`relocation` logic, ported to
   Sourceror-on-source and applied via `patches_from_ast_transform` + `patch_string`); bare code with no
   module is WRAPPED; a module with nothing movable before it is declined. The pattern rule (dead — its fix
   never fired on non-compiling input — and false-COVERing) and its 3 tests are removed; its behaviour now
   actually runs in the semantic round (verified end-to-end: attrs-before-module → moved + compiles).
5. **Fixed a meta-test false-positive** (`FixtureStringEscapingTest`). `MetaTestSupport.fixtures/1` treated
   *every* stringish arg to a verb as a code fixture, so an inline diagnostic-message string in a
   semantic-rule `fix(source, "…msg…")` got flagged as a non-heredoc fixture. Fix: a verb's code fixture is
   the rule-after alias-first arg (`check(Rule, code)`) or only the first source arg (`fix(source, diag)`,
   `analyze(code)`) — later string args (diagnostics/opts/reasons) are not fixtures. (`credence@evolution`,
   `mix test` = 4385 tests, 0 failures.)

---
### Original analysis (for reference — superseded by "What was actually wrong" above)
There are **four** rules in the "module attribute / code outside a `defmodule`" space, split across two
rounds and doing **two different jobs**:

| rule | round | scenario | fix |
|---|---|---|---|
| `Pattern.NoAttrBeforeDefmodule` | **pattern** ❌ | doc/spec attrs above an **existing** `defmodule` | **MOVE** them inside that module |
| `Semantic.NoDocSpecOutsideModule` | semantic | `@doc`/`@spec` with **no** module | **WRAP** in `defmodule Solution` |
| `Semantic.PreferDefmoduleWrapper` | semantic | `cannot invoke @/1 outside module`, no module | **WRAP** in `defmodule Solution` |
| `Semantic.RequireDefmoduleWrapper` | semantic | bare code (`@doc`/`def`) at top level | **WRAP** in `defmodule Solution` |

### Problem 1 — `Pattern.NoAttrBeforeDefmodule` is miscategorized
`@attr` before `defmodule` PARSES but does NOT COMPILE (`cannot invoke @/1 outside module`) — a
**Semantic-round** concern. As a Pattern-round rule:
- its **fix can never fire** — `Pattern.fix_with_trace` (`lib/pattern.ex:52`) correctly skips the whole
  pipeline when `!compiles?` (Pattern rules assume valid, compiling code);
- its **check still fires** in `Pattern.analyze`, so `mix credence.covers` returns COVERED on the snippet
  → tunex novelty marks every attempt to build the correct rule as `duplicate` (this is the false-dupe
  subset of the `duplicate/` bucket, and part of why the timed-out implement rows kept re-deriving
  `prefer_defmodule_wrapper`).

It is a **detect-only Pattern rule**, violating Credence's own promise ("every Pattern rule fixes what it
finds"). **Its move-into-existing-module LOGIC is correct and worth keeping** — wrapping is the WRONG fix
for this case (`@moduledoc "x"\ndefmodule Greeter do…end` wrapped in `defmodule Solution` compiles but
nests `Greeter` and mis-attaches `@moduledoc` to `Solution`). So: **reimplement the move logic as a
Semantic rule** keyed on the `cannot invoke @/1 outside module` `:error` diagnostic, gated to the
"a `defmodule` follows the attrs" shape, and **retire the Pattern-round version**. (`Credence.Semantic`
already handles compile-FAILED source — `lib/semantic.ex:89`.)

### Problem 2 — the three Semantic wrap rules overlap
`NoDocSpecOutsideModule` / `PreferDefmoduleWrapper` / `RequireDefmoduleWrapper` all key on near-identical
diagnostics and apply the **same** `defmodule Solution` wrap — redundant and potentially competing in one
semantic pass. Audit them: pick ONE canonical wrap rule (the "no module at all" case), retire/merge the
others, and order it AFTER the new move rule (if a `defmodule` follows the attrs → MOVE; else → WRAP).

### Problem 3 — round contracts are implicit
Make each round's **contract explicit** in the rule docs / a rule-type guide (which round owns
parse-failures vs compile-failures vs idiomatic), so human- and pipeline-authored rules land in the round
whose fix can actually run. (Same taxonomy as Fix 3's tunex classifier prompt.)

### Suggested issues to file against `Cinderella-Man/credence`
1. **Move `NoAttrBeforeDefmodule` from pattern → semantic** (reimplement on the diagnostic; gate to
   "defmodule follows"; retire the pattern version). Fixes the false-dupe that blocks rule-gen here.
2. **De-duplicate the three semantic `*defmodule_wrapper` / `*outside_module` wrap rules** → one canonical
   wrap, ordered after the move rule.
3. **Document the per-round contract** (parse-fail = syntax, compile-fail = semantic, idiomatic-on-compiling
   = pattern).

## Priority order
1. **Fix 1 timeout knob + 30-min probe** — the primary win; recovers ~26/28 escalated + the classifier_error.
2. **Fix 2** (fence strip) — trivial, tunex-only, immediate; recovers the other 2/28.
3. **Fix 1 resilience** (don't-consume + per-row `too_slow` bound + fatal→shutdown + breaker) — handles the
   rare residual timeout and real outages cleanly.
4. **Fix 3** (classifier phase taxonomy) — prevents future mis-phased, never-fixing rules (modest yield).
5. **Credence section** — file as issue(s) against `credence`; out of scope for this plan.

## Concrete steps
1. **`lib/tunex/llm.ex`** — replace the hardcoded `receive_timeout: 600_000` (`call/3`, line 54) with
   `Config.llm_timeout_ms()`. **`lib/tunex/config.ex`** — read `budget.llm_timeout_ms` (probe value
   `1_800_000`; production value = probe-ceiling + ~30%, TBD). *(Fix 1 — primary)*
2. **`lib/tunex/parser.ex`** — make `strip_outer_fences/1` public. **`lib/tunex/implement/output.ex`** —
   apply it to **every** section in `Output.parse` (right after `Markers.split`). **`lib/tunex/implement/
   seed.ex`** — add the no-``` line to the output contract. **`lib/tunex/classify/parser.ex`** — strip
   `BEFORE`/`AFTER` (and harmlessly the rest) before building the Spec. *(Fix 2 — all three)*
3. **`lib/tunex/config.ex`** — also read `budget.transient_storm_limit` (default 5) and
   `budget.transient_row_limit` (default 3). **No retry knobs** for rule-gen (retry is dropped). *(Fix 1)*
4. **`lib/tunex/row_log.ex`** — add `transient` AND `too_slow` to `@outcome_dirs` + `transient/1` +
   `too_slow/1` movers. *(Fix 1)*
5. **Persistent per-row count** — a tiny store over `var/run/transient_attempts.json` (e.g.
   `Tunex.TransientAttempts.bump(index) -> count`, read-modify-write JSON; best-effort, no crash on write
   failure). Add to `tunex.reset`'s wipe list (it lives under `var/run/`). *(Fix 1)*
6. **`lib/tunex/evolve/router.ex`** — add `defp rulegen_error_class({:llm_error, inner}), do:
   Budget.classify_error(inner)` / `rulegen_error_class(_), do: :other`. Apply in the `{:gave_up, reason}`
   branch of `build_and_gate/5` and the `{:error, {:classifier_errors, reason, _}}` branch of
   `classify_and_dispatch/6`:
   - `:transient` → `Gate.discard(clone)` (implement path only); `TransientAttempts.bump(index)`; if
     `count >= transient_row_limit` → `RowLog.too_slow(index)`, `outcome(:too_slow, nil)` (consumed); else
     `RowLog.transient(index)`, NO `Ledger`, `outcome(:transient_abort, nil)`;
   - `:fatal` → `Tunex.shutdown({:fatal_api, reason})`;
   - `:other` → keep current escalate / classifier_errors paths. *(Fix 1)*
7. **`lib/tunex/orchestrator.ex`** — in `solve_and_finish`, skip BOTH the SFT append and `Progress.mark_done`
   ONLY when `rg_outcome(rg) == :transient_abort` (`:too_slow` and all else append + `mark_done` as today).
   Surface the per-row outcome from `run_row`/`do_row` to `handle_info(:next)`; thread
   `consecutive_transient` through state (+1 on `:transient_abort`; reset to 0 on any real outcome incl.
   `:too_slow`; unchanged on blacklist); at `budget.transient_storm_limit` →
   `Tunex.shutdown({:transient_storm, idx})`. *(Fix 1 + breaker)*
8. **`lib/tunex/classify/prompt.ex`** — add `@phase_taxonomy`, inject in `build/1` next to the PHASE /
   output-contract section; tighten `lens(:failed)`. **No seed mirror.** *(Fix 3)*
9. **Credence** — open issue(s) capturing the "What's wrong with Credence" section. *(out of scope)*

## Verification
- **Unit (`mix test`):**
  - config/llm: `LLM.call` passes `Config.llm_timeout_ms()` as `receive_timeout` (assert via an injected/
    captured `post`, or by reading the configured value).
  - router transient: `implement` stub → `{:gave_up,{:llm_error,{:network,:timeout}}}` (count < limit) ⇒
    `outcome == :transient_abort`, **`Gate.discard` called**, `RowLog.transient` called, `Ledger` NOT
    called; classify stub → `{:error,{:classifier_errors,{:llm_error,{:network,:timeout}},_}}` ⇒
    `:transient_abort`, NO discard, NO Ledger. A non-transient `:gave_up` / re-ask validation failure ⇒
    unchanged escalate / classifier_errors path.
  - router too_slow: with the per-row count already at `transient_row_limit - 1`, a transient ⇒ `outcome ==
    :too_slow`, `RowLog.too_slow` called (not `transient`). (Stub `TransientAttempts`.)
  - router fatal: a `{:llm_error,{:http,401,_}}` in either branch ⇒ `Tunex.shutdown({:fatal_api,_})` (inject
    the shutdown fn).
  - orchestrator: a `:transient_abort` row ⇒ neither SFT append nor `mark_done`; a `:too_slow` row ⇒ SFT +
    `mark_done` DO run; `transient_storm_limit` consecutive aborts ⇒ shutdown; a blacklisted row between
    aborts ⇒ counter unchanged (breaker still trips); a real outcome ⇒ counter reset.
  - output: a RULE block wrapped in ```` ```elixir ```` ⇒ stripped, written file compiles; a rule whose
    `@moduledoc` contains a mid-file ```` ``` ```` is NOT corrupted (proves `strip_outer_fences`, not
    `strip_fences`). classify parser: a fenced `BEFORE` ⇒ stripped, passes `parses?`.
  - prompt: `build/1` output contains the phase-taxonomy text (assert like the existing
    `type_change_block` tests).
- **The 30-min probe (the experiment that sets the production timeout):** set `budget.llm_timeout_ms =
  1_800_000`; remove the 28 timed-out indices from `var/run/progress`; re-run them (translate cached =
  free, solve = local Qwen = free; only the 28 `implement` Mimo calls cost tokens). **Capture `elapsed_ms`
  per now-successful call** (already logged) → the real completion-time distribution. Set production
  `llm_timeout_ms` = observed ceiling + ~30%. Confirm the formerly-timed-out rows now reach the Gate; any
  that STILL exceed 30 min land in `transient/` then `too_slow/` after `transient_row_limit` re-runs (NOT
  `escalated/`, NOT in decisions.md).
- **Manual:** confirm `var/run/decisions.md` no longer accrues `{:network}` blocks after a run.

## Resolved decisions
**Root-cause reframe (2026-06-10) — supersedes the earlier "retry" plan:**
1. **The 26/28 + classifier_error are slow `implement` generations cut off at 10 min, NOT network blips**
   (evidence in Fix 1: 28/28 had an earlier Mimo success in the same row; all hit the 600s ceiling;
   312:1 in `implement`; the 4.5-min success max is a censoring artifact).
2. **Primary fix = raise the timeout** (`budget.llm_timeout_ms`), set from a **30-min probe** (not 20 — to
   avoid re-censoring) → production = probe-ceiling + ~30%. Billing is by tokens not wall-clock, so a
   generous timeout costs nothing extra.
3. **Retry is DROPPED** — it doesn't help slow calls (a retry just times out again), and genuine blips are
   already covered by don't-consume (re-run next pass, free). `stage/2`'s existing translate/solve retry is
   untouched.
4. **Don't-consume on a residual timeout** — `:transient_abort` skips SFT append + `mark_done` (re-runs
   next pass); implement-path also `Gate.discard`; no `Ledger`; log → `transient/`.
5. **Per-row `too_slow` bound (NEW)** — persistent `var/run/transient_attempts.json`; at
   `budget.transient_row_limit` (3) the row is consumed → `too_slow/` bucket, so a consistently-too-slow row
   can't loop forever.
6. **Fatal rule-gen errors** (`401/402/403`, `429`-streak) → `Tunex.shutdown` like `stage/2` (closes a
   cache-warm silent-collapse gap).
7. **Breaker kept** — `consecutive_transient`, blacklist leaves it unchanged, any real outcome resets, halt
   at `budget.transient_storm_limit` (5).
8. **SFT** — skip append + `mark_done` only on `:transient_abort`; `:too_slow` and all else behave as today.
   No dedupe needed.
9. **Fix 2** — strip + seed no-fence note + classify-side strip (all three). **Fix 3** — classify prompt
   only, no seed mirror.

## Remaining open questions
1. **Production `llm_timeout_ms`** — pending the 30-min probe's measured completion-time ceiling (then
   +~30%). Until then the knob defaults to the probe value `1_800_000`.
2. Minor (`429`-streak): `Budget.classify_error` is stateful (`consecutive_429`); the router predicate calls
   it once per error, and `note_success` is only called by `stage/2`. Observed logs are 100% timeouts, not
   429s — non-issue today; revisit only if 429s appear.
