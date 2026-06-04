# 09 — External research: self-evolving rule systems (does docs 07/08 hold up?)

*Re-run 2026-06-04 (supersedes the failed 2026-06-02 sweep). A multi-source deep-research pass — 5 angles,
21 sources fetched, 94 claims extracted, top 25 adversarially verified (3-vote, need 2/3 to refute). Purpose:
sanity-check the [`07`](07_classifier_split_architecture.md) / [`08`](08_classifier_split_task_breakdown.md)
rebuild against 2024–26 prior art for a **solo, near-zero-budget** maintainer, and try (again) to resolve the
two Elixir-specific gaps. This is a literature/landscape doc — not a build plan.*

> **✅ This run's verification was healthy** (unlike the 2026-06-02 attempt, which a verifier tool bug reduced
> to mass abstentions). **23 of 25 verified claims confirmed 3-0; 2 were genuinely refuted on evidence (1-2),
> not abstained.** So "confirmed" here means *survived adversarial refutation*, and "refuted" means *a
> majority of skeptics found it false* — both are trustworthy this time. The one soft spot is **synthesis
> coverage of the Elixir angle** (§3), not verification integrity.

---

## 0. Bottom line

**Docs 07/08 point the right way — and the strongest support is the *direction*, not the headline numbers.**
2024–26 work independently converged on the rebuild's shape: a **closed-loop, linter-as-verifier** system with
**proposer→verifier separation** and a **deterministic re-check** instead of one-shot trust. Anthropic's own
guidance ("simplest pattern first; workflows beat agents for well-defined tasks") directly endorses deleting
the monolithic agentic session. **Two flashy quantitative claims did NOT survive** (§2) — do not lean on them.
The highest-value *new* idea is again **metamorphic auditing of existing rules** (StaAgent / Statfier), now
confirmed 3-0. The two Elixir-specific questions (Syntax-repair approach, ecosystem rule sources) are **still
unresolved after a second pass** (§3) — and that recurrence is a signal to stop web-researching them and settle
them with a small code spike instead.

---

## 1. Confirmed findings (survived 3-0 / 2-1 adversarial verification) → concrete moves

### F1 — Split the monolithic agentic session: cheap classifier + bounded implementer loop + deterministic re-check
*Confidence: HIGH. Sources: Anthropic *Building Effective Agents* (3-0); BitsAI-Fix `arXiv:2508.03487` (3-0);
CAG `arXiv:2510.12825` (the split-architecture claim survived 2-1; its *superiority* benchmark was refuted, §2).*
Anthropic: find the simplest pattern, use **workflows for well-defined tasks**, add agentic complexity only
when simpler demonstrably falls short — and "the most successful implementations use simple, composable
patterns, not frameworks" (confirmed 3-0). A classifier-then-generation split is a recognised, named design.
→ **Exactly the 07/08 thesis (kill the harness, one classifier call + a non-agentic implementer loop). Keep
going — but justify it from Anthropic's simplicity principle, not from a token-reduction headline number.**

### F2 — Deterministic linter-as-verifier re-check = the Evaluator-Optimizer pattern
*Confidence: HIGH. Source: BitsAI-Fix `arXiv:2508.03487` (3-0); Anthropic Evaluator-Optimizer (3-0).*
BitsAI-Fix re-runs the **lint scan to verify each LLM-generated fix** and regenerates over a **bounded retry
loop (≤3)** — the canonical Evaluator-Optimizer workflow (one LLM generates, a deterministic evaluator gates,
loop). → **The 07/08 novelty pre-check (re-run Credence on the isolated snippet) + the bounded implementer
retry loop are this pattern verbatim. Validated.** *(The specific "≈85% remediation in ByteDance prod" number
attached to this paper was refuted — §2. The pattern is endorsed; the figure is not.)*

