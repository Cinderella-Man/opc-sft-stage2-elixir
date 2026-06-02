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
row that reached solve  (success OR failed — §3.3; failed rows feed new-syntax rules)
   │
   ▼
[parse APPLIED_RULES]  any {rule, :reverted}?   (Pattern-only; a rule turned COMPILING code → non-compiling — §3.7)
   │
   ├── yes ──► [IMPLEMENTER: bugfix mode · broke-compile shape]   (NO classifier — deterministic, pre-attributed)
   │
   ▼ no
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
   └── POTENTIAL_NEW_RULE ────► [NOVELTY PRE-CHECK]  run `before` through Credence.fix in the clone (§3.9)
                                      │   already flagged/fixed? → duplicate → log no_action/duplicate/ (no model work)
                                      ▼ genuinely uncovered
                                  [IMPLEMENTER: new mode]
                                      write new rule + split tests
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
  - **Wiring (not free today):** `Config.provider_for/1` + `stage_max_tokens/1` are hard-guarded
    `when stage in [:translate, :solve]` — add `:classify` (and `:implement`, §5) to `stages` +
    `stage_max_tokens` and **relax both guards**, or `for_stage(:classify, …)` raises. Thread the stage atom
    `for_stage → Budget.record` for the per-stage cost split (§11.0 / Q8).
  - **"Thinking on" = reuse `xiaomi_mimo_2_5_pro` as-is; it's the model's *default* reasoning, not a flag.**
    Thinking is an explicit knob only for *local Qwen* (`enable_thinking`); Mimo-pro is a reasoning model by
    default (config.exs: "reasoning tokens count against the cap"). No new provider, no toggle.
- **Model: `mimo-v2.5-pro` with thinking on.** This call carries the single hardest judgment in the system —
  recognising *clean, passing, zero-issue but non-idiomatic* code. This is the one place we deliberately **pay
  for brains**. (Free local Qwen stays for solve only.)
