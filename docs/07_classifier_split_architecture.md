# 07 — Classifier-split architecture (the rule-gen rebuild)

*Written 2026-06-02 from a deep grilling session + codebase research.*
*Supersedes the **levers + triage** of [`06`](06_burn_reduction_execution_plan.md). The constraint
framing in [`05`](05_token_budget_truth_and_plan.md) (38B-token/mo bucket, console = only truth, in-band
ledger undercounts ~20×) and the **corrected cost model** in `06` (cost ≈ 92% `cache_read` = re-read prefix;
`max_turns` capping kills yield) both still hold and motivate this rebuild.*

> **Status: design, not built.** This doc is meant to be grilled further and then converted into tasks.
> It describes a **full replacement** of the rule-creation process. The current monolithic ClaudeCode-agent
> flow (`lib/tunex/claude_code.ex` + the agentic `lib/tunex/evolve/credence_rule_generator.ex`) is **deleted**
> by this plan — not flagged, not kept as a fallback.

---

## 1. Why rebuild (the one-paragraph case)

Today every solved row spawns **one ClaudeCode agentic session** whose prompt = a 75-line task + rule-name
index + ledger + the **raw row-log firehose**, fed to a Mimo-pro model *through the Claude Code harness*.
Two structural costs make this the entire burn:

1. **The harness re-sends the whole conversation prefix on every turn** — cost is ~92% `cache_read`, scaling
   `final_prefix × (turns ÷ 2)` (the "~20×" multiplier). Output is a rounding error.
2. **62% of these sessions conclude `no_opportunity`** — a full multi-turn agentic session, harness system
   prompt and all, just to say "nothing to do."
3. **The harness itself is overhead**: ClaudeCode's system prompt is ~24k tokens, sent on every turn. A raw
   chat call has a ~200-token system prompt. The harness exists to give the model *tools + a loop*; but the
   model only needs tools because it has to *explore* (discover the Sourceror AST shape, the rule format, the
   file layout). Remove the need to explore and the harness has no job.

**The rebuild** splits the one monolithic agentic session into:

- a **single cheap classifier call** (raw LLM, no harness, no tools) that consumes the log **once** and emits
  a structured decision + spec, and
- a **bounded solver-style implementer loop** (raw LLM, no harness, no tools) that fires **only** on
  actionable specs, seeded with everything it would otherwise have explored for.

`NO_ACTION` (the 62%) spawns **zero** implementer work. The firehose is read exactly once, by the classifier,
killing the ~20× multiplier on it. The harness is deleted.

---

## 2. The shape

```
solved row
   │
   ▼
[distill]  coarse cut: drop Python / translate / round-trip / reference  (anti-anchor + smaller input)
   │
   ▼
[CLASSIFIER]  one raw Tunex.LLM call · mimo-v2.5-pro + thinking · ~200-tok system prompt · no tools
   │   input:  distilled log + APPLIED_RULES + decisions.md ledger
   │   output: marker-fenced thick spec  (see §4)
   │
   ├── NO_ACTION ─────────────► log → var/run/no_action/<idx>.log         (no model work)
   │
   ├── BUGFIX_RULE ───────────► [IMPLEMENTER: bugfix mode]
   │      (rule_name ∈ APPLIED_RULES)        edit existing rule + its tests in place
   │
   └── POTENTIAL_NEW_RULE ────► [IMPLEMENTER: new mode]
          (always create new)               write new rule + split tests
                                                   │
                                                   ▼
                                          [GATE] (unchanged 5-part)
                                                   │
                                        ┌──────────┴──────────┐
                                     commit                 reject
                                  (evolution branch)    log → escalated/  + ledger
```

Both implementer modes run the **same** solver-style loop engine (§5), parameterized by seed context and
target paths.

---

## 3. The classifier

### 3.1 Execution

- **Raw `Tunex.LLM` single call** via `LLM.for_stage(:classify, …)` (re-uses the existing usage/budget
  instrumentation). **Not** the ClaudeCode harness — no tools, no agentic loop, no 24k system prompt.