### F3 — Metamorphic equivalent-mutation testing finds misfiring rules in mature linters  *(highest-value new idea)*
*Confidence: HIGH. Sources: StaAgent `arXiv:2507.15892` (4 claims, all 3-0); Statfier `shinhwei.com/statfier.pdf`
(3-0).* StaAgent **seeds programs from each rule's own description**, mutates them, and flags two concrete
problem types via a **metamorphic relation** (the rule's verdict must stay consistent across the
behaviour-preserving mutation) — it found **64 problematic rules across 5 real Java static analyzers** (SpotBugs,
SonarQube, etc.). Statfier (semantic-preserving metamorphic transforms) found **79 bugs, 46 confirmed**, across
five analyzers. → **Run an offline metamorphic audit against Credence's existing ~90 rules** — near-zero cost
(local Qwen to seed/mutate + Credence's own harness as oracle), independent of the dataset walk. It is also the
principled answer to "**how do I detect rules fighting each other**": metamorphic inconsistency surfaces
over-firing and conflict directly. **Most promising thing to prototype next.** ⚠️ *Caveat: both tools are
**Java-only**; transfer to Elixir/Sourceror is plausible but unproven — it's an open question (§3).*

### F4 — Score new rules by UNIQUE true positives, not standalone precision
*Confidence: HIGH. Source: ADE `arXiv:2509.16749` (5 claims, 3-0).* ADE scores a generated detection rule as
**`½(precision + unique-TP-rate)`** — explicitly rewarding detections **no other rule already catches** and
penalising redundancy even at high precision. → **Theoretical backing for the `mix credence.covers` pre-check**
(drop a proposal if *any* existing rule engages) and an argument to **never reward a redundant rule even when it
passes the Gate**. ⚠️ *Caveat: ADE is a **cybersecurity** detection-rule system — strong analogy, not
code-linting.*

### F5 — Avoid majority-vote multi-sampling; if you ever multi-sample, select by novelty
*Confidence: HIGH. Source: EVOL-RL `arXiv:2509.15194` (5 claims, 3-0).* Pure self-consistency / majority-vote
selection **collapses entropy and drops pass@n** by rewarding conformity to the modal answer; adding a
**novelty-aware reward** (scoring each sample by semantic distance from the others) **restores diversity**.
→ **Direct evidence against the "run the classifier N times + dedup by vote" idea** (floated and rejected during
07/08 grilling). Reinforces: **stay at one classifier call.** If multi-sampling is ever revisited, select by
embedding distance, not vote count. ⚠️ *Caveat: this is an **RL training** result — borrow the principle, not the
mechanism.*

### F6 — Recycle failed/partial attempts as in-context examples — no fine-tuning needed
*Confidence: HIGH. Sources: `arXiv:2505.00234` (self-generated trajectory DB as in-context examples, no
fine-tuning — 3-0); MAE `arXiv:2510.23595` (proposer-solver-judge roles on small Qwen — 3-0, but it is an **RL
weight-update** method, borrow only the role split).* An LLM agent can self-improve by **accumulating its own
past trajectories into a database and retrieving them as in-context examples** — zero fine-tuning, zero extra
training budget. → **Maps onto the saved `no_action/` + `escalated/` logs: RAG a few relevant past
attempts/failures into the implementer prompt.** A pure win for a zero-budget local-Qwen setup. *(Note: SOAR
`arXiv:2507.14172` was fetched for this angle but yielded no surviving named claim this run; `2505.00234` is the
better-grounded citation for the "no fine-tuning, recycle as context" move. The MAE proposer/solver/judge
**role decomposition** is reusable; its RL training loop is not.)*

---

## 2. Refuted this run (do NOT cite these as support)

Both were killed on a 1-2 adversarial vote — a majority of skeptics judged them unsupported by the source.

- **❌ "ByteDance's lint-fix pipeline hit ~85% remediation accuracy in production."** Refuted (`arXiv:2508.03487`).
  The BitsAI-Fix *pattern* (lint-verify + bounded retry, F2) stands; this **specific production figure does
  not** — don't use it to argue the loop's real-world fix rate.
- **❌ "CAG (classifier-augmented generation) outperforms both single-prompt AND agentic baselines on accuracy
  and efficiency while cutting tokens."** Refuted (`arXiv:2510.12825`). The *existence* of the classifier-split
  design survived (F1); the **headline "beats agentic on everything" benchmark did not.** The old doc's "~66%
  token cut, smaller model matches big prompt" line was this claim — **drop it.** Justify the split from
  Anthropic's simplicity principle (F1) and the 05/06 cost analysis instead.

---

## 3. STILL unresolved after two passes: the Elixir Syntax layer + ecosystem (the real gap)

Sources were fetched on this angle both runs (Sourceror repo, Credo `adding_checks`, `rfx`, the syntax-repair
survey, tree-sitter #224, dorgan's source-manipulation blog) — but **no Elixir-specific claim survived to a
verified finding either time.** The harness keeps prioritising the academic architecture papers and dropping
the operational Elixir detail (this run: 8 claims budget-dropped before verification). **Two failed attempts is
the signal: stop web-researching this and resolve it with a code spike + direct source read.**

| Lead (read these directly) | Why it matters | Source |
|---|---|---|
| **Sourceror** + `Code.string_to_quoted/2` | Can it locate the *exact* failing node in non-parsing code → targeted **Syntax-rule discovery** instead of blind string matching? Resolve empirically. | `github.com/doorgan/sourceror` ; dorgan.ar "preparing the ground for source code manipulation" |
| **`rfx`** — Sourceror-based Elixir refactoring framework | Closest existing analogue to Credence's **Pattern** phase; possible source of pre-built AST transforms / structural patterns | `github.com/andyl/rfx` |
| **Credo custom checks** | Prior art for rule structure + testing conventions (compare to Credence's check/fix split) | `hexdocs.pm/credo/adding_checks.html` |
| **tree-sitter error recovery**; LLM syntax-repair survey | Comparison points for "string-fix vs error-recovery parser vs grammar-based LLM repair" | `tree-sitter#224` ; survey `arXiv:2507.03629` |

**Reasoned take (UNVERIFIED — my synthesis from the source list, not an adversarially-confirmed finding):**
naive string-level fixing is probably *fine* for the narrow, enumerable Python-ism cases the Syntax phase
actually targets (`a div b`, scientific notation, augmented assignment), and a parser-recovery layer may be
over-engineering for that scope. But the rebuild is leaving **Sourceror's error-tolerant parsing on the table**,
and it could make Syntax-rule *discovery* far more targeted. **Settle it with a 1-hour spike**, not more
web search: feed 5–10 real non-parsing Qwen solve attempts to `Code.string_to_quoted/2` / Sourceror and see
whether it returns a usable error locus. This connects to `07` §3.6 (phase asymmetry) and §3.7 (the `covers`
pre-check's parse-error handling).

---

## 4. Honesty / provenance caveats

- **Verification was clean this run** (23/25 confirmed, 2 genuine refutes, no abstention-dropouts) — the
  2026-06-02 verifier bug did not recur. Trust the confirm/refute split.
- **Domain transfer is the main risk, not verification.** ADE (F4) = cybersecurity; BitsAI-Fix + StaAgent +
  Statfier (F2/F3) = **Java**; CAG (F1) = NL-to-ETL. **None are Elixir, and none are code-*linting-rule
  generation* end-to-end** — they are analogies that each validate one component.
- **F5 (EVOL-RL) and MAE (F6) are RL training methods** — borrow the *principle* (novelty > vote count; role
  decomposition), not the weight-update mechanism. The zero-budget constraint means no fine-tuning anyway.
- **All numeric vendor claims** (mutation scores, bug counts, token reductions) are self-reported by their
  papers; the two most load-bearing numbers were the ones refuted (§2).
- **2025 single-paper preprints, not independently replicated.** No 2026-dated unverifiable papers were relied
  on this run (the prior doc's `arXiv:2604.*` / `2602.*` citations did not resurface and are dropped).

---

## 5. Recommended next steps (zero/low cost, in priority order)

1. **Prototype the StaAgent/Statfier metamorphic audit (F3)** against Credence's existing ~90 rules — highest
   confidence, highest value, offline, local-Qwen only; surfaces over-firing + rule conflict *before* they
   pollute a run. (First sub-question: does metamorphic seeding transfer to Sourceror — answer with the same
   spike as §3.)
2. **Wire `2505.00234`-style failure-recycling (F6)** — RAG a few `escalated/` / `no_action/` examples into the
   implementer prompt; no fine-tuning, no budget.
3. **Resolve the Elixir Syntax layer with a code spike, NOT more web research (§3)** — feed real non-parsing
   solve attempts to `Code.string_to_quoted/2` / Sourceror; decide string-fix vs error-recovery empirically.
   Skim `rfx` for reusable Pattern-phase transforms while there.
4. **Bake F4 (unique-TP) into the Gate's mental model** — `covers` already drops redundant proposals; make
   "adds a unique true positive" the explicit acceptance question at `evolution → main` review.

---

## Appendix — source ledger (21 fetched, 25 claims verified, 23 confirmed / 2 refuted)

**Architecture / proposer-verifier:** BitsAI-Fix `2508.03487`, CAG `2510.12825`, Anthropic *Building Effective
Agents* (`anthropic.com/research/building-effective-agents`).
**Metamorphic rule auditing:** StaAgent `2507.15892` (+ `…v1` HTML), Statfier (`shinhwei.com/statfier.pdf`).
**Novelty scoring / diversity collapse:** ADE `2509.16749`, EVOL-RL `2509.15194` (+ `…v3` HTML).
**Failure-recycling / small-model self-improvement:** `2505.00234`, MAE `2510.23595`, SOAR `2507.14172`,
`2407.18219`, `2510.01375`, Lilian Weng "LLM Powered Autonomous Agents" (secondary).
**Elixir / tooling (UNRESOLVED angle — read directly):** `github.com/doorgan/sourceror`,
`hexdocs.pm/credo/adding_checks.html`, `github.com/andyl/rfx`, syntax-repair survey `2507.03629`,
dorgan.ar source-manipulation post, `tree-sitter#224` (forum).

*Run stats: 5 angles · 21 sources fetched · 94 claims extracted · 25 verified · 23 confirmed · 2 killed ·
7 findings after synthesis · 103 agent calls.*