- **Accuracy, NOT bias — the classifier IS the quality bar.** Both errors are permanent, symmetrically:
  - a false `NO_ACTION` is a permanently lost rule;
  - a false `POTENTIAL_NEW_RULE` that lands is a **permanent pollutant** — the Gate validates *mechanics*
    (touches `lib/`+`test/`, mutation test RED, suite green), **not** whether the rule is a genuine idiomatic
    improvement, so a speculative rule passes and then fires on **all future code forever** (removable only by
    a human — the Gate's pure-deletion guard blocks autonomous removal).
  - Therefore the classifier **does not "try."** It proposes only improvements it can ground in the data as
    genuinely non-idiomatic with a clear idiomatic form. **Tiny / one-off is welcome** (Credence's aim is
    *thousands* of precise rules aggregating — a real but small improvement is still a rule); **uncertain is
    `NO_ACTION`.** The downstream gates (pre-check, implementer, Gate) are correctness backstops, *not* a
    license to speculate — they don't catch a dubious-but-valid-looking rule.
- Runs on **100% of rows that reached solve — success AND failed** (preserving today's
  `orchestrator.ex:169` behavior; **not** solved-only), minus the `:reverted` deterministic lane (§3.7).
  Failed rows are the richest source of new-**syntax** rules (an unfixed Python-ism no rule caught); the task
  framing forks by outcome (§3.3). This is the new cost floor — still cheap: a `no_opportunity` row drops from
  a ~1M+ `cache_read` × ~20× multi-turn session to one ~few-K-token call. (Failed rows are a minority — most
  solve eventually — so the floor widens only marginally, and the primary goal is *more rules*.)

### 3.2 Input

The classifier is the **only** consumer of the row log. It receives:

1. **The distilled log** — coarse cut only this round: drop the Python source, the translate output, the
   round-trip output, and the reference Elixir solution. Keep the Qwen solve attempts + **every attempt's**
   Credence fix trace (before/after/`APPLIED_RULES`/issues). Rationale below (§7).
2. **`APPLIED_RULES`** — the closed set of rules that actually fired, extracted from the fix trace. Drives the
   BUGFIX closed-set validation and the option-shaping.
3. **`decisions.md` ledger** — patterns we **attempted to implement and failed**, so the classifier does not
   re-propose a known *impossible* pattern (which would cost a doomed implementer run). Injected **whole,
   uncapped**: it records *only* attempted-failures (never `no_opportunity`/`NO_ACTION`), so it stays
   near-empty by design (`ledger.ex` moduledoc). A ledger that grows large is a *smell* (too many failures),
   not a sizing problem — do not cap it.

**Explicitly NOT injected: the rule-name index.** See §3.5 — it is redundant by construction.

### 3.3 Option-shaping (deterministic prompt construction)

The set of decisions the classifier is *offered* is shaped from deterministic preconditions, so it cannot
emit a structurally impossible route:

- **`APPLIED_RULES` empty across all attempts** → no rule fired → BUGFIX is impossible → the classifier is
  offered only `POTENTIAL_NEW_RULE | NO_ACTION`.
- Otherwise → all three options.

(Future preconditions can shape the option set further; this is the first.)

**Solve-outcome forks the task framing (the classifier runs on EVERY row that reached solve — success *and*
failed, §3.1).** The solve outcome is a deterministic precondition, so it shapes the *lens*, not just the
option set:
- **Solved** → judge the **clean passing final code** for non-idiomatic residual (Pattern new-rules) + bugfix
  + lane.
- **Failed** → there is **no clean final**; judge instead for **an issue the attempts repeatedly hit that no
  existing rule fixed** (Syntax/Semantic new-rules — the `a div b` Python-ism case) + bugfix + lane. The
  pattern-residual lens is *not* offered (nothing clean to judge).
The downstream machinery (novelty pre-check, single-issue isolation, Gate, `:reverted` lane) is **identical**
across both; only the prompt framing forks.

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

> **⚠️ The "by construction" argument is necessary but NOT sufficient — it has a hole.** It assumes every
> applicable rule *already fired* during solve. That fails when the residual pattern appeared in a
> **non-compiling / non-parsing** solve attempt: Pattern rules need `Sourceror.parse_string!` to succeed, so a
> snippet carrying an *unrelated* syntax error was never run against the existing rules, and looks "uncovered"
> when a rule already covers it → a **duplicate rule**. (The Gate can't catch this: rule tests are
> module-direct and assert a specific rule name, so the mutation check goes RED via a *compile error* when the
> new rule is reverted — see §3.9 Finding.) The real guarantee is the **deterministic novelty pre-check
> (§3.9)**, which re-runs Credence on the isolated `before` snippet *now* and asks it directly. The
> construction argument explains why residuals are *usually* novel; the pre-check is what *makes it true*.

### 3.8 Phase asymmetry — phase-conditional seed + gates (read before §4–6)

Credence has **three rule phases, and they are not interchangeable.** Almost every "parse / compile / AST"
assumption in this doc is implicitly **Pattern-phase**; the other two break it. Ground truth:

| Phase | Operates on | `before` parses? | `before` compiles? | Match basis | Revert marker |
|---|---|---|---|---|---|
| **Syntax** | code that **won't parse** (Python-isms, parse errors) | **NO** | no | **string-level** `rule.fix(src)` on raw source | none |
| **Semantic** | **compiler warnings/errors** (`Code.with_diagnostics`) | yes | maybe not | diagnostic-driven, AST fix | none |
| **Pattern** | **compiling, idiomatic** code | yes | yes | `Sourceror` AST visitor | **`:reverted`** (only phase that reverts) |

Consequences threaded through the rest of the doc:

- **`:reverted` (§3.7) is Pattern-ONLY** — only Pattern has the `apply_or_revert` gate; Syntax/Semantic keep
  every change and compose. Pattern's **entry gate** (`pattern.ex:52`) skips non-compiling input, so every
  `:reverted` is **already** a genuine compiling→non-compiling broken rule (no Credence fix needed).
- **New-rule opportunities skew Pattern — but Syntax/Semantic are first-class, NOT rare.** The *final* solved
  code parses (no Syntax residual) and compiles `--warnings-as-errors` (no Semantic residual), so residual in
  the *clean final* code is Pattern. **But the classifier keeps *all* solve attempts (§7), including Qwen's
  non-parsing / non-compiling early ones** — and a Python-ism there that **no existing syntax rule caught**
  (e.g. `a div b` infix) is a legitimate **new-syntax-rule** opportunity sitting in the kept solve trace.
  Likewise a never-fixed warning pattern → new-semantic-rule. So the machinery must handle all three phases
  first-class; `pattern` is the *plurality*, not an assumption.
- **BUGFIX is phase-polymorphic** — `APPLIED_RULES` mixes all three phases, so a BUGFIX target can be any
  phase. The implementer seed + the `before` gates are therefore **phase-conditional**, built once and shared
  by both routes:
  - **Pattern** target/new → AST-dump seed (§6); `before` must parse **and** compile.
  - **Semantic** target → `before` must parse (AST available) but **need not compile**; seed centers on the
    *diagnostic* the rule keys on, not pure AST shape.
  - **Syntax** target → **no AST dump** (`before` doesn't parse — the AST helper would *raise*); seed = the raw
    before/after strings + the `Credence.Syntax.Rule` (string-level `fix/1`) exemplar; **no parse/compile gate.**

### 3.9 The deterministic novelty pre-check (the real duplicate guard)

> Runs for `POTENTIAL_NEW_RULE` only, *between* classifier and implementer. BUGFIX needs no pre-check — its
> target provably fired (it's in `APPLIED_RULES`).

**Finding (why this is mandatory, not polish).** Two facts in the live code remove every *other* dedup path:
1. Existing rule tests are **module-direct + identity-based** (`alias TheRule; assert &1.rule == :the_rule`),
   so the Gate's mutation check (revert the rule file → run the test → expect RED) passes *trivially* via a
   **compile error** when the module is deleted. The Gate gives **zero** duplicate protection.
2. The agentic flow we're deleting confirmed novelty by **reading rule files** (`credence_rule_generator.ex`:
   "scan the index… read 2-3 rule files to confirm novelty"). Deleting the index removes that, and the "by
   construction" argument has the non-compiling-attempt hole (§3.5).

So we replace LLM-read-the-rules novelty confirmation with a **deterministic behavioral coverage check**:

1. Take the classifier's `before` snippet (a self-contained `defmodule`, matching how rule tests wrap snippets).
2. Run it through **current Credence in the clone** (freshest landed ruleset): `Credence.fix(before)` + `analyze`.
3. **Purely behavioral — never a rule name:** if `result.code != before` (auto-fixed) **or** `result.issues
   != []` (flagged) → **already covered → duplicate → do NOT build.** Skip the implementer (zero LLM cost), log
   to `duplicate/` (§8). Else (untouched & unflagged) → genuinely novel → proceed to implementer new-mode.

Properties:
- **Phase-agnostic & needs no compilable input** — `Credence.fix` runs the Syntax pipeline *when parsing
  fails*, so coverage is detected even for non-parsing snippets. This is precisely why §3.8 forbids a global
  "before must compile" gate: it would break this check for Syntax.
- **Doesn't matter *why* the existing rule didn't fire during solve** (syntax error, non-parsing attempt,
  recompile lag) — we re-run Credence on the clean isolated snippet and ask directly. Deterministic ground
  truth replaces the fragile construction proof, and it closes the Q3 same-window-duplicate gap (the clone has
  every landed rule on commit).
- **Decouples dedup from the test convention** — unit tests stay conventional (module-direct); dedup is the
  pre-check's job. (Your "can't assert exact rule name" caveat is satisfied automatically — the pre-check is
  whole-pipeline behavioral and names no rule.)
- **Home:** a `mix credence.covers?` task in the clone (sibling to `mix credence.ast`, §6) — reads a snippet,
  prints `COVERED`/`NOVEL` (code changed or issues non-empty ⇒ COVERED). Dogfoolable, reusable, accepts
  non-parsing input.

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

**The orchestrator owns naming, not the model.** The classifier proposes a *semantic* `proposed_name` (§4.1);
the orchestrator resolves the first free suffix (`prefer_enum_sum.ex` taken → `prefer_enum_sum_2.ex`, module
`PreferEnumSum2`) and hands the implementer the **final** module name + exact paths. Naming is no longer
something the LLM can get wrong or explore. On collision we simply accept a fresh standalone rule and let the
human dedup later — no dropping, no special routing.

- **On-convention names, no index needed.** The catalog is overwhelmingly `no_*` (98), then `prefer_*` (7),
  `avoid_*` (5). Inject just those **three prefixes** (~5 tokens) into the classifier prompt so `proposed_name`
  stays on-brand — far cheaper than re-introducing the dropped index (§3.5), and it's a convention hint, not a
  catalog.
- **Explicit order for a NEW rule:** `classify → novelty pre-check (§3.9: pattern uncovered?) → resolve
  name + suffix → implementer`. The pre-check (pattern novelty) and the suffix-decollide (name clash) are
  independent — a genuinely novel pattern can still collide on a name a sibling took — and the pre-check runs
  **first** so a duplicate dies before any naming or implementer work.

---

### 3.7 Deterministic BUGFIX lane — `:reverted` rules (no classifier)

A Pattern rule whose `fix/2` turns **compiling code into non-compiling code** is *provably* broken (a linter
fix must preserve compilability). Credence already detects, reverts, and **attributes** this exactly in the
trace (`{rule, :reverted}`) — a deterministic, pre-attributed bug signal, **no LLM judgment, no bisection** —
so it **skips the classifier entirely**.

**Why `:reverted` is already a clean signal (no Credence behavioral change needed).** `:reverted` is
**Pattern-only** (Syntax/Semantic keep every change — that's where multi-rule *composition* happens, and it
already works). And Pattern has an **entry gate**: `Pattern.fix_with_trace` (`lib/pattern.ex:52`) **skips the
whole pipeline unless `compiles?(code_string)`** — the moduledoc states it ("Pattern rules … assume
semantically valid code. If the source does not compile, the pipeline is skipped entirely"). So:
- `run_fixable_rules` only ever runs on **compiling** input, and `apply_or_revert` reverts any fix that breaks
  compilation — keeping `source` compiling between every rule.
- Therefore **`compiles?(source)` is invariantly true** at every `apply_or_revert`, and the existing
  `not compiles?(fixed)` revert fires **only** on a genuine **compiling → non-compiling** regression.
- ⇒ Every `{rule, :reverted}` is **already** a genuine broken rule. There is **no "benign `:reverted`"** to
  filter, and **no revert-gate fix** to make. (An earlier draft of this doc proposed one, on the mistaken
  premise that Pattern runs on non-compiling code; the entry gate makes that unreachable. The composition
  concern is real but lives in Syntax/Semantic, which don't revert.)

**The one (optional) Credence nicety:** `log_diff` the `source` + reverted `fixed` in the revert branch (today
only the *success* branch logs the diff, `pattern.ex` keep-branch) so the broken before/after lands in the row
log for the implementer seed. **Visibility only — not a behavioral change**; the seed can otherwise be
reconstructed from the solve-attempt code + `APPLIED_RULES`.

**Tunex routing (orchestrator, BEFORE the classifier):**
- Parse `APPLIED_RULES`; if any `{Mod, :reverted}` → route straight to **implementer bugfix mode** (culprit =
  `Mod`, grep→path per §Q1), **skip the classifier call**. One culprit per row (≥1 → take the first; the rest
  resurface later — one decision per row stays). Bugfix sub-shape = "broke compile" (§5.1).
- Works against **current Credence as-is** — no Credence prerequisite for the lane itself.

This is strictly **additive** to the classifier flow: the 100%-classifier floor (§3.1) becomes "100% of rows
*without* a `:reverted` culprit."

## 4. The classifier output contract (the "thick spec")

We extract **maximum value from the one call** — it does heavy thinking over the whole log, and we discard the
log afterward, so the spec must carry everything downstream needs.

### 4.1 Fields

```
decision      : NO_ACTION | BUGFIX_RULE | POTENTIAL_NEW_RULE   (must be in the offered set)
rule_name     : present iff BUGFIX_RULE; must be ∈ APPLIED_RULES (a module name, §Q1)
proposed_name : present iff POTENTIAL_NEW_RULE; semantic snake_case, prefixed no_/prefer_/avoid_ (§3.6)
phase         : pattern | syntax | semantic                    (present iff a rule is proposed; plurality pattern, but syntax/semantic first-class from failed rows, §3.8/§3.3)
before        : the offending / non-idiomatic snippet          (parse/compile gate is phase-conditional, §3.8/§4.3)
fixable       : { after : <idiomatic rewrite> }  |  check_only
rationale     : one line — why this is non-idiomatic / how the existing rule over-fires
```

- **`before` is the rule's first test case** (must-fire). For fixable rules `after` is the must-not-fire +
  `fix(before) == after` assertion. For `check_only` there is no `after` (the rule will be `fix_patches/2 ->
  []`).
- **Always a full, self-contained `defmodule` — ALL phases.** Pattern/semantic snippets are full modules
  already; a **syntax** snippet is wrapped in a **module template** (it still won't *parse* — that's the issue —
  but it's a full-module-shaped string). One canonical form read identically by the novelty pre-check (§3.9),
  the test scaffold (matching Credence's own `defmodule Bad do … end` convention, Q4), and the AST helper. The
  **only** phase-conditional bit is the AST *dump* (Sourceror raises on the non-parsing syntax template → §5.3
  string seed), never the *form*.
- **🔑 `before` MUST isolate exactly ONE issue (hard contract, not a nicety).** Credence fixes **compose** —
  N syntax rules together turn garbage into compiling code, **none sufficient alone** for the full snippet. If
  `before` carries more than one issue:
  - the **novelty pre-check** (§3.9) sees a *sibling* rule fix a *co-located* issue → `result.code != before`
    → **false `COVERED`** for a genuinely novel pattern; and
  - the **Gate mutation check** reverts the target rule but a sibling still fixes its part → RED/GREEN is **not
    attributable** to the target rule.
  Both correctness properties require `before` to contain **only** the one targeted pattern, fixed by **only**
  the one rule — exactly the "tests have this specific issue only and it gets fixed" discipline. This
  generalizes to all phases but is *most acute* for syntax. Validation: see §4.3.
- **The implementer's must-fire test is built from the *exact* `before` bytes the pre-check validated** — so
  "pre-check said NOVEL" and "this test goes RED on HEAD" concern the identical input. That byte-identity is
  the thread that makes the pre-check's verdict trustworthy at Gate time.
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
===RULE_NAME===                         (BUGFIX only — the MODULE name from APPLIED_RULES, §Q1)
Credence.Pattern.PreferEnumReverseTwo
===PHASE===
pattern
===BEFORE===
<snippet>
===AFTER===           (or:  ===CHECK_ONLY===)
<snippet>
===RATIONALE===
<one line>
```

For `POTENTIAL_NEW_RULE`, swap `===RULE_NAME===` for `===PROPOSED_NAME===` (semantic snake_case, e.g.
`prefer_map_put_new`); the orchestrator owns final naming + suffix de-collision (§3.6).

### 4.3 Deterministic validation gates

Parse + validate; on failure → **one re-ask**; if still invalid → log to `var/run/classifier_errors/<idx>`.

- `decision` ∈ the **offered** set (respects option-shaping §3.3).
- `BUGFIX_RULE` ⇒ `rule_name` ∈ `APPLIED_RULES` **and** resolves to an existing `lib/<phase>/<name>.ex`.
  A name that didn't fire is *structurally impossible* → reject. (The LLM cannot send us chasing a phantom
  rule.)
- `POTENTIAL_NEW_RULE` ⇒ `phase` valid; `before` non-empty and a **full `defmodule`** (template-wrapped for
  `syntax`, §4.1). **Parse/compile checks are phase-conditional (§3.8):** `pattern` → must parse **and**
  compile; `semantic` → must parse; `syntax` → **no** parse/compile gate (targets non-parsing code; AST helper
  would raise). **Single-issue isolation (§4.1):** there is no cheap deterministic test that `before` carries
  exactly one issue (that's the classifier's job + prompt discipline), but the pre-check **operationally
  enforces** it — a multi-issue `before` tends to read `COVERED` (a sibling rule fires) and is dropped to
  `duplicate/` rather than mis-built. Then run the novelty pre-check (§3.9) — `COVERED` ⇒ `duplicate/`, no
  implementer.
- `after` parses (when fixable, and the phase isn't `syntax`); over the cap → auto-downgrade to `check_only`.

On a malformed/invalid spec we do **one** re-ask, then stop (a row we can't get a clean spec for is not worth
an implementer). The failed spec + log land in `classifier_errors/` for debugging.

**Re-ask mechanics:** a fresh `LLM.call` that **re-sends the full prompt + appends the specific validation
error** ("DECISION not in offered set" / "`before` didn't parse" / "`rule_name` ∉ APPLIED_RULES" / "missing
`===END===`"). Don't try to omit the log to save tokens — marker-fenced output makes malformation rare, the
floor call is only a few-K tokens, and the log + exact error is the most reliable path to a clean second
attempt. One retry only; second failure → `classifier_errors/`, no third try.

---

## 5. The implementer (solver-style loop — no harness, no tools)

The keystone of "less agentic": the implementer is the **same shape as the solve stage** — LLM generates →
*we* run the validator deterministically → feed failures back → retry — on raw `Tunex.LLM`, bounded retries.
The thing that made the old agent *explore* (unknown AST shape, unknown rule format, unknown layout) is
**supplied up front**, so there is nothing to explore and no need for tools.

**Where it runs (the clone, not the workspace).** The implementer writes rule + test files into the **clone**
(`Config.credence_clone()`) and runs its focused `mix test test/<phase>/<rule>_test.exs` **there** — exactly
where the old agent ran (`ClaudeCode.run(prompt, cwd: clone)`) and, critically, the **same tree the Gate then
validates** (`gate.ex` runs `mix test` in `clone`). Same tree end-to-end ⇒ the retry-loop `mix test`, the Gate
mutation check, and the full suite all see identical files — no drift. The solve workspace
(`var/run/workspace`, a path-dep to the clone) is **not** touched by the implementer.

**Serial single-writer discipline (write it down).** The clone working tree is a **serial, single-writer**
resource shared, *per row, strictly in sequence*, by: the novelty pre-check / `covers?` / AST helper
(read-only `mix run`), then the implementer (writes `lib/` + `test/`), then the Gate (writes during the
mutation snapshot, then `git reset --hard` on reject). v2 is one stream (one GPU, one clone), so there are no
races — but nothing may run the clone concurrently, and every row must leave the tree clean (commit or Gate
`discard`) before the next row starts.

**Recompile-after-commit (load-bearing, keep it).** On a successful Gate commit the new commit path **must**
call `Workspace.recompile_credence/1` (as the deleted orchestration did) so the *solve* workspace's credence
path-dep picks up the landed rule. Now *solve-quality* (fewer residuals reach the classifier), no longer
dedup-critical — the §3.9 pre-check reads the clone directly, which is fresh on commit — but dropping it
silently degrades solve coverage over a long run.

### 5.1 One engine, two modes

| | `POTENTIAL_NEW_RULE` (new mode) | `BUGFIX_RULE` (bugfix mode) |
|---|---|---|
| Target paths | new `lib/<phase>/<name>.ex` + new split tests (orchestrator-assigned, suffix-decollided) | the **existing** `lib/<phase>/<name>.ex` + its test(s), from `rule_name` |
| Seed context | rule+test exemplar + before/after AST dumps | **full source of the offending rule** + **all** `test/<phase>/<name>*_test.exs` (glob) + before AST dump |
| Test files written | **split**: `_check_test.exs` always; `_fix_test.exs` when fixable | **edit in place** — no test-split migration (see §5.4) |
| Mutation gate | new test RED without new rule | narrowed `_check` test RED with HEAD rule (over-fires → issue present → must-not-fire fails) |

The mechanics are identical: **LLM emits whole files → orchestrator writes → focused `mix test` → feed
failures back → retry (≤ `rule_gen_max_retries`) → Gate**. Do **not** fork the engine; parameterize it.

**Bugfix mode has two sub-shapes** (same engine, different seed + mutation assertion):
- **over-fire** (from the classifier) — the rule fired and produced *worse/more-verbose/wrong but compiling*
  code. Seed = the over-firing before/after; the narrowed `_check` test goes RED on the HEAD rule (issue
  present → must-not-fire fails).
- **broke-compile** (from the deterministic `:reverted` lane, §3.7) — the rule's `fix/2` turned *compiling*
  input into *non-compiling* output. Seed = "`<rule>.fix/2` produced non-compiling code on this `before`;
  narrow the match so it doesn't fire here, **or** repair the patch." Regression test asserts the rule no
  longer breaks this input (`fix(before)` compiles, or the rule no longer fires on `before`); the mutation gate
  is that test RED against the HEAD rule.

### 5.2 Whole-file emit (not patches)

Even for bugfix, the LLM returns the **complete** updated `rule.ex` + test file(s); we overwrite wholesale.
Rules are small (~60–200 lines); whole-file emit is far more reliable in a non-agentic loop than
patch-application, which is fuzzy and adds a failure mode. (Caveat: very large rules like the 552-line
`no_map_then_aggregate` make whole-file rewrite riskier — acceptable, the Gate backstops it; revisit only if
large-rule bugfixes fail in practice.)

**Output contract — a file-keyed marker scheme (N files, not solve's 2).** `parse_module_test` handles only
MODULE+TEST; the implementer emits up to 3 (new) or 1+N (bugfix) files, so use a generic `===KEY===` →
`%{key => content}` splitter (whole-file emit ⇒ each block is a complete file):

- **New mode — fixed-role markers**, orchestrator maps roles → the suffix-decollided paths it assigned (§3.6);
  the model never picks paths:
  ```
  ===RULE===          <rule.ex>
  ===CHECK_TEST===    <_check_test.exs>
  ===FIX_TEST===      <_fix_test.exs>   (omit iff check_only)
  ===END===
  ```
- **Bugfix mode — path-keyed markers** (the `test/<phase>/<name>*_test.exs` glob can be 1..N); the prompt
  injects the **exact glob filenames** so the model echoes them:
  ```
  ===RULE===
  <rule.ex>
  ===TEST:test/pattern/foo_check_test.exs===
  <content>
  ===TEST:test/pattern/foo_test.exs===
  <content>
  ===END===
  ```
- **Validation:** new → `RULE` + `CHECK_TEST` required, `FIX_TEST` iff fixable. bugfix → `RULE` = the known
  rule path; every `TEST:<path>` **⊆ the known glob set** (≥1 changed); **no new/renamed files** — this is
  exactly what *enforces* §5.4's modify-only invariant and keeps the Gate's pure-deletion/scope checks trivial.

### 5.3 Seed context = what the agent used to explore for

- **Both before + after AST dumps**, precomputed by the AST helper (§6) and passed as **arguments** to the
  loop. The loop never invokes the helper itself (keeps it non-agentic; no `mix run -e`, ever).
  **Phase-conditional (§3.8):** AST dumps apply to `pattern` (and `semantic`, which parses); for a **`syntax`**
  target the module-template doesn't parse, so the seed is the **templated before/after module strings + the
  `Credence.Syntax.Rule` string-level `fix/1` exemplar** instead of AST dumps. (The *form* is still a full
  module — §4.1 — only the dump is skipped.)
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

### 5.5 Bound — retries AND size (count alone is not enough)

The danger the rebuild fights was never "infinite turns" — it was the **growing re-sent prefix per turn**
(cost ≈ `cache_read` ∝ `final_prefix × turns`, docs `05`/`06`). A bounded *count* doesn't bound *size*:
whole-file emit (§5.2) + fed-back `mix test` on a 552-line rule re-sends a big prefix every retry. So we bound
**both**, with three rules:

- **`rule_gen_max_retries`** — a **dedicated** config knob (start ~5), *not* shared with solve's `max_retries`
  (rule vs solution authoring have different difficulty profiles; tune independently).
- **Local per-row input ceiling (NEW).** Before each retry, assemble the prompt and check its size locally
  (string length → token estimate); if it exceeds `rule_gen_input_ceiling` **or** the row's cumulative emitted
  output exceeds `rule_gen_output_ceiling`, **abort the row → `gave_up` / `escalated/`**. Pure local check,
  **zero console poll** — this is *not* the old agentic console-polling breaker (rightly dropped); it's a cheap
  string guard that kills the 552-line-rule pathology §5.2 flags. Knobs live beside `rule_gen_max_retries`.
- **Flat (non-accumulating) retry prompt.** Each retry's user prompt = **seed + the *last* attempt + the
  *last* failures only** — never the full attempt history (mirrors solve's `build_retry`, which passes only
  `previous_output` + `failures`). Keeps per-retry size flat, not quadratic.

And the fed-back failures are **trimmed, not raw**: reuse solve's `Report.format_errors` (failures only) and
clip giant compile/`mix test` dumps — the "per-turn `mix test` re-reads" §1 names as a top cost driver are
exactly what must not be re-sent verbatim.

The loop self-terminates at the retry bound or the size ceiling, whichever trips first — a bounded loop of
small, size-capped calls can't run away.

---

## 6. The AST helper (the exploration-killer)

Credence has **no AST-inspection tool today** (rules use `Macro.prewalk/postwalk` on `Sourceror.parse_string!`;
no `ast_walk`, no mix task). The old agent explored — `mix run -e` experiments — precisely to *guess* the
Sourceror tuple shape. Hand it the shape and the exploration disappears.

- **Phase scope (§3.8): the AST helper is for `pattern`/`semantic` only.** A `syntax`-phase `before` does not
  parse, so `Sourceror.parse_string!` *raises* — never run the helper on a syntax snippet; its implementer
  seed is raw strings (§5.3). The orchestrator gates on phase before invoking the helper.
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
  (Confirmed in a real row log: the reference solution + round-trip live entirely *above* the first solve
  line, and everything the classifier needs — solve attempts + every `[Validator.run]`/`[credence_fix]`/
  `APPLIED_RULES` fix trace — lives *below* it. So the cut is a single split.)
  - **Boundary = an explicit `===SOLVE_BOUNDARY===` sentinel** the orchestrator emits (one `Logger.info`)
    immediately before the solve stage; distill = "drop everything before the sentinel." A dedicated line (not
    reusing `[Solve attempt 1] generating`) decouples the judge from Solve's log wording, which can be
    refactored without silently breaking the anti-anchor cut. The sentinel is emitted unconditionally on every
    row and only post-solve rows reach the classifier, so its presence is an **invariant** — no absent-marker
    handling (it can't happen).
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
| Novelty pre-check = `COVERED` (duplicate) | **`duplicate/`** (NEW) | n/a |
| Spec malformed after one re-ask | **`classifier_errors/`** (NEW) | n/a |

**`RowLog` gains move targets.** Today it has `open`/`close` (delete)/`escalate`/`commit`. The rebuild:
`close/1`'s delete → **move to `no_action/`**; add `duplicate/1` and `classifier_errors/1` move methods
(same `filesync → remove_handler → rename` shape as `escalate/1`). **Retention knob** (default = keep
everything): `no_action/` is the bulk, holding full firehose logs — fine for a days-long run + reset; if disk
bites, retain only the *distilled classifier input + its output* there (enough to debug a false-negative).

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
| `decisions.md` **ledger** (`evolve/ledger.ex`) | **Kept** — feeds the classifier (whole, uncapped). Write-sites **move into the new router**: **implementer-failed** (≈ old `gave_up`) + **gate_reject** only. **`phantom` retires** (deterministic whole-file emit → no claim-without-diff). `duplicate/` + `classifier_errors/` do **not** ledger (never attempted; a duplicate is *solved*, not impossible). |
| Rule-name **index** | **Dropped** from the prompt (§3.5). |
| `Git.commit_and_push` to `evolution` | **Unchanged.** |
| `Workspace.recompile_credence/1` after a landed rule | **Kept — load-bearing** (§5). The new commit path must call it; keeps the solve workspace's ruleset current. |
| Implementer's working tree | **The clone** (`Config.credence_clone()`), same tree the Gate validates; serial single-writer per row (§5). |
| **`credence_failed`** escalation branch (the `06` design) | **UNBUILT — design only** (no `Config.credence_failed_clone/0`, no code; only the *local* `escalated/` dir exists today). Orthogonal to the rebuild — the rebuild's failures already land in local dirs. Kept as a separate, independent future step. |
| `summed_usage` as cost basis | **Built** (see §11) — even raw-LLM retries re-send a growing prefix; we must meter the true bucket debit. |
| Free local **Qwen** for solve | **Unchanged** — the classifier is the *only* place we pay for brains. |

---

## 10. Safety properties (why this is hard to break)

- **A BUGFIX can't chase a phantom rule** — `rule_name` must be in `APPLIED_RULES`, validated deterministically.
- **A new rule can't silently overwrite an existing one** — orchestrator-owned naming + deterministic suffix.
- **A bad rewrite can't land** — the Gate's mutation test (RED without the rule) + full-suite-green reject any
  over-aggressive narrowing or any rule that breaks the suite.
- **A bad spec can't burn an implementer** — `before`/`after` are full `defmodule`s with phase-conditional
  parse/compile gates (§3.8); the **novelty pre-check** kills duplicates/multi-issue leakage *before* the
  implementer; over-cap `after` → check-only; malformed → one re-ask → `classifier_errors/`.
- **A false `NO_ACTION` is bounded** — human-sampled audit of retained `no_action/` logs (§12), zero token cost.
- **The `:reverted` lane can't fix a healthy rule** — Pattern's entry gate (`pattern.ex:52`) skips
  non-compiling input, so its only revert is a genuine compiling→non-compiling regression. Every `:reverted`
  is therefore an already-attributed broken rule — deterministic, ~zero false-positive, no Credence change.
- **Nothing is lost to debugging** — no deletion (§8).

---

## 11. Build sequencing (each gated on a console-Δ measurement — the only ground truth)

0. **Measurement basis — the ledger undercount *is deleted with the harness*, don't port `summed_usage`.**
   The ~20–50× undercount was a CC-harness artifact: the harness re-sent the prefix every turn but the in-band
   ledger logged only one `result` event per session (that's exactly what `summed_usage` /
   `log_usage_reconciliation` in `claude_code.ex` reconstructed). The rebuild has **no multi-turn harness** —
   the classifier is *one* `LLM.call`, the implementer is *N separate* `LLM.call`s, and `LLM.call` already
   routes every call through `maybe_record_usage → Budget.record` with the full `usage` (input/output/
   cache_read/cache_creation). Prefix growth across implementer retries shows up in each retry's own `usage`.
   So **per-row bucket cost = sum of that row's recorded `LLM.call`s; nothing is hidden** and there is nothing
   to reconstruct — drop the `summed_usage` port.
   - **One-time validation (still do it):** `mix tunex.usage` ≈ console, but now **expect ~1×**, not 20–50×.
     A residual gap is provider-side cache billing, not hidden turns — a different bug.
   - **The one genuinely-new bit:** add **per-stage tagging** to `Budget.record` (today `maybe_record_usage`
     hardcodes `kind: :chat`), threading `:classify` / `:implement` / `:solve` so `mix tunex.usage`'s by-stage
     breakdown can separate classifier from implementer — the thing that makes step 6's "did we hit 4–8×, and
     what's left?" legible. *Prereq for trusting every later number; ~free.*
1. **AST helper** — `mix credence.ast` in Credence + dogfood against a known rule's snippet. Unblocks the
   implementer. **Same Credence pass (ship together — all Credence-side):** (i) `mix credence.covers?`
   behavioral novelty task (§3.9); (ii) *optional* — `log_diff` in the Pattern revert branch for seed
   visibility (§3.7). **No revert-gate fix — `:reverted` is already a clean signal (Pattern entry gate,
   `pattern.ex:52`).**
2. **Classifier** — raw `Tunex.LLM` / Mimo-pro, marker output, validation gates, option-shaping, coarse
   Python-cut distillation (`===SOLVE_BOUNDARY===` sentinel, §7), `APPLIED_RULES` + ledger inputs.
   **Config delta:** add `:classify` (+ `:implement`) to `stages` + `stage_max_tokens`; relax the
   `Config.provider_for/1` + `stage_max_tokens/1` `when stage in […]` guards; reuse `xiaomi_mimo_2_5_pro`
   (default reasoning); thread the stage atom into `Budget.record` (§3.1).
3. **Solver-loop implementer** — both modes (phase-conditional seed, §3.8) + AST-dump injection + the new
   outcome directories (`no_action/`, `duplicate/`, `classifier_errors/`). Runs in the **clone** (§5); the
   commit path calls `Workspace.recompile_credence/1`. **Wired classifier → implementer end-to-end
   immediately** (no measure-only sub-phase).
4. **`credence_failed` escalation branch** — **UNBUILT (doc-06 design, no code yet)**; independent of the
   rebuild (failures already land in local `escalated/`); can land any time, or never. Not a rebuild prereq.
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
| Classifier | One raw `Tunex.LLM` call, `mimo-v2.5-pro` + thinking, no tools, ~200-tok system prompt, on 100% of rows (minus §3.7 lane). **Accuracy not bias — it IS the quality bar** (Gate checks mechanics, not idiomatic merit; a bad landing rule pollutes all future code). Tiny-but-real welcome; uncertain → NO_ACTION; never speculate (§3.1) |
| Classifier input | distilled log + `APPLIED_RULES` + ledger; **no rule-name index** — dedup is the §3.9 pre-check, not a construction proof |
| Phase asymmetry | Syntax (non-parsing, string-level) / Semantic (warnings) / Pattern (compiling, AST). Seed + `before` gates are **phase-conditional** (§3.8); new rules are *plurality* pattern but syntax/semantic are first-class (from failed rows, §3.3); BUGFIX is phase-polymorphic |
| Novelty pre-check | `POTENTIAL_NEW_RULE` only: run `before` through `Credence.fix` in the clone (`mix credence.covers?`); `COVERED` ⇒ duplicate ⇒ `duplicate/`, skip implementer. Behavioral, names no rule, phase-agnostic, no compile gate (§3.9) |
| Output | marker-fenced thick spec `{decision, rule_name?|proposed_name?, phase, before, fixable:{after}|check_only, rationale}`; `before`/`after` are **full `defmodule`s, all phases** (syntax = module template), each **isolating exactly ONE issue** (composition: N rules rescue garbage, none alone — isolation makes pre-check + mutation gate attributable, §4.1) |
| Option-shaping | empty `APPLIED_RULES` → BUGFIX not offered. **Runs on every row that reached solve (success AND failed)**; solve outcome forks the task lens — solved → idiomatic residual; failed → unfixed syntax/semantic issue (new-syntax source) (§3.3) |
| BUGFIX | constrained to `APPLIED_RULES` (over-firing only); under-firing → NEW |
| `:reverted` lane | `:reverted` (Pattern-only) is **already** a genuine compiling→non-compiling broken rule — Pattern's entry gate (`pattern.ex:52`) skips non-compiling input, so `compiles?(source)` is invariant. → **deterministic** bugfix, **skips classifier**, **no Credence change** (§3.7) |
| NEW | **always create new**, never extend; classifier emits `proposed_name` (on-convention `no_/prefer_/avoid_`); order = classify → pre-check → resolve name+suffix → implement; orchestrator owns final naming |
| `after` complexity | capped; over-cap → auto check-only; **CHECK-ONLY is the universal fallback** |
| Validation | deterministic gates; one re-ask → `classifier_errors/` |
| Implementer | **one** solver-style loop (raw LLM, no harness/tools), parameterized new/bugfix; whole-file emit via a **file-keyed marker scheme** (new = fixed-role `RULE`/`CHECK_TEST`/`FIX_TEST`; bugfix = path-keyed `TEST:<path>` ⊆ glob, modify-only) (§5.2) |
| Implementer seed | thick spec + precomputed before+after AST dumps + exemplar (+ rule source for bugfix) |
| Split tests | new rules emit `_check`+`_fix`; bugfix edits existing tests **in place** (no migration) |
| Bound | dedicated `rule_gen_max_retries` (~5) **+ local per-row input/output ceiling** (zero console poll) + flat (non-accumulating) retry prompt + trimmed `Report.format_errors` feedback; **no console-polling breaker**; **no `max_turns`** (§5.5) |
| AST helper | `mix credence.ast` in Credence; raw + layout-stripped views; never `normalize`/unwrapped; dogfooded |
| Distillation | coarse cut **only** this round: drop everything above an explicit `===SOLVE_BOUNDARY===` sentinel (invariant — no absent-marker handling); full marker-fencing documented-not-built |
| Gate | **unchanged** (5-part backstop) |
| Ledger | kept, feeds classifier whole/uncapped (stays near-empty by design); writes on implementer-failed + gate_reject only; phantom retired; duplicate/classifier_errors don't ledger |
| No deletion | move-to-outcome-dir; new `no_action/`, `classifier_errors/`; `tunex.reset` still clears |
| Measurement | **no `summed_usage` port** — the undercount was a CC-harness artifact deleted with it; per-call `Budget.record` IS the bucket basis (expect ledger ≈ console ~1×). Add **per-stage tagging** (`:classify`/`:implement`/`:solve`). Trust console for absolutes (§11.0) |
| Shadow | human-sampled `no_action/` audit; automated second-opinion = footnote only |
| Escalation archive | `credence_failed` branch kept as-is |
| Sequencing | summed_usage → AST helper → classifier → implementer → escalation → delete old → measure |

---

## 14. Open items (tuning, not design — for live iteration, not this plan)

1. The classifier prompt's exact wording for "spot clean-but-non-idiomatic code" — the hardest judgment;
   iterate against `no_action/` audits.
1b. Prompt discipline for **single-issue isolation** of `before` (§4.1) — reducing one Python-ism out of a
   multi-issue garbage attempt is a real classifier difficulty (esp. syntax, where fixes compose). The
   pre-check catches multi-issue leakage as false-`COVERED`; tune the prompt against the `duplicate/` rate.
2. The `after` complexity-cap threshold (lines / statement count) that triggers auto check-only.
3. `rule_gen_max_retries` starting value (~5) — tune against landed-rules/attempt.
3b. `rule_gen_input_ceiling` / `rule_gen_output_ceiling` (the §5.5 local size guard) — set high enough not to
   clip a legit hard rule, low enough to kill a 552-line-rule pathology; tune against `escalated/` size logs.
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