- **Model: `mimo-v2.5-pro` with thinking on.** This call carries the single hardest judgment in the system —
  recognising *clean, passing, zero-issue but non-idiomatic* code — and a false `NO_ACTION` is a permanently
  lost rule. This is the one place we deliberately **pay for brains**. (Free local Qwen stays for solve only.)
- Runs on **100% of solved rows**, so it is the new cost floor. It is still cheap: a `no_opportunity` row
  drops from a ~1M+ `cache_read` × ~20× multi-turn session to one ~few-K-token call.

### 3.2 Input

The classifier is the **only** consumer of the row log. It receives:

1. **The distilled log** — coarse cut only this round: drop the Python source, the translate output, the
   round-trip output, and the reference Elixir solution. Keep the Qwen solve attempts + **every attempt's**
   Credence fix trace (before/after/`APPLIED_RULES`/issues). Rationale below (§7).
2. **`APPLIED_RULES`** — the closed set of rules that actually fired, extracted from the fix trace. Drives the
   BUGFIX closed-set validation and the option-shaping.
3. **`decisions.md` ledger** — dead-end patterns already tried, so the classifier does not re-propose a known
   *impossible* pattern (which would cost a doomed implementer run).

**Explicitly NOT injected: the rule-name index.** See §3.5 — it is redundant by construction.

### 3.3 Option-shaping (deterministic prompt construction)

The set of decisions the classifier is *offered* is shaped from deterministic preconditions, so it cannot
emit a structurally impossible route:

- **`APPLIED_RULES` empty across all attempts** → no rule fired → BUGFIX is impossible → the classifier is
  offered only `POTENTIAL_NEW_RULE | NO_ACTION`.
- Otherwise → all three options.

(Future preconditions can shape the option set further; this is the first.)

### 3.4 The two routes, defined precisely

