# 08 — Classifier-split: task breakdown

*Derived from [`07`](07_classifier_split_architecture.md) (the grilled design). This is the build plan:
ordered, dependency-aware, atomic tasks with acceptance criteria. Section refs (§) point back to `07`.*

> **Two repos.** Tasks tagged **[C]** live in the Credence clone (`../credence`); **[T]** in this repo
> (`:tunex`). The **[C]** tasks (T1.1 ast · T1.2 covers · T1.3 *opt* revert-log · **T1.4 equiv**) ship as
> **one Credence PR** and unblock most of the Tunex work.

> **Golden rule from `07`:** every phase is gated on a **console-Δ measurement** — the console token bucket is
> the only ground truth (`mix tunex.budget`). The in-band ledger is now trustworthy too (Phase 0).

> **⚑ Credence-side reconciliation (2026-06-08 — see `07`'s top note).** The Credence clone already shipped
> three things this breakdown assumed were to-build, in a slightly different shape (verified in `../credence`):
> 1. **Behaviour-equivalence as a per-rule test + hard meta-gate** (`Credence.BehaviourEquivalence`,
>    `Credence.EquivalenceInputs`, `equivalence_meta_test.exs`) — **not** a `mix credence.equiv` task. ⇒ **T1.4
>    shrinks** to a thin classify-time task reusing that support module; the planned **6th Gate check (T4.3b)
>    is subsumed** by the rule's mandatory equivalence test that the Gate's `mix test` already runs; **T5.1/T5.2
>    gain** mandatory Pattern `_equivalence_test` emission.
> 2. **A scaffold generator** `mix credence.gen.rule <Name> [--type …]` (+ `Credence.RuleName`) ⇒ **T5.x gains a
>    scaffold step** (run the generator, fill the red stubs) and **T5.4a is subsumed** (the generator/RuleName
>    own the phase-conditional filename).
> 3. **Hard Syntax/Semantic meta-gates** (`syntax_meta_test`/`semantic_meta_test`: substance + `valid_syntax?` +
>    fixpoint + attribution) + a **2nd assumption switch `proper_lists`** ⇒ **T5.1 gains** the §3b shapes for
>    new Syntax/Semantic rules; assumption injection already reads N switches (no change).
>
> Still to build in the Phase-1 Credence PR: `credence.ast`, `credence.covers`, `credence.equiv` (now thin), +
> two log tweaks — T1.3 (revert-branch `log_diff`, **optional** visibility) and **T1.3b** (`semantic.ex:130` log
> the *full* diagnostic — **a HARD prereq for the new-semantic-rule lane**, T5.1; without it a semantic rule has
> no real `%{message,position,severity}` to seed `match?`/`diag` and ships dead).

---

## Critical path (at a glance)

```
Phase 0  config + measurement basis        ─┐
Phase 1  [C] Credence PR (ast/covers/equiv/revert-log) ─┤→ both unblock everything downstream
Phase 2  log plumbing (sentinel/distill/APPLIED_RULES parse + grep→path)
Phase 3  classifier (prompt/parse/validate/option-shape/outcome-fork)
Phase 4  deterministic lanes (:reverted · novelty · behaviour-equiv + minimal-assumptions · switch-discovery)
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
| **T0.1** | `lib/tunex/config.ex`, `config/config.exs` | Add `:classify` + `:implement` to `stages` + `stage_max_tokens` (default both → `:xiaomi_mimo_2_5_pro`; floors TBD-tuning, start classify 16k / implement 16k). **Relax** the `when stage in [:translate, :solve]` guards in `provider_for/1` + `stage_max_tokens/1` to include the two new stages. | `LLM.for_stage(:classify, …)` / `(:implement, …)` resolve a provider + floor without raising; `TUNEX_CLASSIFY_PROVIDER` override works. |
| **T0.1b** | `config/config.exs`, `config/secrets.exs`, `budget.prices` | **Configurable classifier model (`07` §3.1).** Add an **`:anthropic_opus` provider** (`model: "claude-opus-4-8"`, secret `Authorization` header in `secret_providers`) + a `budget.prices` entry so per-stage metering (T0.2) is honest. **🔴 `base_url` MUST be an OpenAI-compatible endpoint** — `Tunex.LLM` only speaks OpenAI Chat Completions (`messages` w/ system role, `choices[].message.content`, `usage.prompt_tokens` — `llm.ex:60-64,150-163`); native Anthropic `/v1/messages` won't parse and the only Anthropic client (CC harness) is deleted. Use Anthropic's `/v1/chat/completions` compat layer or a gateway (OpenRouter/LiteLLM), **no adapter**. Default `stages.classify` stays `:xiaomi_mimo_2_5_pro`; switching to Opus = repoint `stages.classify` or set `TUNEX_CLASSIFY_PROVIDER=anthropic_opus`. | With `stages.classify = :anthropic_opus` (or the env override), `LLM.for_stage(:classify, …)` hits Opus through the **unmodified** chat path and records cost under `classify`; default config still uses Mimo-pro. |
| **T0.2** | `lib/tunex/llm.ex`, `lib/tunex/budget.ex` | Thread the **stage atom** `for_stage → call → Budget.record` (replace hardcoded `kind: :chat` in `maybe_record_usage`). | `mix tunex.usage` by-stage split shows `classify` / `implement` / `solve` separately. |
| **T0.3** | — (measurement) | Run one row, compare `mix tunex.usage` vs console Δ (`mix tunex.diag`). **Expect ≈1×** (not 20–50× — that undercount dies with the harness). | Documented ratio ≈1×; if not, investigate provider cache billing before proceeding. **No `summed_usage` port.** |
| **T0.4** | `lib/tunex/preflight.ex` | **Smoke the classifier provider.** Add a `classify_endpoint_reachable!` check (mirror `cc_smoke!`/`mimo_chat_reachable!`): one-token `LLM.for_stage(:classify, "reply OK", "", max_tokens: 16)` against whatever `stages.classify` resolves to. **Always** smoke it (unlike the remote-solve skip) — the classifier may be a distinct vendor (Anthropic) with a separate, expirable key; a stale key must fail *boot*, not mid-run. Also assert the secret header is present (parallel to the existing `has_cc`/`has_chat` checks). | A wrong/missing classifier key fails `mix tunex.preflight`; a good key logs `[Preflight] classify endpoint reachable (<provider>)`. |

---

## Phase 1 — [C] Credence PR (`07` §3.9, §3.7, §6)

> One PR to `../credence`. **No revert-gate fix** — an earlier draft proposed one but it was based on a wrong
> premise: `Pattern.fix_with_trace` (`pattern.ex:52`) skips the whole pipeline unless the source compiles, so
> `:reverted` is **already** a clean compiling→non-compiling broken-rule signal. T1.3 is now an *optional*
> visibility tweak only.
>
> **⚑ Already landed in the clone (2026-06-08) — this PR is now AST + covers + (thin) equiv ONLY.** Credence
> `main` shipped the **per-rule behaviour-equivalence suite** (`Credence.BehaviourEquivalence`,
> `Credence.EquivalenceInputs`, the hard `equivalence_meta_test.exs`), the **scaffold generator**
> (`mix credence.gen.rule` + `Credence.RuleName` + `Credence.RuleScaffold`), the **hard Syntax/Semantic +
> generator meta-gates**, and a **2nd assumption switch `proper_lists`**. So T1.4 is no longer a from-scratch
> battery — it's a thin task on the shipped support module (below), and the Tunex implementer tasks (Phase 5)
> gain a generator-scaffold step + mandatory Pattern `_equivalence_test` emission + the §3b Syntax/Semantic
> shapes.
>
> **⚠️ Baseline = Credence 0.7.0 "safety switches" (`assumptions:`).** This PR layers *on top of* the 0.7.0
> safety-switch work — the clone now ships `Credence.Assumptions`, `{:stream_data, "~> 1.0", only: :test}`, and
> the CI meta-tests (every `assumptions/0` ⊆ known switches; every switch-tagged rule has a `<Rule>PropertyTest`;
> changelog guard). Consequences for the rebuild: Tunex invokes Credence in its **default (helpful)** mode
> everywhere (never `:strict`), so switch-gated rules fire/self-suppress like for real users (`07` §3.5/§3.10);
> Preflight's `mix deps.get`/recompile on the clone fetches `stream_data` (no Tunex change); and the full
> `mix test` the **Gate** runs now includes those meta-tests, so an untested switch-gated rule is rejected
> mechanically (`07` §10). The implementer therefore emits no `assumptions/0` this round (T5.1).
>
> **⚠️ Baseline also pins `lib/syntax.ex` byte-identical (the `evolution → main` review loop confirms this).**
> The review loop's reconciliation **rejected** the `evolution` `lib/syntax.ex` "run rules on parseable source"
> runner change — it shipped a masking regression (a structural syntax issue made `analyze/2` suppress all
> semantic+pattern findings). `analyze/2` keeps its `{:ok, _ast} -> []` guard (syntax phase returns `[]` on
> parseable input, never short-circuiting other phases). T1.2 (`mix credence.covers`) and `07` §3.5/§3.7 depend
> on exactly this: the synthetic `parse_error_issue` fires only on *non-parsing* input, so the novelty pre-check
> can still read `NOVEL` for genuinely-new syntax snippets. **Had that runner change landed, `covers` would
> read `COVERED` on parseable snippets a stray syntax rule matched and silently kill new-rule creation** — so
> the rebuild must run against a clone *without* it. Relatedly, the 2 misfiled syntax rules
> (`fix_module_attr_outside_module`, `fix_typespec_literal_list`) were reclassified to **pattern rules**
> (`no_attr_before_defmodule`, `no_literal_list_typespec`) — consistent with `07` §3.6's taxonomy (syntax =
> won't parse; semantic = compiler diagnostic; pattern = AST-detectable) — leaving only genuinely-unparseable
> fixers in `lib/syntax/`.

| # | Files (credence) | Task | Acceptance |
|---|---|---|---|
| **T1.1** | `lib/mix/tasks/credence.ast.ex` (new) | `mix credence.ast` — reads code (stdin/file), prints **two views**: raw `inspect(Sourceror.parse_string!(code), pretty, limit: :infinity)` (incl. `{:__block__,_,[lit]}` wrappers) + layout-stripped. **Never** emit `normalize_sourceror_ast`/unwrapped form. | **Dogfood:** run on a snippet a known rule matches; dump matches what that rule's `check/2` pattern-matches. |
| **T1.2** | `lib/mix/tasks/credence.covers.ex` (new) | `mix credence.covers` — reads a snippet, runs `Credence.fix` + `analyze` in Credence's **default (helpful) `assumptions:` mode** (no `:strict` override — must match how solve's Validator runs Credence, else a switch-gated pattern reads NOVEL here but COVERED in solve; `07` §3.5/§3.10); prints `COVERED` iff a **real rule engaged**: `result.code != input` **or** `result.applied_rules != []` **or** `result.issues` has a **non-parse-error** issue; else `NOVEL`. **🔴 Must filter the synthetic `parse_error_issue`** — `Pattern.analyze` (`pattern.ex` `{:error,…}` branch) emits it for *any* non-parsing input, so a naive `issues != []` falsely reads COVERED on every novel **syntax** snippet and kills all new-syntax-rule creation (`07` §3.7 🔴 note). Accepts **non-parsing** input. Names no rule. | A snippet an existing rule fixes/flags → `COVERED`; a genuinely novel snippet (incl. a **non-parsing** one no syntax rule matches) → `NOVEL`. |
| **T1.3** *(optional)* | `lib/pattern.ex` (`apply_or_revert` revert branch) | **Visibility only:** call `RuleHelpers.log_diff(name, source, fixed)` in the revert branch (today only the keep-branch logs the diff) so a reverted fix's before/after lands in the row log for the implementer seed. **Do NOT touch the revert *logic*** — `:reverted` is already correct. | Reverted fixes show a before/after diff in the log; full credence suite green. Skippable — the seed can be reconstructed from solve-attempt code + `APPLIED_RULES`. |
| **T1.3b** *(HARD prereq for the semantic lane — T5.1; log-only, no behaviour change)* | `lib/semantic.ex:130` (the unmatched-diagnostic branch) | **Log the FULL diagnostic, not just its message** — change `inspect(diagnostic.message)` → `inspect(diagnostic)` so the `[credence_fix] no rule matched diagnostic: …` line carries `%{message, position, severity}` (today only `message`). This is the **new-semantic-rule signal** (`07` §3.3/§3.6), and the implementer needs `position`+`severity` to build a *real* test `diag` + `match?` (a fabricated diagnostic passes the gate but leaves the rule dead in production — `07` §5.3). Already `Logger.debug` + captured by RowLog (`row_log.ex:88` `level: :debug`); distill keeps `[credence_fix]` lines (T2.2). **Visibility only — no behaviour change.** | An unmatched diagnostic logs the full map; a failed-row solve trace carries a copy-pasteable `%{message, position, severity}` for the semantic seed; full credence suite green. |
| **T1.4** | `lib/mix/tasks/credence.equiv.ex` (new) | **`mix credence.equiv` — the CLASSIFY-TIME behavioural-equivalence pre-check (`07` §3.11). ⚑ Now THIN — reuse, don't reinvent (2026-06-08):** Credence already shipped `Credence.BehaviourEquivalence.eval_outcome/2` (try/rescue → `{:ok,v}`/`{:raise,mod}`/…, **strict `===`** value compare + exception-module parity) and the curated `Credence.EquivalenceInputs` battery (`term_lists`/`signed_integers`/`unicode_strings`/`single_codepoint_strings`/`multi_codepoint_strings`/`stability_lists`). This task is a **snippet-vs-snippet** wrapper (the `equivalence_regression_test.exs` pattern): reads `before` + a proposed `after` (or a rule module), compiles both as `fn`s, runs the `EquivalenceInputs` dimension(s) through `eval_outcome/2`. **🔴 Run-env: shell it as `MIX_ENV=test mix credence.equiv …`** — `Credence.BehaviourEquivalence` + `Credence.EquivalenceInputs` are `test/support/`-only (`elixirc_paths(:test)`), so they are NOT on the `:dev` code path a plain task runs in; under `:test` they compile (test `*_test.exs` files do not), no Credence module-home change. Warm `_build/test` at preflight/first-run (it is separate from the `:dev` build `covers`/`ast` use). **Trichotomy verdict (NOT binary):** `EQUIVALENT` (equal outcome on every input — same value under strict `===`, or same exception class) **| `REPAIR`** (`before` **raises on every** battery input *and* `after` returns `{:ok,_}` on ≥1 — the §3.10 always-crashes repair family; the verdict carries the exception class + `N/N raised` as the `mark_equivalence_repair` reason evidence) **| `DIVERGES`** (`before` had a valid value on some input that `after` disagrees with, or a non-compiling `after`). Prints `EQUIVALENT` / `REPAIR <exc> <n>/<n>` / `DIVERGES <input> <before> <after>`. **Fixed battery (the shipped dimensions), not StreamData** (determinism). **Pattern-phase only** (needs a compilable `before`; the does-not-compile `unconstructible` repair flavour can't reach here — it fails the §4.3 Pattern compile gate). Names no rule; accepts the same `defmodule` snippet form as `covers`. **Scope is classify-time ONLY** — the *built* rule's equivalence is its mandatory `_equivalence_test` (the hard `equivalence_meta_test`), run by the Gate's `mix test` (so the old "6th Gate check" needs no task here — see T4.3). **`--assumptions` (`07` §3.12):** runs in that Credence mode and **filters the battery to the admitted domain** (a `single_codepoint_graphemes` run drops the multi-codepoint inputs); run under `:strict` + each registered switch it reports the **minimal switch set** that makes `before ≡ fix` (∅ = no-promise, a set = switch-gated, "none works" = bug-or-new-switch). Reads `Credence.Assumptions` (never writes it). | Dogfood: a known-unsafe `followup.md` snippet (non-number / `[]` input) ⇒ `DIVERGES` under *all* modes; a rare-text one (`no_codepoint_string_reverse`) ⇒ minimal set `{single_codepoint_graphemes}`; a true no-op ⇒ minimal set ∅; an **always-crashes** snippet (`no_piped_regex_replace` / `no_keyword_get_integer_key` `before`) ⇒ **`REPAIR`** with the exception class + `N/N`. Reuses `EquivalenceInputs`/`eval_outcome` (no duplicate battery); runs under `MIX_ENV=test`. |

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
| **T3.1** | `lib/tunex/classify/prompt.ex` (new) | Build prompt: distilled log + `APPLIED_RULES` (path-resolved closed set) + whole ledger + convention prefixes (`no_/prefer_/avoid_`). **Outcome-forked lens** (solved → idiomatic residual; failed → unfixed-issue) sharing one output-contract core. **🔑 Fixable-only, NO check-only (`07` §4.1, 2026-06-04 policy):** every proposed rule MUST carry a real `after`; there is **no check-only path**. Instruct: *make* the rule fixable by **narrowing `before` to its safe core** (fire only on same-answer-fixable cases; keep the dropped cases as "no issue" `_check` tests), **or** emit **`NO_ACTION`** — never a `fix_patches/2 -> []` stub. This matches the `evolution → main` reviewer's bar so generated rules pass its read first-try. **Inject the behaviour-preservation invariant (`07` §3.10; Credence ≥0.7.0):** `after` must be output-identical to `before` for **every input the active `assumptions:` admit** (Tunex's default helpful mode = every single-codepoint input); a behaviour-changing rewrite is **`NO_ACTION`** (so is a behaviour-safe but unfixable-even-narrowed one — both route to `NO_ACTION`, the only non-rule outcome). + the **codepoint↔grapheme class, now split**: **(a) type-change** rewrites (`Enum.at(String.to_charlist …)` → `String.at`, int vs string) = `NO_ACTION` *forever*; **(b) rare-text-divergent** (count·reverse·palindrome, e.g. `length(String.to_charlist s)` → `String.length`, codepoint palindrome) = **buildable as a switch-gated rule (`07` §3.12)** — tag `assumptions: [<existing switch>]`, or emit `SWITCH_PROPOSAL` if none covers it; no longer auto-`NO_ACTION` + the same-space-is-OK note. **Inject BOTH §3.10 canonical blocks verbatim:** (i) the **type-change ban** block (the BANNED `Enum.at(String.to_charlist …)` example + the "same-type codepoint↔grapheme is switch-gated, not your call here" hand-off — already live in `credence_rule_generator.ex` `@task`, carry byte-for-byte); **(ii) the new "Canonical adversarial-input checklist"** (`07` §3.10 — Unicode precomposed/combining/emoji/flag, empty/single/nil/negative-index, number-vs-char, codepoint/grapheme/byte, variable-used-elsewhere, side-effects-in-moved-code) so the classifier screens `after` against the **exact** nasty-input set the reviewer will. **Require the structured self-check (`07` §3.11):** the classifier must *enumerate the battery and state `{input, before, after, before == after}` for each* in its reasoning before proposing — any divergence ⇒ `NO_ACTION` **(one exception: a `before` that *crashes on every* battery input is a REPAIR candidate, not a divergence to suppress — the failed lens, `07` §3.3/§3.10; do NOT `NO_ACTION` it. T4.3a's `REPAIR` verdict confirms and routes it).** (This is the cheap belt; the deterministic `credence.equiv` pre-check **T4.3a** independently re-verifies, so a hallucinated "all equal" is caught and the bad idea dies before the implementer.) **Assumptions / switch discovery (`07` §3.12):** inject `Credence.Assumptions.all()` (switch **names + summaries**) — a tiny dynamic block; the classifier may add an `assumptions: [...]` field of **existing** switch names to rescue a rare-text-divergent rule (Tier 1), or, when the divergence is a clean rare-text class **no** existing switch covers, emit a **`SWITCH_PROPOSAL`** (proposed promise + the rule it'd unblock) for human ratification (Tier 2) — it MUST NOT invent a switch in the `assumptions` field. ~200-tok system prompt. | Prompt contains the closed set, ledger, prefixes, the **fixable-only / no-check-only** instruction, the reframed behaviour-preservation invariant + the type-change-forbidden / rare-text-**switch-gated** split + **both** verbatim §3.10 canonical blocks + the injected `Credence.Assumptions` registry + the `SWITCH_PROPOSAL` instruction; lens matches solve outcome; no rule-name index. |
| **T3.2** | `lib/tunex/classify/parser.ex` (new) | Parse marker output (`===DECISION===`/`===RULE_NAME===`\|`===PROPOSED_NAME===`/`===PHASE===`/`===BEFORE===`/`===AFTER===`/**`===ASSUMPTIONS===`** (optional, `07` §3.12)/`===RATIONALE===`/`===END===`) → struct; plus the **`SWITCH_PROPOSAL`** shape (`===PROPOSED_SWITCH===` {name·summary·default·divergence_class} + `===BEFORE===`, no `===AFTER===`). **No `===CHECK_ONLY===` marker** — `after` is mandatory for any *built* rule (`07` §4.1). | Round-trips a valid spec incl. an optional `assumptions` list and a `SWITCH_PROPOSAL`; tolerant of stray whitespace; a proposed rule with no `===AFTER===` is invalid. |
| **T3.3** | `lib/tunex/classify.ex` (new) | Orchestrate: option-shaping (empty closed set → no BUGFIX); `LLM.for_stage(:classify)`; validation gates (decision ∈ offered; `rule_name` ∈ closed set **and** grep-resolves; `proposed_name` snake_case; **phase-conditional** `before` parse/compile per §3.6; `before`/`after` full `defmodule`; **`after` mandatory** for a proposed rule — a missing `after` is invalid (re-ask); **`after` over-cap → `NO_ACTION`**, never check-only — that path is gone, `07` §4.1). **`assumptions` (`07` §3.12):** every name `⊆ Credence.Assumptions.names()` (unknown ⇒ invalid → re-ask — can't invent a switch here); the tag is advisory, **T4.3a `credence.equiv --assumptions` is the authority** and corrects it to the minimal set. **`SWITCH_PROPOSAL`:** validate `proposed_switch` shape → route to `switch_proposals/` (T6.x), never built. **One re-ask** (full re-send + specific error) → else `classifier_errors/`. **Note: behaviour-preservation is now MOSTLY a deterministic gate (T4.3 `credence.equiv`), not just prompt** (`07` §3.11/§3.12) — the residual judgment (clean rare-text class vs plain bug) stays prompt-side. | Valid spec → struct; an `assumptions` name outside the registry → re-ask; a `SWITCH_PROPOSAL` routes to `switch_proposals/`; each invalid-spec class → one re-ask → `classifier_errors/` on second failure. |

---

## Phase 4 — Deterministic lanes (`07` §3.9, §3.7, §3.11)  · *depends: T1.2, T1.3, T1.4, T2.3, T2.4*

| # | Files | Task | Acceptance |
|---|---|---|---|
| **T4.1** | router (see T6.1) | **`:reverted` lane** — BEFORE the classifier: if `APPLIED_RULES` has any `{Mod, :reverted}` → route to implementer **bugfix mode** (culprit `Mod`, broke-compile sub-shape), **skip classifier**. First culprit only. Works against current Credence (no gate fix). | A row with a `:reverted` culprit never calls the classifier; goes straight to bugfix. |
| **T4.2** | `lib/tunex/novelty.ex` (new) | **Novelty pre-check** — for `POTENTIAL_NEW_RULE` only: shell `mix credence.covers` in clone on `before`. `COVERED` → `duplicate/`, skip implementer. `NOVEL` → proceed. (Runs after the classifier, before naming/implementer.) | A `before` an existing rule covers → `duplicate/`, no implementer run; novel → proceeds. |
| **T4.3** | `lib/tunex/equiv.ex` (new) + `lib/tunex/evolve/gate.ex` | **Behavioural-equivalence check (`07` §3.11/§3.12) — pattern-phase, TWO run-points.** (a) **Classify-time pre-check** (for a fixable `POTENTIAL_NEW_RULE`/BUGFIX, after novelty): shell `MIX_ENV=test mix credence.equiv` (with the spec's `assumptions`, `07` §3.12) in clone on the classifier's `before`/`after`; it returns the **trichotomy verdict + minimal switch set**. **`EQUIVALENT`:** ∅ ⇒ proceed no-promise; a set ⇒ proceed switch-gated (overriding/correcting the spec tag). **`REPAIR`** (`before` raises on every admitted input, after succeeds — §3.10) ⇒ proceed to implementer in **repair sub-mode** (emits `mark_equivalence_repair` seeded with the verdict's exception-class + `N/N` evidence; **not** `behaviour_diverged/`). **`DIVERGES`** under all registered switches ⇒ **`NO_ACTION`** → `behaviour_diverged/` (or `SWITCH_PROPOSAL` if the classifier flagged a clean rare-text class, T4.4), skip implementer. (b) **6th Gate check — SUBSUMED (2026-06-08), no new Gate code.** The built rule's behaviour is checked by its **mandatory `_equivalence_test.exs`** (Credence's hard `equivalence_meta_test`; runs the **actual `fix(before)`** over the `EquivalenceInputs` battery, strict `===`), which the Gate's existing full `mix test` already runs — a diverging fix fails its own test → suite RED → reject → `escalated/`. So `gate.ex` needs **no `credence.equiv` invocation**; the work moves to T5.1/T5.2 (the implementer must *author* a real equivalence test, anti-stub-enforced). Non-pattern phases have no equivalence test (their §3b gates apply instead). | A behaviour-diverging proposal never builds (a); a `REPAIR` verdict (always-crashes `before`) proceeds in repair sub-mode and lands with `mark_equivalence_repair`, NOT `behaviour_diverged/`; the minimal-set decides no-promise vs switch-gated; an implementer that broadens onto an admitted-input divergence fails the rule's own equivalence test in the Gate suite; a true (partial-)no-op passes. |
| **T4.4** | `lib/tunex/switch_proposal.ex` (new) + `lib/mix/tasks/tunex.switch_proposals.ex` (new) | **Switch-discovery lane (`07` §3.12 Tier 2, propose-with-evidence — HUMAN-gated).** A `SWITCH_PROPOSAL` decision (or T4.3 "diverges under all switches" + classifier-flagged clean rare-text class) → write a record to `switch_proposals/` (proposed promise: name·summary·default·divergence_class + the `before` it'd unblock). **Aggregation task** `mix tunex.switch_proposals` clusters records by proposed promise and **ranks by DEMAND** (count of distinct rule proposals each would unblock — code-pattern frequency, the one evidence the harness actually has; NOT runtime-data frequency, which it can't see). **The harness never writes `lib/assumptions.ex`** — a human reads the ranking and authors the switch + generator + CHANGELOG in Credence; next run, Tier 1 picks it up. | A clean-rare-text-but-no-switch proposal lands in `switch_proposals/`, never builds; `mix tunex.switch_proposals` prints promises ranked by how many rules each would unblock. |

---

## Phase 5 — Implementer (`07` §5, §6)  · *depends: T1.1, T2.4; **T5.1 semantic branch depends on T1.3b** (the full-diagnostic log — without it a new-semantic-rule has no real `%{message,position,severity}` to seed `match?`/`diag`, so it can only fabricate one → a rule that passes the Gate but is dead in production; T1.3b is a HARD prereq for the semantic lane, not optional)*

| # | Files | Task | Acceptance |
|---|---|---|---|
| **T5.1** | `lib/tunex/implement/seed.ex` (new) | **Phase-conditional seed**: pattern/semantic → AST dumps (shell `mix credence.ast` on before+after) + rule/test exemplar; syntax → templated before/after module strings + `Credence.Syntax.Rule` exemplar (no AST dump). Bugfix → + offending rule full source + all globbed tests. Path-convention line. **Re-state the behaviour-preservation invariant (`07` §3.10/§5.3; Credence ≥0.7.0):** the implementer writes `fix/2` and could regress it by broadening the match onto a behaviour-diverging input, so inject the invariant (output-identical for **every admitted input**) + the codepoint↔grapheme split (type-change forbidden forever / rare-text-divergent **switch-gated via `07` §3.12**). **NO check-only escape (`07` §4.1):** the implementer must write a real `fix_patches/2`; if it can't keep the fix safe even on the narrow core the classifier handed it, it `gave_up`s — it does **not** ship a `-> []` stub. **Assumptions (`07` §3.12 Tier 1) — when the spec carries `assumptions: [...]`:** emit `def assumptions, do: [...]` (the settled existing-switch names) **plus** a `Credence.Pattern.<Rule>PropertyTest` from a **fixed template** asserting `before ≡ fix` over Credence's **shared** `single_codepoint_string/0` generator (injected as a seed exemplar). **Author NO generator and propose NO new switch** — that is human-gated Tier 2. A `no-promise` rule (`assumptions: []`) emits neither, as before. The 0.7.0 meta-tests (tagged-rule-needs-property-test; `assumptions/0 ⊆ names()`) gate both at the Gate (`07` §10). **Inject BOTH §3.10 canonical blocks verbatim here too:** (i) the **type-change ban** (the implementer writes `fix/2` and must not broaden into a type-changing rewrite) and (ii) the **adversarial-input checklist** (Unicode/edge/value-kind/side-effect — same set the reviewer uses). **Inject the §5.6 test conventions:** fix tests compare the **whole output with `==`** (BAN `=~`, `String.contains?`, `String.match?`/`Regex.match?`, `starts_with?`/`ends_with?`, `String.split`+`Enum.at` slicing — even for negatives); `expected` from the rule's **real** output; **heredocs only** (no `\n`-escapes); `_check` includes the dropped-unsafe cases as "no issue"; `check`/`fix` agree — so the emitted tests are reviewer-ready and need no normalization downstream. **⚑ Scaffold first + READ-BACK (`07` §5.0 step ★1b/§5.3, 2026-06-08):** after T5.4 runs `mix credence.gen.rule <FinalName> --type <phase>`, the seed builder **reads the generated stub files back and injects their FULL contents** (rule + every generated test file) as the exact gate-passing template the model FILLS — an explicit orchestrator action (`File.read!` each generated path), not an implicit side effect. So a wholesale emit can't drop a required shape. **Semantic only — also inject the REAL captured diagnostic** (`%{message, position, severity}` from the failed-solve trace's `[credence_fix] no rule matched diagnostic` line, T1.3b) as `===REAL_DIAGNOSTIC===`; the implementer copies it verbatim into the `_check`/`_fix` test `diag` literal and derives `match?` from it, so the rule fires in production (a fabricated diagnostic passes the gate but ships a dead rule, `07` §5.3). **Emit a mandatory Pattern `_equivalence_test.exs` (`07` §5.6):** `<Name>EquivalenceTest` calling `assert_equivalent(before, rule: Rule, vars: [...], inputs: <Credence.EquivalenceInputs dimension>)` picked for the rule's risk class (must clear anti-stub: fires + rewrote + ≥3 **discriminating** inputs; passes strict `===`). **`vars` = the ordered free vars of `before`, read off the seed's AST dump** (no spec field; a wrong list / non-discriminating dimension fails the focused `mix test` → retry, self-correcting); a constant-output-by-design rule sets `allow_constant_output: true`. **Repair sub-mode (T4.3a `REPAIR` verdict):** emit `mark_equivalence_repair(reason)` with the reason built from the verdict's exception-class + `N/N raised` evidence. For the other non-preserving rules use `mark_equivalence_{cosmetic,unconstructible}(reason)` (repair = a `before` invalid on every input, `07` §3.10). **For a new SYNTAX/SEMANTIC rule, emit the §3b substance shapes** the hard `syntax_meta_test`/`semantic_meta_test` demand: positive + negative + a real transform + **`valid_syntax?(fix(...))`** + (syntax) the **fixpoint** `analyze(fix(...)) == []` + (semantic) attribution `to_issue(...).rule == :<snake>` — via the `Credence.RuleCase` verbs (no direct parser calls). The generator emits all these shapes; the fill pass makes them green. **Self-run the §3.11 battery before emitting `fix`** (compute `{input, before, after}` per input; **narrow the match until every battery input is a no-op**) — the rule's **own mandatory `_equivalence_test`** (run by the Gate's `mix test`, strict `===`, anti-stub) re-verifies this deterministically, so a broadened match that diverges on a battery input fails the suite and is rejected, not landed. | Seed for each phase contains the right primitives + the reframed behaviour-preservation invariant + **both** verbatim §3.10 canonical blocks + the §5.6 test conventions + the no-check-only instruction + the §3.12 Tier-1 assumptions / property-test-from-shared-generator instruction (and the "no generator authoring / no new switch" bound); never runs the AST helper on a syntax (non-parsing) snippet. |
| **T5.2** | `lib/tunex/implement/output.ex` (new) | **File-keyed parser**: generic `===KEY===`→`%{key=>content}`. New = `RULE` + `CHECK_TEST` + `FIX_TEST` — **all three required** (every rule is fixable, `07` §4.1; a missing `FIX_TEST` is an invalid emit, not a check-only rule); **for a PATTERN rule, `EQUIVALENCE_TEST` is ALSO required** (→ `test/pattern/<rule>_equivalence_test.exs`; the hard `equivalence_meta_test` fails the Gate suite without a real one, 2026-06-08); **+ `PROPERTY_TEST` REQUIRED iff the spec has `assumptions` (`07` §3.12 Tier 1)** → `test/pattern/<rule>_property_test.exs` (the `<Rule>PropertyTest` the 0.7.0 meta-test demands). Syntax/Semantic new rules: `RULE` + `CHECK_TEST`(=`_analyze_test` for syntax) + `FIX_TEST` only, **no** `EQUIVALENCE_TEST` (Pattern-only gate). Bugfix = `RULE` + `TEST:<path>` (each ⊆ glob — which already matches `_equivalence_test`/`_property_test` — modify-only; reject new/renamed). | New-mode (all required blocks; a Pattern emit missing `EQUIVALENCE_TEST` is rejected; a Syntax/Semantic emit *with* one is rejected) + bugfix-mode samples parse; a switch-gated emit missing `PROPERTY_TEST` is rejected; a no-promise emit with a stray `PROPERTY_TEST` is rejected; out-of-glob `TEST:` path rejected. |
| **T5.4a** | ~~`lib/tunex/implement/naming.ex`~~ — **SUBSUMED by the generator (2026-06-08)** | **Phase-conditional check-test filename** (`07` §5.4) — **no longer Tunex logic.** `Credence.RuleName` + `mix credence.gen.rule` (T5.4) own the filename fork (`_check_test` for pattern/semantic, `_analyze_test` for syntax) by construction. Tunex just maps the `CHECK_TEST` role marker onto whichever file the generator created. Keep this row as a pointer; the work is the generator's. | The generator lands a syntax new-rule's check test as `<name>_analyze_test.exs`, pattern/semantic as `<name>_check_test.exs` — verified by the generator pin, not Tunex code. |
| **T5.3** | `lib/tunex/implement.ex` (new) | **Solver loop in the clone**: emit → write files → focused `mix test` → trimmed `Report.format_errors` feedback → **flat** retry prompt (seed + last attempt + last failures) → retry ≤ `rule_gen_max_retries`. **Local size ceiling** (`rule_gen_input_ceiling`/`_output_ceiling`) → abort to `gave_up`. No tools, no token breaker. **🔴 On ANY abort path (gave_up / size-ceiling / implementer-failed) call `Gate.discard(clone)`** (`reset --hard HEAD` + `clean -fd`) — the generator (T5.4) wrote stub `lib/`+`test/` files *before* the loop, and there is no Gate on the abort path to clean them, so the orphan stubs must be reverted to honour the serial single-writer invariant (`07` §5/§5.0). | Lands a rule on a happy-path spec; aborts on a pathological oversize row, leaving a **clean** clone tree (orphan generator stubs reverted); writes only to clone. |
| **T5.4** | `lib/tunex/implement/naming.ex` (new) | Orchestrator-owned naming **+ generator scaffold (`07` §5.0/§6.1, 2026-06-08)**: `proposed_name` → first free suffix (`_2`, module `Name2`) → then **shell `mix credence.gen.rule <FinalPascalName> --type <phase>` in the clone** to write the honest-red, gate-passing skeletons (paths/module-names from `Credence.RuleName`, never hand-built; **abort-on-collision is a free name backstop**). Hand the final module + the generator's exact file paths to the **T5.1 seed builder, which reads their contents into the seed** (§5.0 step ★1b). **Runtime order within a new-rule row is T5.4 → T5.1 → T5.3** (resolve name + scaffold → build seed from the generated files → fill loop), even though the task list numbers T5.1 first. | Collision → `_2` variant; the generator writes correctly-named stubs (incl. Pattern `_equivalence_test`) that pass every meta-gate but fail their runtime assertions; the seed builder (T5.1) reads them; loop receives final paths, never picks them. |
| **T5.5** | `config/config.exs`, `lib/tunex/config.ex` | Knobs: `rule_gen_max_retries` (~5), `rule_gen_input_ceiling`, `rule_gen_output_ceiling`. | Readable via `Config`; defaults present. |

---

## Phase 6 — Router + outcomes + orchestrator wiring (`07` §2, §8, §Q10)  · *depends: 3, 4, 5*

| # | Files | Task | Acceptance |
|---|---|---|---|
| **T6.1** | `lib/tunex/evolve/router.ex` (new — replaces agentic routing) | The spine: parse `APPLIED_RULES` → `:reverted` lane (T4.1) **else** classify (T3.3) → `NO_ACTION`\|BUGFIX\|`POTENTIAL_NEW_RULE`(→novelty T4.2→**equiv pre-check + minimal-set T4.3a**→naming T5.4)\|**`SWITCH_PROPOSAL`(→T4.4 `switch_proposals/`, no build)** → implementer (T5.3, emits assumptions+property-test if switch-gated; `mark_equivalence_repair` in repair sub-mode) → **Gate** (its full `mix test` runs the rule's mandatory `_equivalence_test` — the *subsumed* 6th check, T4.3b) → commit + `Workspace.recompile_credence/1`, or reject (+ `Gate.discard` on any post-scaffold implementer abort, T5.3). One decision per row. | End-to-end on a real row: each decision path reaches its correct outcome dir / commit; a diverging proposal lands in `behaviour_diverged/`; a repair candidate lands committed with `mark_equivalence_repair`; a switch proposal in `switch_proposals/`; an aborted implementer leaves a clean clone tree. |
| **T6.2** | `lib/tunex/row_log.ex` | `close/1`'s delete → **move to `no_action/`**; add `duplicate/1` + `behaviour_diverged/1` (`07` §3.11) + `switch_proposal/1` (`07` §3.12) + `classifier_errors/1` (same shape as `escalate/1`). | Each outcome moves the log to the right dir; nothing deleted. |
| **T6.3** | `lib/tunex/evolve/ledger.ex` + callers | Write-sites move into the router: **implementer-failed + gate_reject only**. **Retire `phantom`.** `duplicate/` + `classifier_errors/` do **not** ledger. | Ledger appends on the two failure paths only; stays near-empty on a clean run. |
| **T6.4** | `lib/tunex/orchestrator.ex` | Call the router (not `CredenceRuleGenerator`) on **every row that reached solve (success AND failed)**; pass the solve outcome (for the lens fork). | Failed-solve rows reach the classifier with the failed lens. |
| **T6.5** | `lib/tunex/row_log.ex` (`ensure_ready`), `lib/mix/tasks/tunex.reset.ex` | Create + reset `no_action/`, `duplicate/`, `behaviour_diverged/`, `switch_proposals/`, `classifier_errors/`. | `mix tunex.reset` clears them; boot creates them. |

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
  focused-agentic escalation; Sourceror cheatsheet; migrating existing rules to split tests;
  **failure-/success-recycling RAG into prompts** (below).
- **Elixir Syntax-repair spike (PRE-TASK for T5.1's syntax branch)** — backed by
  [`09`](09_external_research_self_evolving_rule_systems.md) §3 (unresolved across two research passes; resolve
  by spike, not web search) and `07` §6/§3.6. **~1–2 h, zero paid tokens, no code shipped:** feed 5–10 real
  non-parsing solve attempts (from `escalated/`) to `Code.string_to_quoted/2` **and** Sourceror's fault-tolerant
  parser; record whether a usable **error locus** (line/col + token) or **partial AST** returns. **Outcome
  gates T5.1's syntax seed:** locus available → upgrade the syntax seed from blind before/after strings to a
  *targeted* locus seed (more precise syntax-rule discovery); not available → the string-only seed in T5.1 is
  *confirmed*, not assumed. Also answers whether §16's metamorphic seed→mutate transfers to non-parsing syntax.
  Cheapest concrete action; do it before committing T5.1's syntax design.
- **Offline metamorphic rule audit (`07` §16; `09` F3, StaAgent `arXiv:2507.15892`)** — a **complementary
  pipeline**, off the critical path and **off the paid bucket** (local Qwen + Credence harness). Seed from each
  rule's `_check_test`/moduledoc → semantics-preserving mutate (start α-rename only) → Credence-as-oracle
  consistency check → violations become **BUGFIX-shaped specs** routed through the *existing* T5.3 implementer
  bugfix mode + the Gate (no new back-end). Prototype after the rebuild lands 2–3 rules; prove on 5 rules
  before scaling (Java→Elixir transfer unproven). Tasks to be broken out when picked up — not the
  dataset-walk rebuild's critical path.
- **Failure-/success-recycling RAG (`07` §15; `09` F6, `arXiv:2505.00234`)** — inject 1–2 phase+recency-matched
  past outcomes (a `var/run/rag_index.jsonl`, K=1, no embeddings) into the T5.1 implementer seed and/or the
  T3.1 classifier prompt; positives from `committed/` only; injected tokens counted against T5.5's
  `rule_gen_input_ceiling`. **Measurement-gated** (build only if T8.1 shows low implementer first-try yield or
  the `no_action/` audit shows poor classifier precision) — every example adds tokens to a *paid* call. The
  classifier-calibration use de-risks "the one load-bearing unknown."
- **Switch-gated rule generation (`07` §3.12) — NO LONGER fully deferred (2026-06-04).** Split by risk:
  **Tier 1 (use EXISTING switches) IS BUILT** — classifier `assumptions: [...]` field + registry injection
  (T3.1), `credence.equiv --assumptions` minimal-set (T1.4/T4.3), `assumptions/0` + `<Rule>PropertyTest`-from-
  shared-generator emit (T5.1/T5.2). It recovers the pure rare-text `followup.md` rejections. **Tier 2
  (DISCOVER new switches) stays deferred to a HUMAN** — *propose-with-evidence*: `SWITCH_PROPOSAL` → `switch_
  proposals/` with demand ranking (T4.4); a human writes the switch + generator + CHANGELOG in Credence (the
  harness never authors a generator or touches `lib/assumptions.ex`). Type-change rewrites stay forbidden
  regardless (a switch can't promise away a type change).
- **Model-divergence A/B sampling (`07` §12)** — every N-th row, run the distilled input through **both**
  classifier models (Mimo-pro + Opus) and log both specs for calibration data (`classifier_ab_sample_every`,
  default 0=off). Mostly replayable offline from the saved `no_action/`/`committed/` logs (no-deletion, §8), so
  build the online sampler only if offline replay is too coarse. Not on the critical path.

---

## The one load-bearing unknown (call it out, measure it first)

Whether a **one-shot Mimo-pro classifier** can make the "clean-but-non-idiomatic" call at acceptable precision
**without tools** is empirical, not structural — settled only by the live `no_action/` human audit (`07` §12),
which is the first thing to watch once Phase 6 runs. Everything else is built to make this the *only* real
unknown.
