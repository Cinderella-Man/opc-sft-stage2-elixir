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

> **⚑ Credence-side reconciliation (2026-06-08 — read before §3.11/§5/§6).** Since this doc was written,
> the Credence clone (`main`) **independently shipped two things this plan assumed it would build, but in a
> different shape** — verified in the clone, not hypothetical. They *strengthen* the rebuild; they do **not**
> change its skeleton. The deltas:
>
> 1. **Behaviour-equivalence is now a PER-RULE TEST + a HARD meta-gate, NOT a `mix credence.equiv` task.**
>    Credence shipped `Credence.BehaviourEquivalence` (`assert_equivalent/2`, `assert_equivalent_module/2`,
>    `assert_effect_trace_equivalent/2`, `eval_outcome/2` with **strict `===`** + exception-module parity,
>    `mark_equivalence_{cosmetic,unconstructible,repair}/1`) + a curated `Credence.EquivalenceInputs` battery
>    (`term_lists`/`signed_integers`/`unicode_strings`/`single_codepoint_strings`/`multi_codepoint_strings`/
>    `stability_lists`) + a **hard** `equivalence_meta_test.exs` that fails the suite unless **every Pattern
>    rule** carries a real `<name>_equivalence_test.exs` (anti-stub: fires + rewrote + ≥3 **discriminating**
>    inputs). **Consequences:** (a) §3.11's "6th Gate check" is **subsumed** — a behaviour-diverging fix fails
>    its *own* mandatory equivalence test, which the Gate's full `mix test` already runs; no separate
>    `equiv`-on-the-built-rule plumbing. (b) §3.11's **classify-time** pre-check still needs a deterministic
>    snippet-vs-snippet check (no rule exists yet), but it is now a **thin task built ON TOP of**
>    `BehaviourEquivalence`/`EquivalenceInputs` (reuse `eval_outcome` + the shipped battery — don't reinvent).
>    (c) Every **new Pattern rule the implementer ships now MUST include an equivalence test** (§5.6) — a new
>    mandatory artifact the generator scaffolds. (d) The shipped **`mark_equivalence_repair`** tier legitimizes
>    a *behaviour-changing* "fix broken → working" family (does-not-compile / always-crashes), which §3.10's
>    blanket "absolute" framing forbade — see §3.10's repair note.
> 2. **A rule SCAFFOLD GENERATOR shipped: `mix credence.gen.rule <Name> [--type pattern|syntax|semantic]`**
>    (+ `Credence.RuleName` derive/test_path/test_module — the single name/path source of truth — and
>    `Credence.RuleScaffold`). It emits correctly-named, heredoc-fixtured, **honest-red, gate-passing**
>    skeletons (Pattern → rule + `_check_test` + `_fix_test` + **`_equivalence_test`**; Syntax → rule +
>    `_analyze_test` + `_fix_test`; Semantic → rule + `_check_test` + `_fix_test`), formats them, aborts on
>    collision. **This is the "use the generator" step (§5.0/§6.1):** the implementer no longer hand-builds
>    paths/module-names/test-shapes — the orchestrator runs the generator with the final name, then the
>    implementer **fills the red stubs**. This subsumes T5.4a's phase-conditional check-test filename and
>    de-risks every structural meta-gate.
> 3. **Syntax & Semantic rules now carry HARD meta-gates too** (`syntax_meta_test.exs` /
>    `semantic_meta_test.exs` + a `generator_meta_test.exs` pin): completeness + substance (positive +
>    negative) + **`valid_syntax?(fix(x))`** + the **fixpoint** `analyze(fix(x)) == []` + attribution. So a new
>    Syntax/Semantic rule can no longer ship inert — the implementer must emit those shapes (§5.6); the
>    generator does, by construction.
> 4. **`Credence.Assumptions` now has TWO default-on switches** — `single_codepoint_graphemes` **and**
>    `proper_lists`. §3.10/§3.12's "the one promise on" prose generalizes to "the helpful-mode promises"; the
>    dynamic `Assumptions.all()` injection (T3.1/T5.1) already handles N switches, so no design change — only
>    the shared-generator reference (§3.12) gains `proper_list/0` alongside `single_codepoint_string/0`.
>
> **Still NOT built** (Tunex's planned Credence PR, `08` Phase 1): `mix credence.ast`, `credence.covers`,
> `credence.equiv`. Build them as planned — but `credence.equiv` reuses the shipped support module (delta 1b),
> and the implementer flow gains a generator-scaffold step (delta 2). Inline notes below thread each delta into
> the section it touches.

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
[parse APPLIED_RULES]  any {rule, :reverted}?   (Pattern-only; a rule turned COMPILING code → non-compiling — §3.9)
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
   └── POTENTIAL_NEW_RULE ────► [NOVELTY PRE-CHECK]  run `before` through Credence.fix in the clone (§3.7)
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
    default (config.exs: "reasoning tokens count against the cap"). No toggle.
- **Model: configurable per-stage, default `mimo-v2.5-pro` with thinking on.** This call carries the single
  hardest judgment in the system — recognising *clean, passing, zero-issue but non-idiomatic* code. This is the
  one place we deliberately **pay for brains** (free local Qwen stays for solve only) — so the *which-brain*
  choice must be a **config knob, not a hardcode**:
  - The classifier provider resolves through the **same `stages.classify` + `TUNEX_CLASSIFY_PROVIDER`
    machinery** as translate/solve (`Config.provider_for/1`; `env_provider/1` is already generic). Switching
    models = repoint `stages.classify` at a different **provider atom** (or set the env override for a run); no
    code change.
  - **Default = `:xiaomi_mimo_2_5_pro`** (the in-bucket, no-extra-dep choice). **Alternative = a new
    `:anthropic_opus` provider** (Claude Opus 4.8 / `claude-opus-4-8` via the Anthropic API, its own
    `base_url`/`model`/secret auth header in the `providers` map + `secret_providers`). Add it to `budget.prices` too so per-stage cost
    metering (T0.2) stays honest.
  - **Why configurable, not just Mimo-pro:** the only evidence the one-shot judgment is tractable comes from
    pasting a real row log into **Claude Opus** (web chat, no tools) — it returned clean candidates + existing-
    rule examples. That validates the *task*, not **Mimo-pro one-shot**, which is the actual load-bearing
    unknown (`08` "one load-bearing unknown"). A false `NO_ACTION` is a permanently lost rule and a false
    `POTENTIAL_NEW_RULE` is a permanent pollutant (§3.1), so the classifier *is* the quality bar — and it is a
    **single cheap call per row** (not the implementer loop), making it the rational place to spend on a
    stronger model if Mimo-pro underperforms. Time + the saved `no_action/` logs (§8, §12) settle which.
  - **🔴 Wire-protocol constraint — the Opus provider MUST be an OpenAI-compatible endpoint.** `Tunex.LLM`
    speaks **OpenAI Chat Completions only**: it sends `messages:[{role:"system"},{role:"user"}]` (`llm.ex:60-64`)
    and parses `body["choices"][0]["message"]["content"]` + `usage.prompt_tokens` (`llm.ex:150-163`). Anthropic's
    **native `/v1/messages`** is a different shape (top-level `system`, `content[]` blocks, `input_tokens`,
    `anthropic-version` header) and **would not parse** — and the one Anthropic-protocol client we have (the CC
    harness) is **deleted** in this rebuild. So "same path, no adapter" (the design intent) holds **only** if
    `:anthropic_opus` points at an **OpenAI-compatible** endpoint: Anthropic's own `/v1/chat/completions`
    compat layer, or a gateway (OpenRouter / LiteLLM). Then `LLM`, `maybe_record_usage`, and `Budget` work
    untouched. (Native-Anthropic instead ⇒ a small adapter in `LLM` — reintroducing the very protocol we're
    deleting; avoid.)
  - **⚠️ Dep caveat:** pointing the classifier at Opus makes Anthropic (or the gateway) a **second paid dep**
    (CLAUDE.md's "Mimo is the only PAID dep" no longer holds for that config). It stays cheap — one few-K-token
    call/row, no harness — but it is a distinct vendor + a distinct auth that can expire, so **Preflight must
    smoke it** (§11 step 2 / `08` T0.4).
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
  - **Behaviour preservation is absolute *relative to Credence's declared assumptions* (§3.10; Credence ≥0.7.0
    "safety switches").** A proposed `after` must be output-identical to `before` for **every input the active
    `assumptions:` admit**. Tunex runs Credence in its **default (helpful)** mode (one promise on,
    `single_codepoint_graphemes`), so "every input" here means "every single-piece-character input." The two
    sub-classes now diverge: **type-changing** rewrites (charlist↔grapheme, integer vs string) stay `NO_ACTION`
    *forever* (no switch can rescue a type change), while **rare-text-divergent** rewrites (grapheme/codepoint
    count·reverse·palindrome) are **buildable as switch-gated rules** (§3.12 — Tier-1 existing switch + a
    property test from the shared generator, or Tier-2 `SWITCH_PROPOSAL`). For pattern rules, §3.11's
    deterministic `credence.equiv` check *executes* the equivalence (catching the type-change class on any
    exercised input, and confirming the minimal assumption set); the classifier quality-bar duty remains the
    backstop for non-battery inputs, eval-order, and non-pattern phases.
- Runs on **100% of rows that reached solve — success AND failed** (preserving today's
  `orchestrator.ex:169` behavior; **not** solved-only), minus the `:reverted` deterministic lane (§3.9).
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
  new rule.** We never auto-extend an existing rule (see §3.8).

### 3.5 Why no rule-name index (residual = uncovered by construction)

Credence-fix runs **all** existing rules during solve's `Validator` step 1/6, and a landed rule **recompiles**
into subsequent rows. Therefore, by the time the classifier sees the final code, every applicable existing
rule has *already fired* — where, on Credence ≥0.7.0, "all rules" means all rules **active under the current
`assumptions:` mode**. Tunex always runs the **default (helpful)** mode, never `:strict`, so switch-gated rules
(§3.10) count among "all rules" and self-suppress as residuals here too. Consequences:

- If a rule covered this pattern, the code is already fixed → idiomatic → the classifier says `NO_ACTION`
  **on the code's own merits**, with no index needed.
- Residual non-idiomatic code is, by definition, **not caught by any existing rule** → a new-rule proposal is
  *always* genuinely novel.
- BUGFIX needs only the `APPLIED_RULES` closed set, not the full catalog.
- Duplicate *names* are handled deterministically by a suffix (§3.8).

Self-suppression of duplicates was never the index's job — it is `credence-fix-runs-all-rules` +
recompile-on-land. The index only added prompt weight and a coupling point. **Dropped.**

> **⚠️ The "by construction" argument is necessary but NOT sufficient — it has a hole.** It assumes every
> applicable rule *already fired* during solve. That fails when the residual pattern appeared in a
> **non-compiling / non-parsing** solve attempt: Pattern rules need `Sourceror.parse_string!` to succeed, so a
> snippet carrying an *unrelated* syntax error was never run against the existing rules, and looks "uncovered"
> when a rule already covers it → a **duplicate rule**. (The Gate can't catch this: rule tests are
> module-direct and assert a specific rule name, so the mutation check goes RED via a *compile error* when the
> new rule is reverted — see §3.7 Finding.) The real guarantee is the **deterministic novelty pre-check
> (§3.7)**, which re-runs Credence on the isolated `before` snippet *now* and asks it directly. The
> construction argument explains why residuals are *usually* novel; the pre-check is what *makes it true*.

### 3.6 Phase asymmetry — phase-conditional seed + gates (read before §4–6)

Credence has **three rule phases, and they are not interchangeable.** Almost every "parse / compile / AST"
assumption in this doc is implicitly **Pattern-phase**; the other two break it. Ground truth:

| Phase | Operates on | `before` parses? | `before` compiles? | Match basis | Revert marker |
|---|---|---|---|---|---|
| **Syntax** | code that **won't parse** (Python-isms, parse errors) | **NO** | no | **string-level** `rule.fix(src)` on raw source | none |
| **Semantic** | **compiler warnings/errors** (`Code.with_diagnostics`) | yes | maybe not | diagnostic-driven, AST fix | none |
| **Pattern** | **compiling, idiomatic** code | yes | yes | `Sourceror` AST visitor | **`:reverted`** (only phase that reverts) |

Consequences threaded through the rest of the doc:

- **`:reverted` (§3.9) is Pattern-ONLY** — only Pattern has the `apply_or_revert` gate; Syntax/Semantic keep
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
    *diagnostic* the rule keys on, not pure AST shape — specifically the **real `%{message, position, severity}`
    captured from the failed-solve trace** (§5.3, the `[credence_fix] no rule matched diagnostic` line; `08`
    T1.3b), so `match?` keys on a genuine compiler message and the rule isn't dead in production.
  - **Syntax** target → **no AST dump** (`before` doesn't parse — the AST helper would *raise*); seed = the raw
    before/after strings + the `Credence.Syntax.Rule` (string-level `fix/1`) exemplar; **no parse/compile gate.**
    (The raw-string-seed choice is an **unverified assumption** — Sourceror's fault-tolerant parser *might*
    yield a usable error locus for a targeted seed; validate via the §6 spike before building it. `09` §3.)

### 3.7 The deterministic novelty pre-check (the real duplicate guard)

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
3. **Purely behavioral — never a rule name:** if `result.code != before` (an existing rule auto-fixed it),
   **or** `result.applied_rules != []` (a rule fired), **or** `result.issues` contains a **non-parse-error**
   issue (a check-only rule flagged it) → **already covered → duplicate → do NOT build.** Skip the implementer
   (zero LLM cost), log to `duplicate/` (§8). Else (untouched, no rule fired, only-parse-error-or-no issues) →
   genuinely novel → proceed to implementer new-mode.

> **🔴 Why NOT the naive `result.issues != []`.** `Credence.analyze` (`credence.ex:16-28`) short-circuits on
> syntax issues, but only when a syntax **rule matched** (`syntax.ex:18-19` returns `[]` for an *unmatched*
> parse failure). So a genuinely **novel non-parsing** snippet falls through to `Pattern.analyze`, which on
> unparseable input returns a synthetic **`parse_error_issue`** (`pattern.ex` `{:error, …}` branch) — non-empty
> **purely because it doesn't parse**, not because any rule covers it. A naive `issues != []` would therefore
> read **COVERED** on *every* novel syntax snippet → **no new syntax rule could ever be built** (the doc's
> "richest source of new-syntax rules", §3.3, silently dead). The coverage signal must be **"did a real rule
> engage"** — `code` changed, `applied_rules` non-empty, or a *non-parse-error* issue — never the bare
> parse-error pseudo-issue. `mix credence.covers` filters it out by issue type.

Properties:
- **Phase-agnostic & needs no compilable input** — `Credence.fix` runs the Syntax pipeline *when parsing
  fails*, so coverage is detected even for non-parsing snippets **(via `code != before` / `applied_rules`, NOT
  the parse-error issue — see the 🔴 note above)**. This is precisely why §3.6 forbids a global "before must
  compile" gate: it would break this check for Syntax.
- **Doesn't matter *why* the existing rule didn't fire during solve** (syntax error, non-parsing attempt,
  recompile lag) — we re-run Credence on the clean isolated snippet and ask directly. Deterministic ground
  truth replaces the fragile construction proof, and it closes the Q3 same-window-duplicate gap (the clone has
  every landed rule on commit).
- **Decouples dedup from the test convention** — unit tests stay conventional (module-direct); dedup is the
  pre-check's job. (Your "can't assert exact rule name" caveat is satisfied automatically — the pre-check is
  whole-pipeline behavioral and names no rule.)
- **Binary unique-TP, deliberately.** The check is "does *any* existing rule engage?" (drop if so) — i.e. a
  unique-TP = 0 reject. [`09`](09_external_research_self_evolving_rule_systems.md) **F4** (ADE `arXiv:2509.16749`,
  3-0: score rules by `½(precision + unique-TP)`) backs *rejecting redundant rules* — but a **continuous**
  unique-TP *threshold* is deliberately NOT applied at the autonomous gate: it would fight §3.8's "micro-rules
  welcome" (a tiny-but-real unique catch is still a rule). The continuous ADE score belongs at **human
  `evolution → main` review** (the `candidates.md` acceptance bar — "does this add a unique true positive?"),
  not here.
- **Home:** a `mix credence.covers` task in the clone (sibling to `mix credence.ast`, §6) — reads a snippet,
  prints `COVERED`/`NOVEL` (a real rule engaged — `code` changed, `applied_rules` non-empty, or a non-parse-error
  issue ⇒ COVERED; bare parse-error ⇒ still NOVEL). Dogfoodable, reusable, accepts non-parsing input.

### 3.8 Always-create-new + name collision

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
- **Explicit order for a NEW rule:** `classify → novelty pre-check (§3.7: pattern uncovered?) → resolve
  name + suffix → implementer`. The pre-check (pattern novelty) and the suffix-decollide (name clash) are
  independent — a genuinely novel pattern can still collide on a name a sibling took — and the pre-check runs
  **first** so a duplicate dies before any naming or implementer work.

---

### 3.9 Deterministic BUGFIX lane — `:reverted` rules (no classifier)

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

### 3.10 Behaviour preservation — absolute *relative to declared assumptions* (the master correctness invariant — overrides idiom)

> **Reframed by Credence 0.7.0 "safety switches" (`assumptions:`).** This invariant used to read "the `after`
> must be output-identical to `before` for *every* input, no exceptions." Credence now states
> behaviour-preservation **relative to a declared domain**: *"Credence never changes behaviour on any input the
> stated promises (`assumptions:`) admit."* In **`:strict`** mode zero promises are made ⇒ the admitted domain
> is *every possible input* ⇒ bit-identical output, the old iron-clad guarantee, reachable by one word. In the
> **default (helpful)** mode the curated **helpful-mode promises** are **on** — as of 2026-06-08 that is
> **`single_codepoint_graphemes`** (every character is a single codepoint: no decomposed/NFD accents, ZWJ emoji,
> flags) **and `proper_lists`** (every list's tail is a list — no improper `[1 | 2]`); read "the promise(s) on"
> generically, the set grows as Credence adds switches and Tunex reads them dynamically via
> `Credence.Assumptions.all()` (§3.12) — so a rule may also fire when its rewrite
> is output-identical *for every promise-satisfying input*, declared via `def assumptions, do:
> [:single_codepoint_graphemes]` and **proved by a mandatory StreamData property test**.
>
> **Tunex runs Credence in the default (helpful) mode everywhere** (solve Validator, the `covers` novelty
> pre-check §3.7, the Gate suite) — never `:strict` — so switch-gated rules fire and self-suppress as residuals
> exactly as for real users (§3.5).

> Binds **every** stage that emits a *behaviour-equivalence claim* — a code→code rewrite asserted to be the
> same: the **classifier** (proposes `before`/`after`, §4.1), the **implementer** (writes `fix/2`, §5), and the
> **`:reverted`/bugfix** lanes. The 5-part Gate validates *mechanics* (touches `lib/`+`test/`, mutation RED,
> suite green) — **not** behaviour identity. **§3.11 closes most of this gap for pattern rules:** a
> deterministic `mix credence.equiv` check executes `before` vs `fix(before)` across an adversarial battery, at
> classify-time **and** as a 6th Gate check, catching value / type / exception / order divergence (incl. the
> type-change class on any *exercised* input). What remains on **prompt discipline** (`08` T3.1 / T5.1) is the
> narrow residual §3.11 can't execute: a divergence only on a non-battery input, **evaluation-order / side-effect
> divergence**, and the **semantic/syntax** phases (no compilable `before`). *(One more tooth from 0.7.0: the
> clone's full suite — which the Gate runs — meta-tests that every `assumptions`-tagged rule has a property test
> and names only real switches, §10.)*
>
> **Out of scope: solve / translate.** Same as before — both author code rather than refactor it, so neither
> makes an equivalence claim. The invariant is a property of **rule fixes**, which is exactly the
> classifier/implementer surface above.

- **A fix that can change output *within the admitted domain* is not a fix.** "Correct for the common input"
  is still not good enough: a fixable rule's `after` must be output-identical for *every input the active
  promises admit* (`fix(before) == after` *and* a no-op wherever its rewrite would diverge on such input). The
  only thing 0.7.0 changes is *which* inputs count — `:strict` = all of them, helpful = the single-codepoint
  ones.
- **No check-only path at all (2026-06-04 policy, §4.1).** Earlier drafts allowed a CHECK-ONLY
  (`fix_patches/2 -> []`) fallback for fix *complexity*. **Removed.** Behaviour-*unsafety* and
  fix-*complexity* now route to the **same** place: a pattern whose only idiomatic form changes behaviour on
  admitted input → **`NO_ACTION`**; a behaviour-safe pattern that is merely hard to auto-fix → **narrow to the
  fixable core, or `NO_ACTION`**. Never a check-only stub.

- **The one principled exception — the REPAIR family (Credence's `mark_equivalence_repair`, shipped
  2026-06-08).** "Absolute behaviour preservation" has a sound carve-out Credence now formalizes: a rule whose
  **`before` has NO valid output on ANY admitted input** — it either *does not compile* (a hallucinated guard /
  missing `require`) or *always crashes* (an arg-order bug like `value |> Regex.replace(...)`, or
  `Keyword.get(l, <int>)` which the `is_atom(key)` guard rejects on every list) — is a **correction**, not a
  behaviour change, because there is no behaviour to preserve. These ship with `mark_equivalence_repair(reason)`
  (the reason must prove the broken precondition) instead of `assert_equivalent`. **For Tunex this is exactly
  the failed-row / Python-ism source** (§3.3): an `a div b`-style always-broken snippet is a repair, not a
  `NO_ACTION`. So the classifier/`credence.equiv` pre-check must **not** auto-`NO_ACTION` a `before` that
  *crashes on every battery input* — that is a repair candidate. **The mechanism (§3.11): `credence.equiv` is a
  trichotomy `EQUIVALENT | REPAIR | DIVERGES`** — it deterministically returns `REPAIR` when `before` raises on
  every admitted input and `after` succeeds, and the router proceeds to the implementer in repair sub-mode
  (the implementer emits `mark_equivalence_repair`; Syntax rules are repairs by nature and live outside the
  equivalence suite, §5.6). A
  `before` that returns a **valid-but-undesired** value on *some* input is NOT a repair — it is a behaviour
  change → narrow or `NO_ACTION` (Credence's own line: `no_map_get_sentinel` was dropped for exactly this).

**The old "FORBIDDEN: codepoint↔grapheme" class splits in two under 0.7.0 — read the split, don't blanket-ban.**
`String.to_charlist/1`·`?c`·`String.codepoints/1` work in **codepoint** space; `String.at`·`String.reverse`·
`String.length`·`String.graphemes` work in **grapheme** space. The two index spaces still diverge whenever a
character spans multiple codepoints — NFD accents (`"b́"` = `b` + U+0301, no precomposed form), ZWJ emoji
(`"👨‍👩‍👧"` = 1 grapheme / 5 codepoints), flags (`"🇵🇱"` = 1 / 2). But the *consequence* now depends on
whether the divergence is a **type change** or a **rare-text-only** difference:

- **(a) Type-changing rewrites — `NO_ACTION` *forever*, no switch can rescue.** A switch is a promise about
  *data*; no promise makes a number and a string interchangeable (Credence safety-switch decision 15).
  `Enum.at(String.to_charlist(s), i)` → `String.at(s, i)` returns an **integer** vs a **string** — it diverges
  on *every* input, incl. plain ASCII. That is not rare-text; it is a type change. Stays `NO_ACTION`, not
  check-only, not switch-gated, ever.
- **(b) Rare-text-divergent rewrites — now BUILDABLE via §3.12 (2026-06-04), no longer auto-`NO_ACTION`.** Same
  return type, diverge *only* on multi-piece characters: grapheme/codepoint **count·reverse·palindrome**, e.g.
  `length(String.to_charlist(s))` → `String.length(s)` (codepoint vs grapheme count, both integers) and
  `String.to_charlist(s) == Enum.reverse(String.to_charlist(s))` → `s == String.reverse(s)` (codepoint vs
  grapheme palindrome; flips on NFD). Credence 0.7.0 keeps exactly these as **switch-gated rules**
  (`assumptions: [:single_codepoint_graphemes]` + a property test — the shipped `no_codepoint_string_reverse`
  example *is* this). **§3.12 now generates them:** if `credence.equiv`'s minimal-set is an *existing* switch →
  **Tier-1 switch-gated rule** (implementer emits `assumptions/0` + a property test from the shared generator);
  if the residual is a clean rare-text class **no** existing switch covers → **Tier-2 `SWITCH_PROPOSAL`**
  (human-gated). Only a residual that diverges on *plain* inputs (a bug) or changes **type** (sub-class (a))
  stays `NO_ACTION`.
- **Same-space rewrites are unaffected** — `String.graphemes(s) == Enum.reverse(String.graphemes(s))` →
  `s == String.reverse(s)` is grapheme→grapheme, needs no promise, and is a normal Pattern rule (it is the
  always-safe half of the now-split `no_manual_string_reverse`).

#### Canonical prompt block (inject verbatim — classifier T3.1 & implementer T5.1)

This is the **exact** type-preservation text the new-rule prompt(s) must carry. It is already live in the
soon-to-be-deleted `credence_rule_generator.ex` `@task`; the rebuild's `classify/prompt.ex` (`08` T3.1) and
`implement/seed.ex` (`08` T5.1) must inject this same block verbatim. It encodes sub-class **(a)** above (the
type-change ban) and explicitly hands sub-class **(b)** off to the switch-gated path ("handled elsewhere /
not your call here").

```text
NEVER generate a rule whose fix changes the TYPE of the value the code produces.
A rewrite must return the same kind of value (integer, string, list, etc.) for
every input. If the "before" and "after" can ever be different types, the rule is
wrong even if it looks tidier — discard it, do not emit it.

The most common trap is codepoint↔grapheme on strings. These are NOT
interchangeable:

  - String.to_charlist/1, String.codepoints/1, ?c literals  -> work on CODEPOINTS
    (small pieces; produce INTEGERS / lists of integers)
  - String.at/1, String.length/1, String.reverse/1, String.graphemes/1,
    String.count/2                                            -> work on GRAPHEMES
    (whole characters; produce STRINGS)

Specifically BANNED — never generate these or any variant of them:

  - Enum.at(String.to_charlist(s), i)  ->  String.at(s, i)
      WRONG: left returns a codepoint INTEGER, right returns a one-character
      STRING. This is a type change, true for every input including plain ASCII.
      There is no safe fix for indexed character access off a charlist — leave
      it alone. (Do not work around the exact wording with hd(tl(...)),
      |> Enum.fetch(i), |> Enum.at(i), list comprehensions, etc. — same trap.)

Rule of thumb: if a rewrite swaps a codepoint operation for a grapheme operation
(or the reverse), and the result types differ, NEVER emit it. (A same-type
codepoint↔grapheme rewrite — e.g. a count or a reverse where both sides are
strings — is a separate, switch-gated case and is handled elsewhere; that is not
your call to make here.)
```

#### Canonical adversarial-input checklist (inject verbatim — classifier T3.1 & implementer T5.1)

This is the **second** verbatim block both new-rule prompts carry (alongside the type-change block above). It
hands the classifier/implementer the **exact nasty-input set the `evolution → main` reviewer uses** — so a
generated rule survives the reviewer's "prove correctness with nasty inputs" step on the first read, instead of
being narrowed (or bounced) there at Claude-token cost.

```text
A green test suite proves a rule DOES something, not that it is SAFE. Before you
propose an `after` (or write fix/2), run `before` and `after` against every input
below. If the rewrite gives a different answer on ANY of them, the rule is NOT
fixable as-is: narrow the match so it no-ops on that input, or emit NO_ACTION.

  - Unicode:
      * plain ASCII
      * a PRECOMPOSED accent  "é" (1 codepoint)
      * a COMBINING accent    "é" = "e" + U+0301 (2 codepoints, 1 grapheme)
      * a multi-codepoint emoji "👨‍👩‍👧" (5 codepoints, 1 grapheme)
      * a flag "🇵🇱" (2 codepoints, 1 grapheme)
  - Edge cases: empty, single element, nil, a negative index.
  - Value-KIND traps: number 7 vs char "7"; codepoints vs graphemes vs bytes.
    The result must be the SAME KIND of value — integer stays integer, string
    stays string, list stays list. A kind change is wrong even on plain ASCII
    (this is the type-change ban above, restated as an input test).
  - A variable the moved/removed code also uses elsewhere; side effects in moved
    code (IO, send, raise) that re-ordering would observably change.

Same-answer on every one of these, or it is not a fixable rule.
```

### 3.11 The deterministic behavioural-equivalence check (turns §3.10 from discipline into a gate)

> Runs for **pattern**-phase fixable rules — the plurality, and where **~every** behaviour-divergence in the
> live `followup.md` lives. The companion to §3.7: novelty asks *"does a rule already cover this?"*; equivalence
> asks *"is the proposed fix actually a no-op on behaviour?"* Both are **deterministic, execute the snippet, and
> invoke no model judgment.**

> **⚑ Reconciliation (2026-06-08): this exists in Credence now — but as a PER-RULE TEST + a HARD gate, not a
> `mix credence.equiv` task.** Credence shipped `Credence.BehaviourEquivalence.assert_equivalent/2` (compiles
> `before`/`fix(before)` as `fn`s, runs a curated `Credence.EquivalenceInputs` battery, **strict `===`** +
> exception-module parity; anti-stub: rule fires + rewrote + ≥3 **discriminating** inputs) + `assert_equivalent_module/2`
> (T2 whole-module) + `assert_effect_trace_equivalent/2` (the §3.11-phase-2 eval-order tracer — already built)
> + the `mark_equivalence_{cosmetic,unconstructible,repair}/1` opt-outs, and a **hard** `equivalence_meta_test.exs`
> demanding every Pattern rule own a real `<name>_equivalence_test.exs`. This **splits §3.11's two run-points**:
> - **The "6th Gate check" is SUBSUMED.** The Gate already runs the clone's full `mix test`; that now *includes*
>   each rule's mandatory equivalence test executing the **actual** `fix(before)` over the battery. A
>   behaviour-diverging fix the implementer wrote fails its own test → suite RED → Gate rejects. **No separate
>   `equiv`-on-the-built-rule invocation is needed** (T4.3b reduces to "the rule's equivalence test, run by the
>   Gate suite"). The implementer's job becomes *authoring a real equivalence test* (anti-stub + `===` enforced
>   by the meta-gate), seeded from `Credence.EquivalenceInputs` — the generator scaffolds the file (§5.0).
> - **The classify-time pre-check still needs a standalone check** (no rule/test exists yet — only a proposed
>   `before`/`after` string pair), so `mix credence.equiv` is still built — but as a **thin task reusing**
>   `BehaviourEquivalence.eval_outcome/2` + the `EquivalenceInputs` battery in *snippet-vs-snippet* mode (the
>   `equivalence_regression_test.exs` pattern: run two snippets directly, no rule), so the classify-time battery
>   is **byte-identical** to the one the shipped per-rule tests use. The `--assumptions` minimal-set logic
>   (below) stays.
>
> The mechanism description below is **correct as the contract**; only its *home* changed (per-rule test +
> meta-gate for the built rule; a thin `EquivalenceInputs`-reusing task for the proposal).

**Why it's needed (the evidence, not a hypothetical).** The live agentic generator *already* carries a
behaviour-preservation instruction in its `@task` — and still shipped ~25 behaviour-diverging rules
(`followup.md`), **each with a green test suite**, because the model that misjudges safety also writes the
tests that encode the misjudgment. §3.10 enforced as *discipline* (model reasoning) demonstrably leaks. The fix
is to stop trusting reasoning and **execute** `before` vs `fix(before)`.

**The duality that makes it work.** The exact property that makes these rules unsafe — operands are **bare,
runtime-bound variables** (`followup.md` repeats "list & index are always variables", "map arg is always a
bare variable") — is precisely what makes them **differentially testable**: substitute an adversarial battery
into those variables and run both sides.

**Mechanism — `mix credence.equiv` (new Credence task, sibling to `credence.ast` / `credence.covers`).**
**⚑ Run-env caveat (2026-06-08):** `Credence.BehaviourEquivalence` + `Credence.EquivalenceInputs` live in
`test/support/` (`elixirc_paths(:test)` only), so the reused `eval_outcome/2` + battery are **not on the `:dev`
code path**. Tunex therefore shells **`MIX_ENV=test mix credence.equiv …`** in the clone (a separate
`_build/test`, warmed at preflight/first-run alongside the `:dev` build that `covers`/`ast` use). No
Credence module-home change — the task resolves the support modules because `test/support` is compiled under
`:test` (test `*_test.exs` files are *not* compiled by a plain task, so this stays cheap). Given a `before`
snippet + the rule:
1. Compile `before` as a module; compute `after = Rule.fix(before)`; **compile `after`** (a non-compiling
   `after` — an unbound var from a dropped binding, e.g. `no_destructure_reconstruct` / `no_manual_frequencies`
   / `no_manual_enum_uniq` — fails here immediately).
2. Call each public function with a **fixed adversarial battery** (the §3.10 checklist made concrete, matched
   to arity): `[]`, `[x]`, `[x, y, z]`, a `Range`, a **>32-key map**, a **present-key map**, `nil`, `-1`, `0`,
   `7`, `"7"`, `"10"`, ASCII / combining-accent / multi-codepoint-emoji / flag strings, a side-effecting closure.
   **⚑ Reuse, don't reinvent:** this battery is exactly the shipped `Credence.EquivalenceInputs` dimensions
   (`term_lists`/`signed_integers`/`unicode_strings`/`single_codepoint_strings`/`multi_codepoint_strings`/
   `stability_lists`); the classify-time task picks the dimension(s) matching the rule's risk, identical to how
   the per-rule equivalence tests do. Comparison is **strict `===`** (catches `6 == 6.0` value-kind drift) +
   exception-module parity — Credence's `eval_outcome/2` semantics, not `==`.
3. Classify the outcome into a **trichotomy** (the task is the authority — §3.10 repair carve-out is
   *executed*, not reasoned):
   - **`EQUIVALENT`** — `before(input) ≡ after(input)` (same value under strict `===`, or the same exception
     class) for **every** battery input (+ the minimal switch set, §3.12).
   - **`REPAIR`** — `before` **raises on every** battery input *and* `after` returns `{:ok, _}` on ≥1. The
     `before` has no valid output on any admitted input, so the rewrite is a **correction**, not a behaviour
     change (§3.10 repair family). The verdict carries the evidence (exception class + `N/N raised`) so the
     implementer can write the mandatory `mark_equivalence_repair(reason)` reason string. (At classify-time
     only the *always-crashes* repair flavour is reachable — the *does-not-compile* `unconstructible` flavour
     fails §4.3's Pattern "must compile" gate and never gets here.)
   - **`DIVERGES`** — anything else: `before` produced a **valid value on some input** that `after` disagrees
     with (a real behaviour change), or a non-compiling `after`.
4. Print `EQUIVALENT` / `REPAIR <exc> <n>/<n>` / `DIVERGES <input> <before_result> <after_result>` —
   deterministic, dogfoodable, names no rule. **Fixed battery, NOT StreamData** — for determinism (resume-safe,
   reproducible logs).

**Assumption-aware (the §3.12 hook).** `credence.equiv` takes `--assumptions` and runs in that Credence mode,
**filtering the battery to the admitted domain** (a `single_codepoint_graphemes` rule drops the
combining-accent / emoji / flag inputs, keeps the rest). Run under `:strict` + each registered switch, it
reports the **minimal switch set** that makes `before ≡ fix(before)` (∅ = no-promise; a set = switch-gated;
"none works" = bug-or-new-switch). This is what lets §3.12 lift the §15 rare-text deferral *without* weakening
the gate — the promise only ever removes promise-violating inputs, never the plain ones (Credence dec. 6a).

**Two run-points (reuse it, exactly like `covers`):**
- **Classify-time pre-check** — on the classifier's proposed `before`/`after`, *before* building. `DIVERGES`
  ⇒ the spec is behaviour-changing ⇒ **`NO_ACTION`** (log → `behaviour_diverged/`), **zero implementer spend**.
  Kills the bad *idea* cheaply (most `followup.md` greenfield rejections). `REPAIR` ⇒ **proceed** to the
  implementer in **repair sub-mode** (it emits `mark_equivalence_repair` instead of `assert_equivalent`, §5.6)
  — this is the mechanism that keeps §3.10's repair carve-out from being silently swallowed by the gate.
  `EQUIVALENT` ⇒ proceed (no-promise or switch-gated per the minimal set).
- **6th Gate check — now SUBSUMED by the mandatory per-rule equivalence test (2026-06-08).** The check on the
  **actual** `fix(before)` (catching an implementer that **broadened the match** onto a diverging input — most
  of the *delta* rejections: `no_explicit_sum_reduce`, `no_doc_false_on_private`, `no_grapheme_palindrome_check`,
  …) is no longer a *separate* `credence.equiv` invocation. Credence's hard `equivalence_meta_test.exs` forces
  the rule to carry a `<name>_equivalence_test.exs` whose `assert_equivalent` runs the **actual** `fix(before)`
  over the battery with strict `===`; the Gate already runs the full `mix test`, so a broadened/diverging fix
  fails its own equivalence test → suite RED → Gate reject → `escalated/`. The implementer must therefore
  **author** that test (seeded from `EquivalenceInputs`) — and the anti-stub checks (fires + rewrote + ≥3
  discriminating inputs) + the meta-gate's no-skeleton/real-assert rules stop it faking a green one.

**Coverage (measured against the live `followup.md`):** catches **~22 of ~27** — every value / exception / type
(codepoint↔grapheme) / order (>32-key map) / compile divergence in that file. It is what converts §3.10 from
*discipline* into a real gate **for pattern rules.**

**Honest limits (these stay on §3.10 prompt discipline + human `evolution → main` review):**
- **Evaluation-order / side-effect-count** divergence (`no_cond_two_clauses` — cond double-evaluates its guard
  operands; `no_doc_false_on_private` — `@doc` arg side effects). A *value* battery doesn't construct
  side-effecting operands. **Phase-2 enhancement:** instrument operands with an evaluation tracer and compare
  call counts (§14). Until then, discipline-only.
- **Semantic / syntax phases** — `before` doesn't compile, so it can't execute; the check is **pattern-only**
  (which is where ~all `followup.md` failures are).
- **T1 expression-level only at classify-time (verified building it, 2026-06-08).** The shipped `credence.equiv`
  compiles `fn <vars> -> expr end` and the `EquivalenceInputs` dims are flat single-arg lists — so the
  classify-time check is **expression-level, single-var** (multi-var needs an explicit `--inputs-file`). A
  **module-structural (T2)** rewrite (inline-defp, case→heads, cross-statement) has no self-contained callable
  expression, so it **skips** the classify-time gate; its safety net is the built rule's mandatory
  `_equivalence_test`, which IS T2-capable (`assert_equivalent_module`) and runs in the Gate suite. So the
  classify-time equiv is best-effort over T1; T2 is caught at the Gate, not before the build.
- **Battery-completeness** — a divergence *only* on an input not in the battery slips through. The battery is a
  tuning item (§14); **seed it from the `followup.md` triggers** so every known failure class is represented.

**Self-check reinforcement (the seatbelt — cheap, upstream of the gate).** Make the classifier prompt (`08`
T3.1) *require* enumerating the battery and computing `{input, before, after, before == after}` for each as an
explicit reasoning step before proposing, and the implementer (`08` T5.1) likewise before emitting `fix`. This
kills many bad proposals before the deterministic gate runs (saving the build) — **but it is reasoning, so it
is NOT the safety net** (it is the same mechanism that produced `followup.md`). `credence.equiv` is the net.
Belt **and** airbag.

### 3.12 Assumption-aware generation & switch discovery (propose-with-evidence)

> Lifts the §15 deferral **partially** (decided 2026-06-04, autonomy = *propose-with-evidence*). Credence 0.7.0
> "safety switches" let a rule be **partially** behaviour-equivalent — identical on every input a declared
> promise (`assumptions/0`) admits, a no-op when the promise is off (§3.10). This unlocks the
> **rare-text-divergent** class §3.10(b) used to send to `NO_ACTION`. Two capabilities, deliberately split by
> risk.

**The reframe (why this is safe, not a loophole).** An assumption is **a restriction of §3.11's battery**, not
a weakening of it (§3.11 hook). For a rule tagged `assumptions: [:single_codepoint_graphemes]` the battery
**drops the promise-violating inputs** (combining accents, ZWJ emoji, flags) and **keeps everything else**
(`[]`, `nil`, `-1`, negative ints, big maps, ASCII). So Credence's decision **6a** — *"shrink the rule first,
lean on a promise second; a promise covers only the rare-text residual, never a plain bug"* — is enforced
**mechanically**: a switch-gated rule that diverges on any *non*-rare-text input is still caught by the
restricted battery. **A switch can never hide a bug.**

#### Tier 1 — use EXISTING switches (build now)
A contained lift of §15, every part reusing something that already exists:
- **Registry injection** — inject `Credence.Assumptions.all()` (switch **names + summaries**) into the
  classifier (`08` T3.1) and implementer (`08` T5.1) prompts — a tiny dynamic block, like the
  `no_/prefer_/avoid_` prefixes. The harness now *knows which promises it may lean on.*
- **Classifier** may add an `assumptions: [...]` field (existing switch names only) to a proposal; the §4.3
  gate rejects an unknown name (`⊆ Assumptions.names()`).
- **`credence.equiv` is the authority** — it *confirms/corrects* the tag to the **minimal** switch set
  (a rule tagged with a switch it doesn't need, or needs more than, is fixed deterministically).
- **Implementer** emits `def assumptions, do: [...]` **plus** a `<Rule>PropertyTest` — but **authors NO
  generator**: it reuses Credence 0.7.0's **shared, honesty-tested** generator for the relevant switch
  (`AssumptionGenerators.single_codepoint_string/0` for `single_codepoint_graphemes`, `proper_list/0` for
  `proper_lists` — one per switch, picked by the tag), so the property test is a **fixed template parameterized
  by before/after + switch**, not novel StreamData authoring (the part §15 rightly feared). Credence's 0.7.0 meta-tests (every tagged rule has a loadable `<Rule>PropertyTest`;
  every `assumptions/0 ⊆ names()`) then gate it at the **Gate** for free.
- **Recovers** the pure rare-text rejections in `followup.md` — `no_codepoint_string_reverse` (Credence's own
  example #2), `no_grapheme_palindrome_check`, `avoid_graphemes_enum_count_with_predicate` (after shrink-first)
  — while §3.11's strict battery keeps rejecting genuine value/type divergences (`no_integer_to_string_length`,
  the type-changes). Clean split, no overlap.

#### Tier 2 — DISCOVER new switches (propose-with-evidence; HUMAN-gated)
A new switch is **not** a new rule: it is a **global default-policy change on a shared file**
(`lib/assumptions.ex`) whose safety rests on a judgment about the *whole population's runtime data* — which the
harness **never sees** (it sees code, not the strings the code will process). And authoring a correct generator
(one that emits *only* promise-satisfying strings) is the exact trap Credence's plan warns about (a buggy
generator makes every proof pass for nothing). So **the harness never creates a switch.** Instead:
- When `credence.equiv` reports "diverges under all registered switches" **and** the classifier judges the
  residual a **clean rare-text class** (not a value/type bug), the classifier emits a **`SWITCH_PROPOSAL`**
  (decision, §4.1): the proposed promise (name + one-line summary + suggested default), the rule it would
  unblock, the divergence class + the failing input. **Neither a built rule nor `NO_ACTION`** — a *would-be
  rule pending a switch*, logged to **`switch_proposals/`** (§8).
- **The evidence the harness uniquely provides = DEMAND, not data-frequency.** It can't measure "how often does
  decomposed-accent text appear at runtime" (no runtime data). It **can** count how many **distinct rule
  proposals** the same promise would unblock across the 118k-row walk — *demand* (code-pattern frequency, which
  is exactly what it sees). A periodic aggregation over `switch_proposals/` clusters by proposed promise and
  ranks by that count. **The population-safety call ("would most Phoenix apps accept this?") stays human** — the
  harness hands over ranked demand + the classifier's reasoning; the human ratifies by writing the switch +
  generator + CHANGELOG in Credence (a manual PR, per Credence's own §16/§18 teeth). Next run, Tier 1 picks the
  new switch up automatically.
- **The harness touches `lib/assumptions.ex` NEVER** — consistent with shared-files-out-of-scope (review-loop
  Decision 2) and the global-default risk.

## 4. The classifier output contract (the "thick spec")

We extract **maximum value from the one call** — it does heavy thinking over the whole log, and we discard the
log afterward, so the spec must carry everything downstream needs.

### 4.1 Fields

```
decision        : NO_ACTION | BUGFIX_RULE | POTENTIAL_NEW_RULE | SWITCH_PROPOSAL   (must be in the offered set)
rule_name       : present iff BUGFIX_RULE; must be ∈ APPLIED_RULES (a module name, §Q1)
proposed_name   : present iff POTENTIAL_NEW_RULE; semantic snake_case, prefixed no_/prefer_/avoid_ (§3.8)
phase           : pattern | syntax | semantic                  (present iff a rule is proposed; plurality pattern, but syntax/semantic first-class from failed rows, §3.6/§3.3)
before          : the offending / non-idiomatic snippet        (parse/compile gate is phase-conditional, §3.6/§4.3)
after           : <idiomatic rewrite>   (REQUIRED whenever a rule is proposed — there is NO check-only path; narrow `before` to a fixable core or emit NO_ACTION, §4.1)
assumptions     : [] | [<existing switch name>, …]   (§3.12 Tier 1; existing switches ONLY, ⊆ Assumptions.names(); credence.equiv confirms/corrects to the minimal set; [] = no-promise = strict-safe)
proposed_switch : present iff SWITCH_PROPOSAL; {name, summary, default, divergence_class} — the promise that would unblock this rule, for HUMAN ratification (§3.12 Tier 2)
rationale       : one line — why this is non-idiomatic / how the existing rule over-fires
```

- **`before` is the rule's first test case** (must-fire); **`after` is always present** — the must-not-fire
  case + the `fix(before) == after` assertion. **There is NO check-only path (2026-06-04 policy):** every
  proposed rule has a real `fix_patches/2`. A pattern with no safe auto-fix even on a narrow core is
  **`NO_ACTION`**, never a `fix_patches/2 -> []` stub.
- **🔑 `after` MUST be behaviour-identical to `before` for EVERY input the active assumptions admit (hard
  contract — §3.10, Credence ≥0.7.0).** Not "correct for the shown snippet" — a true refactor whose rewrite
  produces the same output on *all admitted* inputs (Tunex's default helpful mode = every single-codepoint
  input). If the only idiomatic form would change behaviour on *some admitted* input, the case is **not
  fixable** and is **`NO_ACTION`** (there is no check-only fallback — §4.1) — **unless** a declared assumption
  admits it (§3.12). The codepoint↔grapheme class (§3.10) is the canonical trap, now read in two parts:
  **type-change** rewrites (e.g. `Enum.at(String.to_charlist …)` → `String.at`) are `NO_ACTION` *forever* (no
  switch rescues a type change); **rare-text-divergent** rewrites (count·reverse·palindrome) are **buildable as
  switch-gated rules** — tag `assumptions: [<existing switch>]` (§3.12 Tier 1), or emit `SWITCH_PROPOSAL` if no
  switch covers the class (Tier 2). This judgment is now **largely deterministic**: `credence.equiv` (§3.11)
  reports the minimal assumption set that makes `before ≡ fix(before)`, so "no-promise vs switch-gated vs bug"
  is mostly computed, not reasoned (the residual judgment is "clean rare-text class vs plain bug", §3.12).
- **Always a full, self-contained `defmodule` — ALL phases.** Pattern/semantic snippets are full modules
  already; a **syntax** snippet is wrapped in a **module template** (it still won't *parse* — that's the issue —
  but it's a full-module-shaped string). One canonical form read identically by the novelty pre-check (§3.7),
  the test scaffold (matching Credence's own `defmodule Bad do … end` convention, Q4), and the AST helper. The
  **only** phase-conditional bit is the AST *dump* (Sourceror raises on the non-parsing syntax template → §5.3
  string seed), never the *form*.
- **🔑 `before` MUST isolate exactly ONE issue (hard contract, not a nicety).** Credence fixes **compose** —
  N syntax rules together turn garbage into compiling code, **none sufficient alone** for the full snippet. If
  `before` carries more than one issue:
  - the **novelty pre-check** (§3.7) sees a *sibling* rule fix a *co-located* issue → `result.code != before`
    → **false `COVERED`** for a genuinely novel pattern; and
  - the **Gate mutation check** reverts the target rule but a sibling still fixes its part → RED/GREEN is **not
    attributable** to the target rule.
  Both correctness properties require `before` to contain **only** the one targeted pattern, fixed by **only**
  the one rule — exactly the "tests have this specific issue only and it gets fixed" discipline. This
  generalizes to all phases but is *most acute* for syntax. Validation: see §4.3.
- **The implementer's must-fire test is built from the *exact* `before` bytes the pre-check validated** — so
  "pre-check said NOVEL" and "this test goes RED on HEAD" concern the identical input. That byte-identity is
  the thread that makes the pre-check's verdict trustworthy at Gate time.
- **🔑 No check-only — narrow to a fixable core, or `NO_ACTION` (2026-06-04 policy; overrides every earlier
  "CHECK-ONLY is the universal fallback" line).** We **no longer emit non-fixable rules at all.** Every proposed
  rule MUST carry a real `after` / `fix_patches`. The discipline mirrors the `evolution → main` reviewer's bar
  verbatim, so a generated rule passes its read on the first pass: **either** *make* the rule fixable by
  **narrowing `before` to its safe core** — fire only on the cases that have a same-answer fix, write the fix
  for exactly those, and keep the dropped cases as explicit "no issue" `_check` tests so the safety choice is
  locked in — **or**, if **no** input is safe to fix even for a narrow core (or the only fix changes a value's
  **type**), **don't propose it: `NO_ACTION`.** This deletes the `unfixable.md` lane *at the source*: the review
  loop used to auto-file constant-`[]` stubs to `unfixable.md` and drop them; the generator now never produces
  one, so the downstream reviewer never spends Claude tokens re-judging a stub.
- **Complexity cap on `after` (routes to `NO_ACTION`, never check-only).** A sprawling `after` is
  untrustworthy. If the proposed `after` blows a deterministic ceiling (> N lines / multi-statement — threshold
  a tuning item, §10), the classifier must **narrow to a simpler fixable core**; if it can't, the row is
  **`NO_ACTION`** (an un-narrowable sprawling fix is not a rule). The cap is a backstop against an over-broad
  `after` — it no longer downgrades to a check-only rule, because that path is gone.

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
===AFTER===           (REQUIRED — every proposed rule is fixable; there is no ===CHECK_ONLY=== marker)
<snippet>
===ASSUMPTIONS===     (OPTIONAL — omit or empty = no-promise; else existing switch names, §3.12 Tier 1)
single_codepoint_graphemes
===RATIONALE===
<one line>
```

For `POTENTIAL_NEW_RULE`, swap `===RULE_NAME===` for `===PROPOSED_NAME===` (semantic snake_case, e.g.
`prefer_map_put_new`); the orchestrator owns final naming + suffix de-collision (§3.8). For a
**`SWITCH_PROPOSAL`** (§3.12 Tier 2 — `credence.equiv` diverges under *all* registered switches but the residual
is a clean rare-text class) there is no `===AFTER===`/build; instead a `===PROPOSED_SWITCH===` block
(`name` · `summary` · `default` · `divergence_class`) + the `===BEFORE===` it would unblock → logged to
`switch_proposals/` for a human, never built.

### 4.3 Deterministic validation gates

Parse + validate; on failure → **one re-ask**; if still invalid → log to `var/run/classifier_errors/<idx>`.

- `decision` ∈ the **offered** set (respects option-shaping §3.3).
- `BUGFIX_RULE` ⇒ `rule_name` ∈ `APPLIED_RULES` **and** resolves to an existing `lib/<phase>/<name>.ex`.
  A name that didn't fire is *structurally impossible* → reject. (The LLM cannot send us chasing a phantom
  rule.)
- `POTENTIAL_NEW_RULE` ⇒ `phase` valid; `before` non-empty and a **full `defmodule`** (template-wrapped for
  `syntax`, §4.1). **Parse/compile checks are phase-conditional (§3.6):** `pattern` → must parse **and**
  compile; `semantic` → must parse; `syntax` → **no** parse/compile gate (targets non-parsing code; AST helper
  would raise). **Single-issue isolation (§4.1):** there is no cheap deterministic test that `before` carries
  exactly one issue (that's the classifier's job + prompt discipline), but the pre-check **operationally
  enforces** it — a multi-issue `before` tends to read `COVERED` (a sibling rule fires) and is dropped to
  `duplicate/` rather than mis-built. Then run the novelty pre-check (§3.7) — `COVERED` ⇒ `duplicate/`, no
  implementer.
- `after` is **present and parses** (the phase isn't `syntax`); a **missing `after` is an invalid spec** →
  re-ask. Over the cap → the classifier should have narrowed; an un-narrowed over-cap `after` ⇒ **`NO_ACTION`**
  (no check-only downgrade — that path is gone, §4.1).
- **`assumptions` (§3.12 Tier 1):** every name ⊆ `Credence.Assumptions.names()` (an unknown switch ⇒ invalid →
  re-ask — the classifier may NOT invent a switch via this field; that's `SWITCH_PROPOSAL`). The tag is
  **advisory** — `credence.equiv --assumptions` is the authority and **corrects it to the minimal set** (a rule
  tagged with a switch it doesn't need is shipped no-promise; one that still diverges under the tagged switch is
  rejected). **`SWITCH_PROPOSAL`** ⇒ no build: validate `proposed_switch` shape, log → `switch_proposals/` with
  demand evidence (§3.12 Tier 2), never enters the implementer.

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
resource shared, *per row, strictly in sequence*, by: the novelty pre-check / `covers` / AST helper
(read-only `mix run`), then the implementer (writes `lib/` + `test/`), then the Gate (writes during the
mutation snapshot, then `git reset --hard` on reject). v2 is one stream (one GPU, one clone), so there are no
races — but nothing may run the clone concurrently, and every row must leave the tree clean (commit or Gate
`discard`) before the next row starts.

**Recompile-after-commit (load-bearing, keep it).** On a successful Gate commit the new commit path **must**
call `Workspace.recompile_credence/1` (as the deleted orchestration did) so the *solve* workspace's credence
path-dep picks up the landed rule. Now *solve-quality* (fewer residuals reach the classifier), no longer
dedup-critical — the §3.7 pre-check reads the clone directly, which is fresh on commit — but dropping it
silently degrades solve coverage over a long run.

### 5.0 Scaffold first — run the generator, then fill the red stubs (2026-06-08)

> **The "use the generator" step.** Credence shipped `mix credence.gen.rule <Name> [--type pattern|syntax|semantic]`
> (+ `Credence.RuleName` as the single name/path source of truth + `Credence.RuleScaffold`). The implementer
> **no longer hand-constructs file paths, module names, or test scaffolds** — that was a per-file failure mode
> and a drift point against the meta-gates. Instead:

1. **Orchestrator resolves the final name + suffix** (§3.8 — `proposed_name` → first free `_N`), then shells
   `mix credence.gen.rule <FinalPascalName> --type <phase>` **in the clone**. The generator writes
   correctly-named, **honest-red, gate-passing** skeletons, `mix format`s them, and **aborts (writes nothing)
   on any path collision** — which doubles as a deterministic name-collision backstop alongside §3.8's suffix
   resolver. (`RuleName` is now the authority for *every* path/module the orchestrator would otherwise hand-type,
   so **T5.4a's phase-conditional check-test filename is handled by the generator** — pattern/semantic →
   `_check_test.exs`, syntax → `_analyze_test.exs` — not by Tunex logic.)
1b. **★ Read the generated files back and inject their full contents into the implementer seed (§5.3).** This is
   the explicit "send the scaffold as context" step: the stub `rule.ex` + every generated test file becomes the
   verbatim template the fill pass preserves (exact module names, file boundaries, heredoc fixtures, the
   gate-passing test shapes). It is a distinct orchestrator action between "run the generator" (step 1) and "the
   model fills" (step 3) — not an implicit side effect of wiring (a).
2. **The generated stubs already pass the structural meta-gates** (naming, triplet/quad completeness, positive
   + negative shapes, whole-string `==` fix, heredoc fixtures, no parser calls, the Pattern `_equivalence_test`
   existence, the Syntax/Semantic `valid_syntax?`/fixpoint/attribution shapes) — but **fail their own runtime
   assertions** against the empty stub (the positive `flagged?`, the `fix` transform, the equivalence
   "rule must fire" precheck). This is the honest-red contract: structure green, behaviour red.
3. **The implementer's job is the FILL pass** — make the red assertions green: write `check/2` + `fix_patches/2`
   (or `analyze`/`fix` for syntax, `match?`/`to_issue`/`fix` for semantic), replace the placeholder fixtures
   with the spec's `before`/`after` (heredocs) — **for semantic, also replace the stub `diag` with the real
   captured `%{message, position, severity}` (§5.3) and key `match?` on it** — and replace the
   `_equivalence_test` stub's literal `inputs:`
   TODO with the right `Credence.EquivalenceInputs` dimension(s) for the rule's risk class (or, for the rare
   non-preserving rule, swap `assert_equivalent` for the correct `mark_equivalence_*` per §5.6).

**How this meshes with whole-file emit (§5.2).** Two equivalent wirings; pick one at build time:
- **(a) Generate-then-fill (preferred):** the generated files are part of the implementer's *seed* (their exact
  shape is the template); the model emits the **whole** filled files via the role markers (§5.2), overwriting
  the stubs. The generator's value is that the seed now carries the **exact gate-passing shape** to preserve, so
  a wholesale rewrite can't silently drop a required test shape (the meta-gate + the focused `mix test` catch it
  if it does).
- **(b) Generate-only-for-paths:** run the generator purely to establish paths/names, then overwrite. Same end
  state; (a) is strictly better because it also teaches the model the shape.

Either way the **generator output is the contract** — the orchestrator does not invent paths, and the role
markers (§5.2) map onto the generator's file set (now **including** the Pattern `EQUIVALENCE_TEST`, §5.6).

> **⚠️ New dirty-tree path (the generator writes BEFORE the fill loop).** Unlike the old flow — where the
> implementer only touched the clone tree when it *emitted* files — `gen.rule` (T5.4) writes stub `lib/`+`test/`
> files up front. The pre-checks that *reject* (novelty `COVERED` → `duplicate/`; `credence.equiv` `DIVERGES`
> → `behaviour_diverged/`) all run **before** the generator, so they leave a clean tree. But an **implementer
> abort *after* scaffolding** (`gave_up` / size-ceiling / implementer-failed) has **no Gate** to clean up, so
> the router MUST call `Gate.discard(clone)` (`git reset --hard HEAD` + `clean -fd`, the existing primitive) on
> every post-scaffold abort path — otherwise the orphan generator stubs pollute the next row's tree (which the
> serial single-writer invariant, §5, forbids).

### 5.1 One engine, two modes

| | `POTENTIAL_NEW_RULE` (new mode) | `BUGFIX_RULE` (bugfix mode) |
|---|---|---|
| Target paths | new `lib/<phase>/<name>.ex` + new split tests (orchestrator-assigned, suffix-decollided) | the **existing** `lib/<phase>/<name>.ex` + its test(s), from `rule_name` |
| Seed context | rule+test exemplar + before/after AST dumps | **full source of the offending rule** + **all** `test/<phase>/<name>*_test.exs` (glob) + before AST dump |
| Test files written | **split**: a check test always (pattern/semantic → `_check_test.exs`; syntax → `_analyze_test.exs`, §5.4) **+ `_fix_test.exs` always** (every rule is fixable, §4.1) — both to §5.6's exact shape | **edit in place** — no test-split migration (see §5.4) |
| Mutation gate | new test RED without new rule | narrowed `_check` test RED with HEAD rule (over-fires → issue present → must-not-fire fails) |

The mechanics are identical: **LLM emits whole files → orchestrator writes → focused `mix test` → feed
failures back → retry (≤ `rule_gen_max_retries`) → Gate**. Do **not** fork the engine; parameterize it.

**Bugfix mode has two sub-shapes** (same engine, different seed + mutation assertion):
- **over-fire** (from the classifier) — the rule fired and produced *worse/more-verbose/wrong but compiling*
  code. Seed = the over-firing before/after; the narrowed `_check` test goes RED on the HEAD rule (issue
  present → must-not-fire fails).
- **broke-compile** (from the deterministic `:reverted` lane, §3.9) — the rule's `fix/2` turned *compiling*
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

- **New mode — fixed-role markers**, orchestrator maps roles → the suffix-decollided paths it assigned (§3.8);
  the model never picks paths. The `CHECK_TEST` role → a **phase-conditional** filename (pattern/semantic →
  `_check_test.exs`, syntax → `_analyze_test.exs`; §5.4):
  ```
  ===RULE===              <rule.ex>
  ===CHECK_TEST===        <_check_test.exs / syntax: _analyze_test.exs>
  ===FIX_TEST===          <_fix_test.exs>   (ALWAYS — every rule is fixable, §4.1; no check-only)
  ===EQUIVALENCE_TEST===  <_equivalence_test.exs>   (PATTERN ONLY — mandatory, §5.6; the hard
                          equivalence_meta_test gate fails the Gate suite without it. syntax/semantic
                          omit it — they carry the §5.6 valid_syntax?/fixpoint/attribution shapes instead)
  ===PROPERTY_TEST===     <_property_test.exs>   (PATTERN, iff the spec carries assumptions — §3.12 Tier 1)
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
- **Validation:** new → `RULE` + `CHECK_TEST` + `FIX_TEST` **all required** (every rule is fixable — §4.1; a
  missing `FIX_TEST` is an invalid emit, not a check-only rule); **for a Pattern rule, `EQUIVALENCE_TEST` is
  ALSO required** (Credence's hard `equivalence_meta_test`, 2026-06-08 — a missing or skeleton equivalence test
  fails the Gate's `mix test`); `PROPERTY_TEST` required **iff** the spec carries `assumptions` (§3.12 Tier 1),
  rejected if present without. Syntax/Semantic new rules require `RULE` + `CHECK_TEST`(=`_analyze_test` for
  syntax) + `FIX_TEST` only — **no** equivalence test (Pattern-only). bugfix → `RULE` = the known
  rule path; every `TEST:<path>` **⊆ the known glob set** (≥1 changed); **no new/renamed files** — this is
  exactly what *enforces* §5.4's modify-only invariant and keeps the Gate's pure-deletion/scope checks trivial.

### 5.3 Seed context = what the agent used to explore for

- **★ The generator-produced scaffold files, FULL CONTENTS (the exact template to fill — §5.0 step ★9).**
  After §5.0's `mix credence.gen.rule` writes the honest-red stubs, the orchestrator **reads those files back
  and injects their verbatim contents** into the seed — the rule stub + `_check_test` + `_fix_test`
  (+ Pattern `_equivalence_test`, + `_property_test` iff switch-gated), or the syntax/semantic stub set. This is
  the load-bearing ingredient that makes the fill a *fill* and not a from-scratch emit: the model sees the exact
  module names, file boundaries, heredoc-fixture shape, and the gate-passing test scaffolding it must preserve,
  and only has to make the red assertions green (write `check`/`fix`, swap fixtures, pick `inputs:`). Without
  this, a whole-file emit (§5.2) can silently drop a required shape; with it, the meta-gates + focused `mix test`
  only ever have to catch a *deviation* from a template the model was shown. (This is wiring (a) in §5.0, now an
  explicit seed ingredient, not an aside.)
- **★ Semantic only — the REAL captured diagnostic.** A semantic rule keys on a compiler diagnostic
  `%{message, position, severity}`, and `match?` regex-matches `message`; a *fabricated* message passes every
  gate but leaves the rule **dead in production** (the live pipeline feeds it `Code.with_diagnostics` output). So
  the semantic seed carries the **real** `%{message, position, severity}` captured from the failed-solve trace —
  Credence's `[credence_fix] no rule matched diagnostic: …` line (the new-semantic-rule signal itself, logged at
  `semantic.ex:130`, already in the row log at `:debug`), upgraded to log the **full** `inspect(diagnostic)` (a
  Credence visibility tweak, `08` T1.3-sibling). The implementer copies it verbatim into the test `diag` literal
  and derives `match?` from it, so the generated rule provably fires on real code. (Pattern/syntax have no
  diagnostic; this ingredient is semantic-only.)
- **Both before + after AST dumps**, precomputed by the AST helper (§6) and passed as **arguments** to the
  loop. The loop never invokes the helper itself (keeps it non-agentic; no `mix run -e`, ever).
  **Phase-conditional (§3.6):** AST dumps apply to `pattern` (and `semantic`, which parses); for a **`syntax`**
  target the module-template doesn't parse, so the seed is the **templated before/after module strings + the
  `Credence.Syntax.Rule` string-level `fix/1` exemplar** instead of AST dumps. (The *form* is still a full
  module — §4.1 — only the dump is skipped.)
- **One inlined small pattern rule + test exemplar** (the old "starter kit", repurposed) so the model knows
  the format without reading files.
- **For bugfix**: the offending rule's full source + all its test files, injected by deterministic path.
- A path-convention line (rules `lib/<phase>/<name>.ex`, tests `test/<phase>/…`, dispatchers, helpers) —
  ~30 tokens, replaces any `ls`/`tree`.
- **The behaviour-preservation invariant (§3.10), re-stated.** The classifier already screened for it, but the
  implementer *writes* `fix/2`/`fix_patches/2` and could regress it (e.g. broaden the match so the rewrite now
  fires on a behaviour-diverging input). Inject the invariant (output-identical for **every input the active
  assumptions admit**) + the codepoint↔grapheme split (type-change = forbidden forever; rare-text-divergent =
  **switch-gated via §3.12**, not deferred). **The implementer also has NO check-only escape (§4.1):** it must
  write a real `fix_patches/2`; if it cannot keep the fix safe even on the narrow core the classifier handed it,
  it does **not** ship a `-> []` stub — it `gave_up`s (and the row is logged), because we no longer accept
  non-fixable rules. **The §3.11 behaviour gate WILL execute its `fix` across the (assumption-restricted)
  battery** (the classify-time `credence.equiv` pre-check **and** the rule's own mandatory `_equivalence_test`
  run by the Gate suite — the *subsumed* 6th check) and a `DIVERGES` is a hard reject — so the seed instructs the model
  to **self-run that battery** (`{input, before, after}` per input) before emitting and to **narrow the match
  until every admitted-battery input is a no-op**, not discover the divergence at the gate.
- **Assumptions (§3.12 Tier 1) — when the spec carries `assumptions: [...]`:** emit
  `def assumptions, do: [...]` (the existing switch names the spec/`credence.equiv` settled on) **plus** a
  `Credence.Pattern.<Rule>PropertyTest` — built from a **fixed template** that asserts `before ≡ fix` across
  Credence's **shared** generator **for the tagged switch** — `AssumptionGenerators.single_codepoint_string/0`
  for `single_codepoint_graphemes`, `proper_list/0` for `proper_lists` (one per switch, picked by the tag;
  injected as an exemplar in the seed). **The
  implementer authors NO generator** — reusing the shared, honesty-tested one is what makes this safe and cheap;
  inventing a new switch/generator is Tier 2 and **out of the implementer's scope** (human-gated, §3.12). For a
  **no-promise** rule (`assumptions: []`) it emits **no** `assumptions/0` and **no** property test, exactly as
  before. The clone's 0.7.0 meta-tests (tagged-rule-needs-property-test; `assumptions/0 ⊆ names()`) gate both
  cases at the Gate. The Gate won't catch a *type-change* regression (§10), so the invariant restatement above
  is the implementer-side backstop.

### 5.4 The split-test rule

> **The loop writes split tests for files it *creates*; it never restructures files that already exist.**

- **New rule** → greenfield: emit the check test **and** the `_fix_test.exs` — **always both** (every rule is
  fixable now, §4.1; no check-only half-set). The before/after spec hands the model exactly the material for
  each file; both files follow §5.6's exact shape. **The check-test *filename* is phase-conditional** —
  the orchestrator (not the model) maps the `CHECK_TEST` role marker to the per-phase convention the
  `evolution → main` review loop's gate enforces: **pattern/semantic → `<name>_check_test.exs`; syntax →
  `<name>_analyze_test.exs`** (syntax rules implement `analyze/1`, not `check/2`, and the live repo names
  their tests `*_analyze_test.exs` + `*_fix_test.exs` — e.g. `fix_scientific_notation_analyze_test.exs`). A
  syntax rule emitted as `_check_test.exs` would fail the review-loop syntax gate (which expects
  `_analyze_test`+`_fix_test`, or a single `_test`). The role markers stay role-based — only the filename
  the orchestrator writes them to forks by phase.
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

### 5.6 Test conventions — emit the reviewer's required shape the first time

The `evolution → main` reviewer enforces an **exact** test shape and *rewrites* any set that misses it — which
is Claude tokens spent. The implementer must emit that shape directly so the reviewer only has to *confirm*,
not repair. Inject these as hard rules in the implementer seed (`08` T5.1); the retry-loop `mix test` already
runs the result, so a violation that breaks compilation is caught locally for free.

- **Split, per kind** (§5.4): pattern → `_check_test.exs` (findings only — **including the deliberately-skipped
  unsafe cases asserted as "no issue"**, so the safe-core narrowing of §4.1 is locked into the tests) +
  `_fix_test.exs` (exact rewrites) **+ `_equivalence_test.exs` (mandatory, below)**. semantic → `_check` + ≥1
  `_fix` variant. syntax → `_analyze`+`_fix` (or a single `_test`).
- **Pattern: a mandatory `_equivalence_test.exs` (2026-06-08, Credence hard gate).** Define
  `<Name>EquivalenceTest`; call `assert_equivalent(before, rule: Rule, vars: [...], inputs: <dimension>)` where
  `<dimension>` is the matching `Credence.EquivalenceInputs` set(s) for the rule's risk class (term_lists /
  signed_integers / unicode_strings / single_codepoint_strings / multi_codepoint_strings / stability_lists). It
  must clear the anti-stub checks (rule fires + a rewrite happened + ≥3 **discriminating** inputs) and pass
  under **strict `===`** + exception-module parity.
  - **`vars` + `inputs` are implementer fills, self-corrected by the loop.** The classifier spec carries **no**
    free-var field; the implementer reads the **ordered free variables of `before` off the AST dump** already
    in its seed (§5.3) for `vars:`, and picks the `inputs:` dimension by the rule's risk class. A wrong `vars`
    list (won't compile / rule won't fire) **or** a non-discriminating dimension fails the focused `mix test`
    → RED → retry, so neither needs a new spec field. A **constant-output-by-design** rule (rare — `no_tautological_if`)
    needs `allow_constant_output: true`; the seed names the flag so the implementer can set it. (If `vars`/dimension
    misfills cluster in practice, a deterministic free-var helper, §6, is the tuning fallback — open item.)
  - For the rare non-preserving rule swap the assert for the exact opt-out: `mark_equivalence_cosmetic`
    (provably inert — param/attr/doc/typespec), `mark_equivalence_unconstructible` (behavioural but no runnable
    `before` — macro/compile-time), or **`mark_equivalence_repair`** (the `before` has no valid output on any
    input — §3.10 repair family). **In repair sub-mode** (routed by a `credence.equiv` `REPAIR` verdict, §3.11)
    the implementer emits `mark_equivalence_repair(reason)` and writes the reason from the verdict's evidence
    (exception class + `N/N raised` — "the before raises `<exc>` on every admitted input, so no input yields a
    valid result"). The generator scaffolds this file as `assert_equivalent` + a TODO; **never** weaken or
    `@tag`-skip it — a divergence is a real bug → narrow/drop the rule.
- **Syntax/Semantic: emit the §3b substance shapes (Credence hard `syntax_meta_test`/`semantic_meta_test`,
  2026-06-08), or the Gate suite rejects an inert rule.** Syntax → a positive `analyze(...) = [%Issue{rule: :<snake>}]`
  + a negative `analyze(...) == []` + a real `fix(A) == B` transform + the **fixpoint** `analyze(fix(...)) == []`
  + **`valid_syntax?(fix(...))`** (the repaired source parses). Semantic → a positive `match?` + a negative
  `refute match?` + attribution `to_issue(...).rule == :<snake>` + a real `fix(src, diag) == expected` +
  `valid_syntax?(fix(...))`. Use the `Credence.RuleCase` verb `valid_syntax?/1` (parser-hidden, so the
  `no_parser_calls` gate stays satisfied). The generator emits all of these; the fill pass makes them green.
- **Every fix-test assertion compares the WHOLE output with `==`** — `assert fix(code) == expected`, or
  `assert fix(code) == code` for a no-op. **Never** match a fragment. **BANNED in fix tests** (each lets an
  unintended change *elsewhere* in the output slip through): `=~`, `String.contains?`,
  `String.match?` / `Regex.match?`, `String.starts_with?` / `String.ends_with?`, and `String.split` + `Enum.at`
  slicing — **even for negative / must-NOT-change cases.** Pin the entire string.
- **`expected` is taken from the rule's REAL output** (run the rule, copy the string), never hand-written —
  `mix format` normalizes layout later, the exact string pins the *meaning*.
- **Triple-quoted heredocs (`"""…"""`) for `code` and `expected`** — never `\n`-escaped single-quoted strings.
- **`check` and `fix` must agree** — never flag a case the fix won't touch; never leave a fixable case the
  check misses.

These are deterministic conventions, not judgment calls — getting them right at emit time is the single biggest
lever on downstream reviewer cost (the reviewer's longest sub-task is normalizing tests to exactly this shape).

---

## 6. The AST helper (the exploration-killer)

Credence has **no AST-inspection tool today** (rules use `Macro.prewalk/postwalk` on `Sourceror.parse_string!`;
no `ast_walk`, no mix task). The old agent explored — `mix run -e` experiments — precisely to *guess* the
Sourceror tuple shape. Hand it the shape and the exploration disappears.

- **Phase scope (§3.6): the AST helper is for `pattern`/`semantic` only.** A `syntax`-phase `before` does not
  parse, so `Sourceror.parse_string!` *raises* — never run the helper on a syntax snippet; its implementer
  seed is raw strings (§5.3). The orchestrator gates on phase before invoking the helper.
  - **⚠️ Assumption, not fact — validate before building `08` T5.1's syntax branch.** "Syntax ⇒ raw-string
    seed, no structural help" rests on the premise that a non-parsing `before` yields *nothing usable*
    structurally. [`09`](09_external_research_self_evolving_rule_systems.md) §3 left this **unresolved across
    two research passes** and flagged it for a **code spike, not more web search** (~1–2 h, zero paid tokens):
    feed 5–10 real non-parsing solve attempts (from `escalated/`) to `Code.string_to_quoted/2` **and**
    Sourceror's fault-tolerant parser, and record whether a **usable error locus** (line/col + offending token)
    or a **partial AST** comes back. **If yes** → the syntax seed (§5.3) can upgrade from blind before/after
    strings to a **targeted locus seed** ⇒ far more precise syntax-rule discovery (and this bullet's "no
    structural help" claim is partly false). **If no** → the string-only seed is *confirmed*, not merely
    assumed. The same spike also answers §16's "does seed→mutate transfer to non-parsing syntax." Only ~4
    genuine syntax rules exist (the rest were reclassified to `pattern`, `08` Phase 1 baseline), so don't
    over-engineer — let the spike decide.
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
  dumps into the implementer's seed (always both — every rule is fixable, §4.1). Writing the rule becomes
  mechanical: "match this exact `before` tuple shape, emit a patch producing this exact `after` tuple shape."
- **Dogfood:** before relying on it, run the helper on a snippet a *known* rule matches and confirm the dump
  matches what that rule actually pattern-matches.
- **Nice-to-have (documented, not built):** append a short static Sourceror-gotchas cheatsheet (wrapped
  literals, atom positions, `:delimiter` meta — all already in Credence's `CONTEXT.md`).

### 6.1 The scaffold generator (the other exploration-killer — already in Credence, 2026-06-08)

Where the AST helper kills *AST-shape* exploration, `mix credence.gen.rule <Name> [--type pattern|syntax|semantic]`
kills *file-shape* exploration — the old agent re-discovered the triplet naming, the heredoc-fixture rule, the
whole-string `==` fix convention, the equivalence-test requirement one meta-gate failure at a time. The
generator **embodies that contract as a template** and is pinned (`generator_meta_test.exs`) against the same
predicates the real meta-gates enforce, so it cannot drift from the gates.

- **Home: Credence `lib/` (shipped).** `Credence.RuleName.derive/2` (name → snake/Pascal/module/path),
  `test_path/2`, `test_module/2` are the **single source of truth** for every path + module name — the
  generator, the pin, *and* the real gates all call it. Tunex's orchestrator shells the task in the clone
  (exactly as it does `run_credence_fix.exs` / will do `credence.ast`).
- **Output:** correctly-named, `mix format`-clean, **honest-red, gate-passing** skeletons — Pattern → 4 files
  (rule + `_check_test` + `_fix_test` + **`_equivalence_test`**); Syntax → rule + `_analyze_test` + `_fix_test`;
  Semantic → rule + `_check_test` + `_fix_test`. **Aborts (writes nothing) on any path collision** — a free
  deterministic backstop to §3.8's suffix de-collision.
- **Use:** §5.0 — orchestrator runs it with the final name, the implementer fills the red stubs. Replaces all
  hand-typed paths/module-names and **subsumes T5.4a** (phase-conditional check-test filename).
- **Dogfood (before relying on it):** `mix credence.gen.rule NoExampleScaffold` → 4 files, format-clean, only
  the runtime assertions red, every meta-gate green; delete the throwaway; suite green again.

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
| Behavioural-equivalence (§3.11) = `DIVERGES` at classify-time | **`behaviour_diverged/`** (NEW) | n/a |
| `SWITCH_PROPOSAL` (§3.12 Tier 2 — would-be rule pending a new switch) | **`switch_proposals/`** (NEW) | n/a |
| Spec malformed after one re-ask | **`classifier_errors/`** (NEW) | n/a |

**`RowLog` gains move targets.** Today it has `open`/`close` (delete)/`escalate`/`commit`. The rebuild:
`close/1`'s delete → **move to `no_action/`**; add `duplicate/1`, `behaviour_diverged/1` (§3.11) and
`switch_proposals/1` (§3.12) and `classifier_errors/1` move methods (same `filesync → remove_handler → rename` shape as `escalate/1`). **Retention knob** (default = keep
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
| The **Gate** (`evolve/gate.ex`) | **5 parts unchanged; the planned 6th check is now SUBSUMED (2026-06-08).** Harness-independent; operates on the git diff + `mix test`. The §3.11 behavioural-equivalence check on the **actual** `fix(before)` no longer needs separate Gate plumbing — Credence's hard `equivalence_meta_test` forces every Pattern rule to carry a real `_equivalence_test.exs` that runs the actual `fix` over the `EquivalenceInputs` battery (strict `===`), and the Gate's full `mix test` already runs it. The same `mix test` now also runs the hard `syntax_meta_test`/`semantic_meta_test` (substance + `valid_syntax?` + fixpoint + attribution) + the generator pin — so the Gate transparently gained the whole 0.7.0+ meta-gate suite as a behaviour/substance net **for free**. |
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
  parse/compile gates (§3.6); the **novelty pre-check** kills duplicates/multi-issue leakage *before* the
  implementer; over-cap `after` → narrow-or-`NO_ACTION` (no check-only); malformed → one re-ask →
  `classifier_errors/`.
- **A false `NO_ACTION` is bounded** — human-sampled audit of retained `no_action/` logs (§12), zero token cost.
- **The Gate's `mix test` now carries the whole Credence meta-gate suite — a free substance/behaviour net
  (2026-06-08).** Beyond the original 5 mechanical checks, the clone's full `mix test` (which the Gate runs)
  fails on: a Pattern rule **missing or faking** its `_equivalence_test` (hard `equivalence_meta_test`: real
  `assert_equivalent`/mark, references the rule, no skeleton, anti-stub fires+rewrote+≥3 discriminating
  inputs); an **inert** Syntax/Semantic rule (hard `syntax_meta_test`/`semantic_meta_test`: positive+negative
  substance, `valid_syntax?(fix)`, fixpoint `analyze(fix)==[]`, attribution); a fixture that isn't a heredoc;
  a test that calls the parser directly; a switch-gated rule without a `<Rule>PropertyTest`. So the implementer
  must satisfy all of these — which the **generator** guarantees structurally and the **fill pass** makes green.
- **Behaviour preservation is now a deterministic property for pattern rules (§3.11), discipline for the
  rest.** §3.11's check **executes** `before` vs `fix(before)` across the `EquivalenceInputs` battery (strict
  `===`) at **two points**: a **classify-time** `credence.equiv` pre-check on the proposal (reject →
  `behaviour_diverged/`, no build), and — for the built rule — the **rule's own mandatory equivalence test**,
  run by the Gate's `mix test` (diverge → suite RED → reject → `escalated/`; this is the *subsumed* 6th check,
  §3.11). Together they catch value / type / exception / order divergence (the bulk of the live `followup.md`:
  a rule that passes the *other* tests but diverges on a battery input **no longer lands**). What stays on
  **discipline + human review**:
  divergence only on a non-battery input, **evaluation-order / side-effect** divergence (the battery is values,
  not side-effecting operands — §3.11 limits), and **semantic/syntax** phases (no compilable `before` to run).
  The classifier still never proposes a behaviour-changing `after`, and the implementer prompt re-states the
  invariant (§5.3) — but those are now the *upstream* belt, with `credence.equiv` the executable airbag.
- **0.7.0 gates the switch machinery — and §3.12 Tier 1 now USES it (UPDATED).** The clone is Credence 0.7.0;
  the full `mix test` the Gate runs includes its assumptions meta-tests: every `assumptions/0` ⊆ known switch
  names, and every switch-tagged rule has a loadable `<Rule>PropertyTest`. A switch-gated rule the implementer
  emits (§3.12 Tier 1) **lands** precisely because it satisfies these — it tags only existing switches and ships
  a property test from the **shared** generator (§5.3); a malformed one (bogus switch, or tagged-without-test)
  **fails the Gate mechanically.** Plus the §3.11 `credence.equiv` restricted-battery proves the partial
  equivalence *before* the Gate. (The meta-tests don't check behaviour identity — that's what §3.11 adds; the
  *type-change* class still has no Gate net beyond §3.11's exercised-input catch + the §5.3 discipline.) A
  **new** switch still can't land autonomously — that's the human-gated Tier 2 (§3.12).
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
   implementer. **⚑ Baseline already landed (2026-06-08, verify in clone): the per-rule behaviour-equivalence
   suite** (`Credence.BehaviourEquivalence` + `EquivalenceInputs` + hard `equivalence_meta_test`), **the scaffold
   generator** (`mix credence.gen.rule` + `Credence.RuleName` + `RuleScaffold`), **the Syntax/Semantic +
   generator meta-gates**, and **the 2nd assumption switch `proper_lists`** — so this step builds only the three
   *still-missing* tasks. **Same Credence pass (ship together — all Credence-side):** (i) `mix credence.covers`
   behavioral novelty task (§3.7); (ii) **`mix credence.equiv` behavioural-equivalence task (§3.11/§3.12) — now
   a THIN task built on the shipped support module** (reuse `BehaviourEquivalence.eval_outcome/2` + the
   `EquivalenceInputs` battery in snippet-vs-snippet mode, the `equivalence_regression_test.exs` pattern); it is
   the **classify-time** pre-check only — the built rule's equivalence is the per-rule test the Gate suite runs.
   Compile `before` + the proposed `after`, run both over the battery, print `EQUIVALENT`/`REPAIR`/`DIVERGES`
   (the trichotomy, §3.11 — `REPAIR` = `before` raises on every admitted input, after succeeds);
   **shelled `MIX_ENV=test`** (the support modules are `test/support`-only); **takes `--assumptions` and reports
   the minimal switch set** (run under `:strict` + each registered switch),
   battery filtered to the admitted domain (§3.12); dogfood on a known-unsafe `followup.md` snippet (must report
   `DIVERGES`) and a rare-text one (must report `EQUIVALENT under single_codepoint_graphemes`); (iii)
   *optional* — `log_diff` in the Pattern revert branch for seed visibility (§3.9). **No revert-gate fix —
   `:reverted` is already a clean signal (Pattern entry gate, `pattern.ex:52`).** *(No `lib/assumptions.ex`
   change — Tunex only READS `Credence.Assumptions`; switch creation is human/Credence-side, §3.12 Tier 2.)*
2. **Classifier** — raw `Tunex.LLM`, **configurable provider** (default Mimo-pro, `:anthropic_opus`
   alternative — §3.1), marker output, validation gates, option-shaping, coarse Python-cut distillation
   (`===SOLVE_BOUNDARY===` sentinel, §7), `APPLIED_RULES` + ledger inputs.
   **Config delta:** add `:classify` (+ `:implement`) to `stages` + `stage_max_tokens`; relax the
   `Config.provider_for/1` + `stage_max_tokens/1` `when stage in […]` guards; default `stages.classify =
   :xiaomi_mimo_2_5_pro`; add the optional `:anthropic_opus` provider (+ `secret_providers` header +
   `budget.prices` entry); thread the stage atom into `Budget.record` (§3.1).
   **Preflight delta:** smoke-test whichever provider `stages.classify` resolves to via a one-token
   `LLM.for_stage(:classify, …)` call (mirrors `cc_smoke!`/`mimo_chat_reachable!`) so a wrong/expired Anthropic
   key (or a mis-set override) fails *boot*, not mid-run. Unlike the remote-solve skip (which shares Mimo's
   already-proven host), the classifier provider may be a **distinct vendor/auth**, so it is always smoked —
   the one-token cost is trivial insurance against losing a whole run on a stale key.
3. **Solver-loop implementer** — both modes (phase-conditional seed, §3.6) + **generator scaffold (§5.0:
   `mix credence.gen.rule`, then fill the red stubs)** + AST-dump injection + **mandatory Pattern
   `_equivalence_test` emission seeded from `EquivalenceInputs` (§5.6)** + Tier-1 assumptions/property-test
   emission (§3.12) + the new outcome directories (`no_action/`, `duplicate/`,
   `behaviour_diverged/`, `switch_proposals/`, `classifier_errors/`). Runs in the **clone** (§5); the commit
   path calls `Workspace.recompile_credence/1`. **Wired classifier → implementer end-to-end immediately** (no
   measure-only sub-phase).
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
- **Documented-not-built — model-divergence sampling (A/B, not second-guessing).** Distinct from the
  second-opinion above: every *N*th row, run the **same** distilled input through **both** configured
  classifier models (e.g. Mimo-pro *and* Opus) and log **both** specs side-by-side. Purpose is **calibration
  data**, not quality arbitration — quantify *how differently the two models judge the same input* so the
  Mimo-vs-Opus choice (§3.1) rests on numbers, not the single Opus anecdote. Cheap (1-in-*N* × one extra
  few-K call) and self-terminating once enough data is gathered. **Mostly free already:** because nothing is
  deleted (§8), every classifier input+output is on disk, so the *same* comparison can be run **offline** by
  re-feeding saved `no_action/`/`committed/` inputs through the other model — build the online A/B sampler only
  if offline replay proves too coarse. Sampling rate `classifier_ab_sample_every` (0 = off, default).
  - **Why A/B is calibration, NEVER selection.** [`09`](09_external_research_self_evolving_rule_systems.md)
    **F5** (EVOL-RL `arXiv:2509.15194`, 3-0) shows majority-vote / self-consistency *selection* collapses
    output diversity (entropy + pass@n drop); the fix is a **novelty reward, not a vote**. So this sampler only
    *logs* divergence to inform the model choice (§3.1) — it must never *pick* the answer by model agreement.
    External backing for staying at **one** classifier call (§3) rather than N-sample-and-vote.

---

## 13. Decision log (quick reference)

| # | Decision |
|---|---|
| Replacement | Full rebuild of rule-creation; ClaudeCode harness + agentic generator **deleted**, no fallback |
| Classifier | One raw `Tunex.LLM` call, **configurable provider** (default `mimo-v2.5-pro`+thinking; `:anthropic_opus` alternative — switch via `stages.classify`/`TUNEX_CLASSIFY_PROVIDER`; Opus = a 2nd paid dep, Preflight-smoked), no tools, ~200-tok system prompt, on 100% of rows (minus §3.9 lane). **Accuracy not bias — it IS the quality bar** (Gate checks mechanics, not idiomatic merit; a bad landing rule pollutes all future code). Tiny-but-real welcome; uncertain → NO_ACTION; never speculate (§3.1) |
| Classifier input | distilled log + `APPLIED_RULES` + ledger; **no rule-name index** — dedup is the §3.7 pre-check, not a construction proof |
| Phase asymmetry | Syntax (non-parsing, string-level) / Semantic (warnings) / Pattern (compiling, AST). Seed + `before` gates are **phase-conditional** (§3.6); new rules are *plurality* pattern but syntax/semantic are first-class (from failed rows, §3.3); BUGFIX is phase-polymorphic |
| Novelty pre-check | `POTENTIAL_NEW_RULE` only: run `before` through `Credence.fix` in the clone (`mix credence.covers`); `COVERED` (a **real rule engaged** — `code` changed / `applied_rules` non-empty / non-parse-error issue; **🔴 NOT** the bare `parse_error_issue`, else every novel syntax rule dies — §3.7) ⇒ duplicate ⇒ `duplicate/`, skip implementer. Behavioral, names no rule, phase-agnostic, no compile gate (§3.6) |
| **Behavioural-equivalence gate** | **§3.11 — the executable behaviour net; split across two homes (2026-06-08).** **Classify-time:** `mix credence.equiv` (a THIN task reusing the shipped `BehaviourEquivalence.eval_outcome/2` + `Credence.EquivalenceInputs` battery, strict `===` + exception-module parity, snippet-vs-snippet; **shelled as `MIX_ENV=test …`** since the support modules are `test/support`-only) on the proposal. **Trichotomy verdict `EQUIVALENT | REPAIR | DIVERGES`** — `DIVERGES` ⇒ `NO_ACTION` → `behaviour_diverged/`, no build; **`REPAIR`** (before raises on every admitted input, after succeeds) ⇒ proceed in repair sub-mode (implementer emits `mark_equivalence_repair`, §3.10 carve-out); `EQUIVALENT` ⇒ proceed (no-promise or switch-gated per the minimal set). **Built rule:** the planned 6th Gate check is **SUBSUMED** — Credence's hard `equivalence_meta_test` makes every Pattern rule carry a real `_equivalence_test` that runs the **actual** `fix` over the battery; the Gate's full `mix test` runs it (diverge ⇒ suite RED ⇒ reject → `escalated/`). **Pattern-phase only.** Catches ~22/27 of live `followup.md`. Limits: eval-order/side-effect divergence (Credence's `assert_effect_trace_equivalent` exists if needed) + non-pattern phases stay §3.10 discipline. **Repair family** (`before` invalid on every input) ships `mark_equivalence_repair`, not an auto-`NO_ACTION` (§3.10) |
| **Scaffold generator** | **NEW step (2026-06-08, §5.0/§6.1).** Orchestrator shells `mix credence.gen.rule <FinalName> --type <phase>` (Credence-shipped; `Credence.RuleName` = single name/path source of truth) → correctly-named, heredoc, honest-red, **meta-gate-passing** stubs (Pattern incl. `_equivalence_test`); implementer **fills** the red assertions. Replaces all hand-typed paths/module-names; **subsumes T5.4a**; aborts on collision (free name backstop) |
| Output | marker-fenced thick spec `{decision, rule_name?|proposed_name?, phase, before, after, rationale}` — **`after` always present; NO check-only** (§4.1); `before`/`after` are **full `defmodule`s, all phases** (syntax = module template), each **isolating exactly ONE issue** (composition: N rules rescue garbage, none alone — isolation makes pre-check + mutation gate attributable, §4.1) |
| Option-shaping | empty `APPLIED_RULES` → BUGFIX not offered. **Runs on every row that reached solve (success AND failed)**; solve outcome forks the task lens — solved → idiomatic residual; failed → unfixed syntax/semantic issue (new-syntax source) (§3.3) |
| BUGFIX | constrained to `APPLIED_RULES` (over-firing only); under-firing → NEW |
| `:reverted` lane | `:reverted` (Pattern-only) is **already** a genuine compiling→non-compiling broken rule — Pattern's entry gate (`pattern.ex:52`) skips non-compiling input, so `compiles?(source)` is invariant. → **deterministic** bugfix, **skips classifier**, **no Credence change** (§3.9) |
| NEW | **always create new**, never extend; classifier emits `proposed_name` (on-convention `no_/prefer_/avoid_`); order = classify → pre-check → resolve name+suffix → implement; orchestrator owns final naming |
| Fixable-only (NO check-only) | **2026-06-04 policy:** every proposed rule carries a real `after`/`fix_patches`. No `fix_patches/2 -> []` stubs. Can't safely fix even a narrow core (or only fix changes a value's **type**) → **`NO_ACTION`**, not check-only. Matches the `evolution → main` reviewer's fixable-only bar (kills the `unfixable.md` lane at source) (§4.1) |
| `after` complexity | capped; over-cap → **narrow to a fixable core, else `NO_ACTION`** (never check-only) (§4.1) |
| Test shape (emit reviewer-ready) | fix tests compare **whole output with `==`** (no `=~`/`String.contains?`/`match?`/`starts_with?`/split-slice — even for negatives); `expected` from the rule's **real** output; **heredocs only** (no `\n`-escapes); `_check` includes the dropped-unsafe cases as "no issue"; `check`/`fix` agree (§5.6) |
| **Behaviour preservation** | **Absolute *relative to declared `assumptions:`* (§3.10; Credence ≥0.7.0).** `after` must be output-identical to `before` for **every input the active promises admit**; Tunex runs the **default (helpful)** mode (`single_codepoint_graphemes` on), never `:strict`. The old "FORBIDDEN: codepoint↔grapheme" class **splits**: **(a) type-change** rewrites (`Enum.at(to_charlist)` → `String.at`, int vs string) = `NO_ACTION` *forever* (no switch rescues — Credence dec. 15); **(b) rare-text-divergent** (count·reverse·palindrome) = **now buildable via §3.12** (Tier-1 switch-gated rule on an existing switch, or Tier-2 `SWITCH_PROPOSAL` if no switch covers it) — no longer auto-`NO_ACTION`. Same-space rewrites OK. **§3.11's `credence.equiv` now gates behaviour** (incl. type-change on exercised inputs) for pattern; the 0.7.0 meta-tests block an untested switch-gated rule at the Gate (§10) |
| Validation | deterministic gates; one re-ask → `classifier_errors/` |
| Implementer | **one** solver-style loop (raw LLM, no harness/tools), parameterized new/bugfix; whole-file emit via a **file-keyed marker scheme** (new = fixed-role `RULE`/`CHECK_TEST`/`FIX_TEST`; bugfix = path-keyed `TEST:<path>` ⊆ glob, modify-only) (§5.2) |
| Implementer seed | thick spec + precomputed before+after AST dumps + exemplar (+ rule source for bugfix) |
| Split tests | new rules emit `_check`+`_fix` **+ (Pattern) a mandatory `_equivalence_test`** (§5.6); Syntax/Semantic emit the §3b `valid_syntax?`/fixpoint/attribution shapes; bugfix edits existing tests **in place** (the `<name>*_test.exs` glob already catches `_equivalence_test`; keep it green) (no migration) |
| Bound | dedicated `rule_gen_max_retries` (~5) **+ local per-row input/output ceiling** (zero console poll) + flat (non-accumulating) retry prompt + trimmed `Report.format_errors` feedback; **no console-polling breaker**; **no `max_turns`** (§5.5) |
| AST helper | `mix credence.ast` in Credence; raw + layout-stripped views; never `normalize`/unwrapped; dogfooded |
| Distillation | coarse cut **only** this round: drop everything above an explicit `===SOLVE_BOUNDARY===` sentinel (invariant — no absent-marker handling); full marker-fencing documented-not-built |
| Gate | 5-part backstop; the planned 6th behavioural-equivalence check is **subsumed** by the rule's mandatory `_equivalence_test` (+ the §3b syntax/semantic + generator-pin meta-gates) which the Gate's full `mix test` already runs (§3.11/§10, 2026-06-08) |
| Ledger | kept, feeds classifier whole/uncapped (stays near-empty by design); writes on implementer-failed + gate_reject only; phantom retired; duplicate/classifier_errors don't ledger |
| No deletion | move-to-outcome-dir; new `no_action/`, `behaviour_diverged/`, `switch_proposals/`, `classifier_errors/`; `tunex.reset` still clears |
| Assumptions / switch discovery (§3.12) | **propose-with-evidence (2026-06-04).** Tier 1: classifier may tag a rule with an **existing** switch (`Credence.Assumptions` injected); `credence.equiv --assumptions` confirms the minimal set; implementer emits `assumptions/0` + a property test from Credence's **shared** generator (no generator authoring). Tier 2: a clean rare-text class with **no** existing switch ⇒ `SWITCH_PROPOSAL` → `switch_proposals/` with **demand** evidence; a **human** writes the switch (harness never touches `lib/assumptions.ex`). Recovers the pure rare-text `followup.md` rejections |
| Measurement | **no `summed_usage` port** — the undercount was a CC-harness artifact deleted with it; per-call `Budget.record` IS the bucket basis (expect ledger ≈ console ~1×). Add **per-stage tagging** (`:classify`/`:implement`/`:solve`). Trust console for absolutes (§11.0) |
| Shadow | human-sampled `no_action/` audit; automated second-opinion = footnote only; **model-divergence A/B sampling** (run both classifier models on 1-in-N rows for calibration data) = documented-not-built, mostly replayable offline from saved logs (§12) |
| Escalation archive | `credence_failed` branch kept as-is |
| Sequencing | summed_usage → AST helper → classifier → implementer → escalation → delete old → measure |

---

## 14. Open items (tuning, not design — for live iteration, not this plan)

1. The classifier prompt's exact wording for "spot clean-but-non-idiomatic code" — the hardest judgment;
   iterate against `no_action/` audits.
1b. Prompt discipline for **single-issue isolation** of `before` (§4.1) — reducing one Python-ism out of a
   multi-issue garbage attempt is a real classifier difficulty (esp. syntax, where fixes compose). The
   pre-check catches multi-issue leakage as false-`COVERED`; tune the prompt against the `duplicate/` rate.
2. The `after` complexity-cap threshold (lines / statement count) that triggers narrow-to-core-or-`NO_ACTION`
   (§4.1 — no longer an auto check-only downgrade).
2b. **The §3.11 `credence.equiv` adversarial battery** — **now the shipped `Credence.EquivalenceInputs`
   dimensions** (2026-06-08); the tuning item is *which dimension(s) to pick per rule* + the arity-matching
   strategy. Grow `EquivalenceInputs` in Credence as new divergence classes surface in `behaviour_diverged/` (it
   already encodes the `followup.md` failure classes). A battery miss = a divergence that slips the gate —
   fixed once in `EquivalenceInputs`, picked up by both the classify-time task and every per-rule test.
2c. **Phase-2 `credence.equiv`: operand side-effect tracer** — to catch the eval-order / side-effect-count
   class (`no_cond_two_clauses`, `no_doc_false_on_private`) the value battery can't construct: wrap the rule's
   matched operands in an evaluation tracer and compare call counts/order between `before` and `fix(before)`.
   Build only if `followup.md`-style eval-order misses recur after the value gate ships.
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
- **Model-divergence A/B sampling** (§12) — run both classifier models on 1-in-N rows to quantify how
  differently they judge; build the online sampler only if offline replay of saved logs proves too coarse.
- **Failure-/success-recycling RAG into prompts** — backed by [`09`](09_external_research_self_evolving_rule_systems.md)
  **F6** (`arXiv:2505.00234`, confirmed 3-0: a self-generated trajectory DB used as **in-context examples, no
  fine-tuning**). §8 already persists every outcome; the §5.3 implementer seed and the §3 classifier prompt are
  currently *static*. Retrieve 1–2 *relevant* past outcomes as few-shot examples: **(a) implementer** — the
  most-recent `committed/` rule of the **same phase** (+ same rule for bugfix) as a real worked template (fewer
  retries to match Credence's AST conventions, §6); **(b) classifier** — past *confirmed* `POTENTIAL_NEW_RULE`
  examples to calibrate the clean-but-non-idiomatic call (**"the one load-bearing unknown,"** `08`), plus
  `no_action/` "leave-alone" negatives. Retrieval is dead-cheap (a `var/run/rag_index.jsonl` filtered by
  phase + recency, K=1, **no embeddings**); injected tokens count against the §5.5 `rule_gen_input_ceiling`.
  **Measurement-gated, not critical-path:** every example adds tokens to a *paid* call (fights the cost thesis),
  so build only if §11-step-6 shows low implementer first-try yield, or the §12 `no_action/` audit shows poor
  classifier precision. Positives from `committed/` only (never `escalated/`). The classifier-calibration half
  **(b)** is the higher-value one — it directly de-risks the load-bearing unknown.
- **Focused-agentic escalation for long-tail complex rules** — the solver loop is the *sole* implementer this
  round; if it can't land a genuinely complex rule it `gave_up`s. Measure yield before reintroducing any
  agentic lane.
- **Sourceror-gotchas cheatsheet** appended to the AST helper output (§6).
- **Migrating existing rules to split test files** — a separate human/mechanical pass, never entangled with
  the autonomous bugfix loop.
- **Switch-gated rule generation — the deferral is now SPLIT (§3.12, 2026-06-04).**
  - **Tier 1 (use EXISTING switches) is NO LONGER deferred — build it (§3.12).** The classifier may tag a rule
    with an existing switch, `credence.equiv --assumptions` confirms the minimal set, and the implementer emits
    `assumptions/0` + a `<Rule>PropertyTest` from Credence's **shared** generator (a fixed template, *not*
    authored StreamData — which is what made this hard). This recovers the rare-text `followup.md` rejections.
  - **Tier 2 (DISCOVER new switches) stays deferred to a HUMAN** — *propose-with-evidence*: the harness emits a
    `SWITCH_PROPOSAL` with demand evidence to `switch_proposals/`, a human writes the switch + generator +
    CHANGELOG in Credence. The harness never authors a new generator or touches `lib/assumptions.ex` (global
    default; the generator-authoring trap). Type-change rewrites stay forbidden regardless — a switch can't
    promise away a type change (§3.10(a)).

---

## 16. Complementary pipeline (deferred): offline metamorphic rule audit

*Backed by external research — see [`09`](09_external_research_self_evolving_rule_systems.md) **F3** (StaAgent
`arXiv:2507.15892`, confirmed 3-0: 64 problematic rules found across 5 production Java analyzers; Statfier,
79 bugs / 46 confirmed). **Deferred / off the critical path** — prototype after the rebuild lands 2–3 rules
(`09` §5 step 1). Documented here so it isn't re-derived from scratch.*

The rebuild detects bad *existing* rules only **reactively**: the BUGFIX lane (§3.4) fires when the dataset
walk *happens* to trip an over-firing rule, and the `:reverted` lane (§3.9) catches only
compiling→non-compiling breakage. There is **no proactive audit** of the ~90 existing rules, and §3.9 leaves
the "rules fighting each other" (composition) detection question open. Metamorphic auditing fills both gaps
**off the paid path**.

**Idea.** For a rule R, generate programs R *should* flag (seeds), apply **semantics-preserving mutations**,
and assert R's verdict stays **consistent** across the mutation. An inconsistency ⇒ R keys on something
incidental ⇒ brittle (over- or under-firing).

**Process (reuses the existing back-end — only the front-end is new):**
1. **Seed** — take R's own `_check_test.exs` must-fire snippet (a guaranteed positive); optionally have **local
   Qwen** generate more from R's moduledoc. No paid call.
2. **Mutate** — a *small, provably-safe* transform set: α-rename bound vars; reorder provably-independent
   statements; swap equivalent call syntax (`&(&1 > 0)` ↔ `fn x -> x > 0 end`); reformat. Each preserves
   behaviour under the §3.10 invariant. **Start with α-renaming only** (trivially safe, catches the most common
   name-keyed brittleness); add transforms one at a time.
3. **Oracle = Credence itself** (run in the clone): check rule ⇒ `flags(seed) == flags(mutant)`; fix rule ⇒
   `fix(seed)` / `fix(mutant)` is the same transformation modulo the mutation.
4. **Triage** (StaAgent Type1/Type2): under-fires (misses an equivalent mutant) ⇒ broaden; over-fires (fires
   post-mutation where it shouldn't) ⇒ narrow.
5. **Route into existing machinery** — each violation is a **BUGFIX-shaped spec** (`rule_name = R`,
   `before = seed`, `after = inconsistent behaviour`) ⇒ **§5.1 implementer bugfix mode** ⇒ **§9 Gate**. No new
   back-end is built.

**Example.** `no_filter_then_map` seed `Enum.map(Enum.filter(list, &(&1 > 0)), &(&1 * 2))`; mutate (α-rename +
capture→anon-fn) to `Enum.map(Enum.filter(xs, fn x -> x > 0 end), fn x -> x * 2 end)`. If R matches only the
`&` capture and misses the `fn` form ⇒ Type A (under-fires) ⇒ broaden.

**Fit.** Reuses §5.1 bugfix implementer, §9 Gate, the `mix credence.ast` helper (§6), §5 clone single-writer
discipline, §8 outcome dirs. Orthogonal to the dataset walk (idle-GPU or one-shot pre-pass); never touches the
classifier, distillation, or the OpenCoder dataset. Serves the PRIMARY GOAL (improve existing rules) and
answers §3.9's "rules fighting each other" — mutate *across* rule boundaries to surface composition conflicts.
**Cost: local Qwen + Credence harness only — off the paid bucket.**

**Risks.** (R1) the mutator is the hard part — a non-equivalent "mutation" yields false violations ⇒ start
α-rename-only, validate each transform compiles + preserves behaviour. (R2) Java→Elixir transfer unproven
(`09` caveat) — the *method* is language-agnostic, only the mutators are Elixir-specific; prove on **5 rules**
first. (R3) noise / low precision — it is *advisory* into the implementer; the Gate (mutation-RED + suite-green)
and the human `evolution → main` review still gate every landing. (R4) the §3 syntax spike (error-locus, §6)
also answers "does seed→mutate transfer to non-parsing syntax rules," so run that first.