- **`BUGFIX_RULE` = an applied rule over-fired / produced worse / more-verbose / wrong code.** The culprit is
  *provably* one of the names in `APPLIED_RULES`. This is the only case where we **know for certain** which
  rule's source + tests to fix — name → `lib/<phase>/<name>.ex` + `test/<phase>/<name>*_test.exs` is a total
  deterministic mapping.
  - **Under-firing** (a rule that *should* have fired but didn't) is **NOT** a BUGFIX — its culprit is
    invisible (not in `APPLIED_RULES`) and indistinguishable from "no rule exists yet." It is handled as
    `POTENTIAL_NEW_RULE`.
- **`POTENTIAL_NEW_RULE` = clean, passing, non-idiomatic code no existing rule caught.** **Always becomes a
  new rule.** We never auto-extend an existing rule (see §3.6).

### 3.5 Why no rule-name index (residual = uncovered by construction)

Credence-fix runs **all** existing rules during solve's `Validator` step 1/6, and a landed rule **recompiles**
into subsequent rows. Therefore, by the time the classifier sees the final code, every applicable existing
rule has *already fired*. Consequences:

- If a rule covered this pattern, the code is already fixed → idiomatic → the classifier says `NO_ACTION`
  **on the code's own merits**, with no index needed.
- Residual non-idiomatic code is, by definition, **not caught by any existing rule** → a new-rule proposal is
  *always* genuinely novel.
- BUGFIX needs only the `APPLIED_RULES` closed set, not the full catalog.
- Duplicate *names* are handled deterministically by a suffix (§3.6).

Self-suppression of duplicates was never the index's job — it is `credence-fix-runs-all-rules` +
recompile-on-land. The index only added prompt weight and a coupling point. **Dropped.**

### 3.6 Always-create-new + name collision

We **never auto-extend** an existing rule from `POTENTIAL_NEW_RULE`. Rationale:

- Extending would force the model to *choose which* rule to broaden and *how* — unbounded, brittle, the worst
  branch in an autonomous loop. (Contrast BUGFIX, where the target is deterministically known — editing it is
  bounded and gate-validated. The asymmetry is principled.)
- Aligns with the existing "micro-rules ARE welcome" philosophy — two narrow rules instead of one broadened
  rule is on-brand; Credence runs them all.
- A human already reviews `evolution → main` manually; **merging/broadening sibling rules is a human
  review-time job**, done by someone good at it, at low frequency.
- Downside (occasionally a clean broadening beats a sibling rule) is small and human-correctable at merge.

**The orchestrator owns naming, not the model.** The classifier proposes a *semantic* name; the orchestrator
resolves the first free suffix (`prefer_enum_sum.ex` taken → `prefer_enum_sum_2.ex`, module
`PreferEnumSum2`) and hands the implementer the **final** module name + exact paths. Naming is no longer
something the LLM can get wrong or explore. On collision we simply accept a fresh standalone rule and let the
human dedup later — no dropping, no special routing.

---

## 4. The classifier output contract (the "thick spec")

We extract **maximum value from the one call** — it does heavy thinking over the whole log, and we discard the
log afterward, so the spec must carry everything downstream needs.

### 4.1 Fields

```
decision   : NO_ACTION | BUGFIX_RULE | POTENTIAL_NEW_RULE   (must be in the offered set)
rule_name  : present iff BUGFIX_RULE; must be ∈ APPLIED_RULES
phase      : pattern | syntax | semantic                    (present iff a rule is proposed)
before     : the offending / non-idiomatic snippet          (must parse via the AST helper)
fixable    : { after : <idiomatic rewrite> }  |  check_only
rationale  : one line — why this is non-idiomatic / how the existing rule over-fires
```

- **`before` is the rule's first test case** (must-fire). For fixable rules `after` is the must-not-fire +
  `fix(before) == after` assertion. For `check_only` there is no `after` (the rule will be `fix_patches/2 ->
  []`).
- **Complexity cap on `after`:** thick output is good, but a sprawling `after` is untrustworthy. If the
  proposed `after` blows a deterministic ceiling (e.g. > N lines / multi-statement — threshold is a tuning
  item, §10), **auto-downgrade to `check_only`** rather than trusting it. The implementer can also *choose*
  check-only when the fix needs coordinated edits. **CHECK-ONLY (`fix_patches/2 -> []`) is the universal
  fallback** — "the auto-fix is too hard" is never a reason to give up.

### 4.2 Format

**Delimited-marker blocks, not JSON.** Mimo is a code model; fenced sections are more reliable than strict
JSON, and code snippets inside JSON strings are an escaping minefield. Mirror solve's proven
`---MODULE---`/`---TEST---` approach:

```
===DECISION===
BUGFIX_RULE
===RULE_NAME===
pattern/prefer_enum_reverse_two
===PHASE===
pattern
===BEFORE===
<snippet>
===AFTER===           (or:  ===CHECK_ONLY===)
<snippet>
===RATIONALE===
<one line>
```

### 4.3 Deterministic validation gates

Parse + validate; on failure → **one re-ask**; if still invalid → log to `var/run/classifier_errors/<idx>`.

- `decision` ∈ the **offered** set (respects option-shaping §3.3).
- `BUGFIX_RULE` ⇒ `rule_name` ∈ `APPLIED_RULES` **and** resolves to an existing `lib/<phase>/<name>.ex`.
  A name that didn't fire is *structurally impossible* → reject. (The LLM cannot send us chasing a phantom
  rule.)
- `POTENTIAL_NEW_RULE` ⇒ `phase` valid; `before` non-empty and **parses** via the AST helper.
- `after` parses (when fixable); over the cap → auto-downgrade to `check_only`.

On a malformed/invalid spec we do **one** re-ask, then stop (a row we can't get a clean spec for is not worth
an implementer). The failed spec + log land in `classifier_errors/` for debugging.

---

## 5. The implementer (solver-style loop — no harness, no tools)

The keystone of "less agentic": the implementer is the **same shape as the solve stage** — LLM generates →
*we* run the validator deterministically → feed failures back → retry — on raw `Tunex.LLM`, bounded retries.
The thing that made the old agent *explore* (unknown AST shape, unknown rule format, unknown layout) is
**supplied up front**, so there is nothing to explore and no need for tools.

### 5.1 One engine, two modes

| | `POTENTIAL_NEW_RULE` (new mode) | `BUGFIX_RULE` (bugfix mode) |
|---|---|---|
| Target paths | new `lib/<phase>/<name>.ex` + new split tests (orchestrator-assigned, suffix-decollided) | the **existing** `lib/<phase>/<name>.ex` + its test(s), from `rule_name` |
| Seed context | rule+test exemplar + before/after AST dumps | **full source of the offending rule** + **all** `test/<phase>/<name>*_test.exs` (glob) + before AST dump |
| Test files written | **split**: `_check_test.exs` always; `_fix_test.exs` when fixable | **edit in place** — no test-split migration (see §5.4) |
| Mutation gate | new test RED without new rule | narrowed `_check` test RED with HEAD rule (over-fires → issue present → must-not-fire fails) |

The mechanics are identical: **LLM emits whole files → orchestrator writes → focused `mix test` → feed
failures back → retry (≤ `rule_gen_max_retries`) → Gate**. Do **not** fork the engine; parameterize it.

### 5.2 Whole-file emit (not patches)

Even for bugfix, the LLM returns the **complete** updated `rule.ex` + test file(s); we overwrite wholesale.
Rules are small (~60–200 lines); whole-file emit is far more reliable in a non-agentic loop than
patch-application, which is fuzzy and adds a failure mode. (Caveat: very large rules like the 552-line
`no_map_then_aggregate` make whole-file rewrite riskier — acceptable, the Gate backstops it; revisit only if
large-rule bugfixes fail in practice.)

### 5.3 Seed context = what the agent used to explore for

- **Both before + after AST dumps**, precomputed by the AST helper (§6) and passed as **arguments** to the
  loop. The loop never invokes the helper itself (keeps it non-agentic; no `mix run -e`, ever).
- **One inlined small pattern rule + test exemplar** (the old "starter kit", repurposed) so the model knows
  the format without reading files.
- **For bugfix**: the offending rule's full source + all its test files, injected by deterministic path.
- A path-convention line (rules `lib/<phase>/<name>.ex`, tests `test/<phase>/…`, dispatchers, helpers) —
  ~30 tokens, replaces any `ls`/`tree`.

### 5.4 The split-test rule

> **The loop writes split tests for files it *creates*; it never restructures files that already exist.**

- **New rule** → greenfield: emit `_check_test.exs` (+ `_fix_test.exs` when fixable). The before/after spec
  hands the model exactly the material for each file.
- **Bugfix** → edit whatever test files exist *in place* (single `<name>_test.exs`? add the must-not-fire
  assertion to it; already split? edit `_check`). No renames, no deletes, no migration. Keeps the bugfix diff
  modify-only so the Gate's pure-deletion/scope checks stay trivial and the mutation gate has an unambiguous
  RED file. (Some rules already have split test files; the convention isn't fully rolled out — the glob
  handles both states. Migrating *existing* rules to split tests is a separate human/mechanical pass.)

### 5.5 Bound

`rule_gen_max_retries` — a **dedicated** config knob (start ~5), *not* shared with solve's `max_retries`
(rule authoring and solution authoring have different difficulty profiles; tune independently). Each retry
feeds back the focused `mix test` failure. The loop self-terminates at the bound — there is **no token
breaker** (the old per-session breaker is dropped; a bounded loop of small calls can't run away).

---

## 6. The AST helper (the exploration-killer)

Credence has **no AST-inspection tool today** (rules use `Macro.prewalk/postwalk` on `Sourceror.parse_string!`;
no `ast_walk`, no mix task). The old agent explored — `mix run -e` experiments — precisely to *guess* the
Sourceror tuple shape. Hand it the shape and the exploration disappears.

- **Home: a new `mix credence.ast` task in the Credence repo** (reads code from stdin/file, prints the AST).
  Lives there so it uses Credence's exact Sourceror version + can reuse `RuleHelpers.strip_layout_meta`; it is
  also a genuine standalone dev tool for human rule-authors. Tunex shells out to it against the clone, exactly
  as it already does with `run_credence_fix.exs`.
- **Output: two views.**
  1. **Raw** — `inspect(Sourceror.parse_string!(code), pretty: true, limit: :infinity)`. The ground truth the
     rule's `check/2` pattern-matches against, **including** the `{:__block__, _, [literal]}` wrappers, which
     *matter*.
  2. **Layout-stripped** — same structure with `:line/:column/:closing` meta removed, for readability.
  - ⚠️ **Never emit `normalize_sourceror_ast`/unwrapped form** as the matching target — it *unwraps* the
    `__block__` literal wrappers (it exists for test-time AST-equivalence) and would teach the model the
    **wrong** shape to match.
- **Why this is correct:** `Macro.prewalk/postwalk` is a *visitor*, not a transformer — the function receives
  each subtree of the parsed tree **unchanged**. So dumping the parse output *is* exactly what the walk sees.
  (The standard parser `Code.string_to_quoted` would give a different, un-wrapped AST — Credence never uses
  it.)
- **Usage:** the orchestrator runs the helper on **both** the `before` and `after` snippets and injects both
  dumps into the implementer's seed (before-only for check-only). Writing the rule becomes mechanical: "match
  this exact `before` tuple shape, emit a patch producing this exact `after` tuple shape."
- **Dogfood:** before relying on it, run the helper on a snippet a *known* rule matches and confirm the dump
  matches what that rule actually pattern-matches.
- **Nice-to-have (documented, not built):** append a short static Sourceror-gotchas cheatsheet (wrapped
  literals, atom positions, `:delimiter` meta — all already in Credence's `CONTEXT.md`).

---

## 7. Distillation (this round: coarse cut only)

The classifier reads the log **once**, so distillation's old justification (shave the ~40× re-sent prefix)
is **gone**. Its remaining value is **accuracy** + a smaller single-call input:

- **Build this round (a few lines):** drop the Python source / translate / round-trip / **reference Elixir
  solution** sections. These are *actively harmful* to a one-shot judge — the reference answer anchors the
  model into rationalising "already fine"; solve is reference-blind by design and the classifier must be too.
  - Implementation note: this needs a stable boundary marker between the translate and solve sections of the
    row log. If one isn't already clean enough to split on, add a single log line to mark it — still trivial.
- **Keep:** the Qwen solve attempts + **every attempt's** Credence fix trace (un-deduped). Intermediate
  over-firing matters: a rule can over-fire on an early attempt and be masked by Qwen's later rewrite; the
  final state would hide a real BUGFIX opportunity.

**Documented, NOT built this round** (the `06` design, preserved as the follow-up): full **marker-fencing at
the source** — emit stable code-constant markers around each high-value block per attempt (`<<FIX_TRACE
rule=.. attempt=N>>…<<END>>`, `<<APPLIED_RULES>>`, `<<SOLVE_CODE attempt=N>>`, `<<ISSUES>>`); distiller rule =
keep fenced verbatim, drop everything unfenced. Build it only if measurement shows the classifier mis-judging
from log noise. The full firehose stays on disk regardless (§8).

---

## 8. No deletion (debuggability)

We will be debugging this heavily, so **nothing in `var/run/` is ever deleted** — artifacts are **moved** to
an outcome directory, never removed. `mix tunex.reset` remains the only thing that clears `var/run/`, so disk
is bounded by a run, not forever.

| Outcome | Directory | Was |
|---|---|---|
| Landed rule | `committed/` | (same) |
| gave_up / gate-reject / implementer-failed | `escalated/` | (same) |
| `NO_ACTION` | **`no_action/`** (NEW) | *deleted* (`RowLog.close/1`) |
| Spec malformed after one re-ask | **`classifier_errors/`** (NEW) | n/a |

`RowLog.close/1`'s delete becomes a move to `no_action/`. **Retention knob** (default = keep everything):
`no_action/` is the 62% bulk holding full firehose logs — fine for a days-long run + reset; if disk bites,
retain only the *distilled classifier input + its output* there (enough to debug a suspected false-negative).

(Scope of "no deletion" = logs/artifacts. The Gate still `git reset`s the clone's working tree on reject —
that's not a debugging artifact.)

---

## 9. What stays, what dies

| Item | Fate |
|---|---|
| `lib/tunex/claude_code.ex` (the harness driver) | **Deleted** — no harness anywhere, no flag fallback. |
| agentic `credence_rule_generator.ex` (`@task`, `build_prompt`, `route`) | **Replaced** by classifier + router + solver-loop implementer. |
| `max_turns` (config + plumbing) | **Deleted** — no turns. |
| Per-session token breaker | **Deleted** — bounded loop can't run away. |
| The 5-part **Gate** (`evolve/gate.ex`) | **Unchanged** — harness-independent; operates on the git diff + `mix test`. The backstop that lets everything upstream be aggressive. |
| `decisions.md` **ledger** (`evolve/ledger.ex`) | **Kept** — now feeds the classifier; written on gave_up / failed-implement. Prevents re-attempting known-impossible patterns. |
| Rule-name **index** | **Dropped** from the prompt (§3.5). |
| `Git.commit_and_push` to `evolution` | **Unchanged.** |
| **`credence_failed`** escalation branch (the `06` design) | **Kept as-is** — gave_up / failed-implement artifacts committed off-machine for human rule-mining; branch off `main`, data-only JSON blobs, Preflight-ensured. |
| `summed_usage` as cost basis | **Built** (see §11) — even raw-LLM retries re-send a growing prefix; we must meter the true bucket debit. |
| Free local **Qwen** for solve | **Unchanged** — the classifier is the *only* place we pay for brains. |

---

## 10. Safety properties (why this is hard to break)

- **A BUGFIX can't chase a phantom rule** — `rule_name` must be in `APPLIED_RULES`, validated deterministically.
- **A new rule can't silently overwrite an existing one** — orchestrator-owned naming + deterministic suffix.
- **A bad rewrite can't land** — the Gate's mutation test (RED without the rule) + full-suite-green reject any
  over-aggressive narrowing or any rule that breaks the suite.
- **A bad spec can't burn an implementer** — `before`/`after` must parse; over-cap `after` → check-only;
  malformed → one re-ask → `classifier_errors/`.
- **A false `NO_ACTION` is bounded** — human-sampled audit of retained `no_action/` logs (§12), zero token cost.
- **Nothing is lost to debugging** — no deletion (§8).

---

## 11. Build sequencing (each gated on a console-Δ measurement — the only ground truth)

0. **`summed_usage` measurement fix** — record `summed_usage` (already computed in `claude_code.ex collect/2`,
   to be ported) as the cost basis so `mix tunex.usage` ≈ console; validate once via `mix tunex.diag` to name
   the real multiplier. *Prereq for trusting every later number; ~free.*
1. **AST helper** — `mix credence.ast` in Credence + dogfood against a known rule's snippet. Unblocks the
   implementer.
2. **Classifier** — raw `Tunex.LLM` / Mimo-pro, marker output, validation gates, option-shaping, coarse
   Python-cut distillation, `APPLIED_RULES` + ledger inputs.
3. **Solver-loop implementer** — both modes + seed context + AST-dump injection + the new outcome directories
   (`no_action/`, `classifier_errors/`). **Wired classifier → implementer end-to-end immediately** (no
   measure-only sub-phase).
4. **`credence_failed` escalation branch** — independent; can land any time.
5. **Delete** `claude_code.ex` + the agentic generator once 2–3 are proven landing rules.
6. **MEASURE** the combined cut vs the **4–8×** target (console Δ/row, committed rows/day must not drop).

---

## 12. Shadow / false-negative protection

Doc `06` called false-negative protection non-negotiable (route ~10% of triaged-out rows to the *full
agent*). Under this design **there is no full agent to shadow to** — the classifier *is* the smartest judge.
So:

- **Built: human-sampled audit of retained `no_action/`.** Since we keep every NO_ACTION log, a human
  periodically eyeballs a random sample to estimate the false-negative rate — zero token cost, same human who
  reviews `evolution → main`. Bad miss rate → tighten the classifier prompt.
- **Footnote only (not even nice-to-have):** an automated second-opinion — re-run a sample of `NO_ACTION`
  through a *differently-prompted* classifier ("find the rule a lazy reviewer missed"). Spending tokens to
  second-guess the smart judge inverts the design; build only if human sampling ever shows an unacceptable
  miss rate (a problem that probably never happens).

---

## 13. Decision log (quick reference)

| # | Decision |
|---|---|
| Replacement | Full rebuild of rule-creation; ClaudeCode harness + agentic generator **deleted**, no fallback |
| Classifier | One raw `Tunex.LLM` call, `mimo-v2.5-pro` + thinking, no tools, ~200-tok system prompt, on 100% of rows |
| Classifier input | distilled log + `APPLIED_RULES` + ledger; **no rule-name index** (residual = uncovered by construction) |
| Output | marker-fenced thick spec `{decision, rule_name?, phase, before, fixable:{after}|check_only, rationale}` |
| Option-shaping | empty `APPLIED_RULES` → BUGFIX not offered |
| BUGFIX | constrained to `APPLIED_RULES` (over-firing only); under-firing → NEW |
| NEW | **always create new**, never extend; collision → deterministic suffix; orchestrator owns naming |
| `after` complexity | capped; over-cap → auto check-only; **CHECK-ONLY is the universal fallback** |
| Validation | deterministic gates; one re-ask → `classifier_errors/` |
| Implementer | **one** solver-style loop (raw LLM, no harness/tools), parameterized new/bugfix; whole-file emit |
| Implementer seed | thick spec + precomputed before+after AST dumps + exemplar (+ rule source for bugfix) |
| Split tests | new rules emit `_check`+`_fix`; bugfix edits existing tests **in place** (no migration) |
| Bound | dedicated `rule_gen_max_retries` (~5); **no token breaker**; **no `max_turns`** |
| AST helper | `mix credence.ast` in Credence; raw + layout-stripped views; never `normalize`/unwrapped; dogfooded |
| Distillation | coarse Python/translate/reference cut **only** this round; full marker-fencing documented-not-built |
| Gate | **unchanged** (5-part backstop) |
| Ledger | kept, feeds classifier |
| No deletion | move-to-outcome-dir; new `no_action/`, `classifier_errors/`; `tunex.reset` still clears |
| Measurement | build `summed_usage` cost basis; validate via `mix tunex.diag`; trust console for absolutes |
| Shadow | human-sampled `no_action/` audit; automated second-opinion = footnote only |
| Escalation archive | `credence_failed` branch kept as-is |
| Sequencing | summed_usage → AST helper → classifier → implementer → escalation → delete old → measure |

---

## 14. Open items (tuning, not design — for live iteration, not this plan)

1. The classifier prompt's exact wording for "spot clean-but-non-idiomatic code" — the hardest judgment;
   iterate against `no_action/` audits.
2. The `after` complexity-cap threshold (lines / statement count) that triggers auto check-only.
3. `rule_gen_max_retries` starting value (~5) — tune against landed-rules/attempt.
4. Whether very large rules (e.g. 552-line `no_map_then_aggregate`) need a patch-mode bugfix instead of
   whole-file emit — revisit only if large-rule bugfixes fail in practice.
5. The `no_action/` retention knob (full firehose vs distilled-input-only) — flip if disk bites.

---

## 15. Things deliberately NOT in this round (documented for the future)

- **Full marker-fencing distillation** (§7) — coarse cut suffices for one smart call; build if the classifier
  mis-judges from log noise.
- **Automated second-opinion shadow** (§12) — footnote; human sampling first.
- **Focused-agentic escalation for long-tail complex rules** — the solver loop is the *sole* implementer this
  round; if it can't land a genuinely complex rule it `gave_up`s. Measure yield before reintroducing any
  agentic lane.
- **Sourceror-gotchas cheatsheet** appended to the AST helper output (§6).
- **Migrating existing rules to split test files** — a separate human/mechanical pass, never entangled with
  the autonomous bugfix loop.
