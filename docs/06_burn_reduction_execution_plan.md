# Burn-reduction execution plan (the agreed build)

*Written 2026-06-01 from a deep-dive grilling session + live measurement of `var/run/committed/`.*
*Supersedes the **lever ranking and the turn-cap recommendation** in [`04`](04_cost_again.md) and
[`05`](05_token_budget_truth_and_plan.md) — those were built on un-measured assumptions that the saved
transcripts disprove (see "Corrected cost model"). The constraint framing in `05` (38B-token/mo bucket,
console = only truth, ledger undercounts ~20×) still holds.*

---

## TL;DR — what we're building and why

**Goal (confirmed):** maximise **rules per 38B-token bucket**, running **24/7**. Optimise
*rules-per-token*. Duty-cycle throttling is a last resort only (it lowers rules-per-bucket — strictly
dominated). Need ~4–8× burn cut.

**Root cause of the burn (now measured, not theorised):** cost ≈ `sessions × turns × growing-prefix`,
and it is **~92% `cache_read`** — i.e. the **re-read of the conversation prefix on every turn**. Output is
a rounding error. So every token we remove from the prefix is saved **once per turn (~40× on a typical
session)**. That is the whole game.

**The plan is two families of lever:**

1. **Shrink the re-sent prefix** (zero rule-recall risk — DO FIRST, measure, then triage):
   - **Distill the agent prompt** — stop feeding the raw debug firehose; feed only the Qwen-solver
     interaction + Credence fix traces. (Q3–Q6)
   - **Starter kit** — hand the agent a tiny curated context so it stops *exploring* (the worst tokens to
     waste, billed ~40×): path-convention line + rule-name index + **one** small pattern rule+test exemplar
     + named-small fallbacks. (Q9)
   - **`max_turns` stays 80** (a backstop, NOT a savings lever — see data). Add a **per-session token
     breaker** + reduce turn *count* via the better context above. (Q7)
2. **Cut whole sessions** — **triage** out the 62% `no_opportunity` rows so the agent runs *less*.
   **← OPEN. This is tomorrow's branch.** (designed in `04` §1/§3; revisit with the corrected cost model.)

**Plus two non-cost changes** decided this session:
- **Measurement fix:** record `summed_usage` (already computed in `claude_code.ex`) as the cost basis so
  `mix tunex.usage` stops undercounting ~20×; validate once against the console via `mix tunex.diag`.
- **Escalated dead-ends → committed to Credence** on a separate `failed` branch (data-only), reviewable on
  GitHub. (Q11–Q12)

---

## Corrected cost model (the measurements that overturn docs 04/05)

Measured from `var/run/committed/*.json` (53 landed-rule transcripts) + `*.log` (the fed prompts):

1. **`max_turns` 80→12-15 was the headline rec in 04/05. It is WRONG — it would destroy yield.**
   Real `num_turns` distribution of **landed** rules: `min=10 p50=20 p75=28 p90=34 p95=42 max=56 mean=23.5`.
   A cap of 15 clips **79%** of your rules; 20 clips **49%**; even 34 (p90) clips 11%. Docs guessed "13-17
   turns" and never read `num_turns`. **Decision: `max_turns` stays 80** — it's a runaway backstop, not a
   lever. Aggressive turn-capping is anti-correlated with the primary goal.

2. **Cost is ~92% `cache_read` (re-read prefix).** e.g. row 22006 (17 turns): `cache_read=1,391,104`,
   `input=101,684`, `output=13,433`. Per-session result-event totals: `p50=1.06M, max=4.3M` tokens — and
   that is the **undercount**.

3. **The "x20" mystery is solved.** The ledger logs the **result event's** usage = the prefix on the
   *final* turn. The bucket bills the prefix on *every* turn, and the prefix grows turn-by-turn, so true
   debit ≈ `final_prefix × (turns ÷ 2)`. It scales with length: ~8× at 17 turns, ~25×+ at 56 turns —
   averaging the observed "~x20". **Consequence (the lever):** shaving 20K off the prefix saves
   ~20K × turns ≈ **~800K bucket tokens/session**. `mix tunex.diag` (with the console cookie) will pin the
   exact multiplier.

4. **Where the prefix comes from:** the fed *initial* prompt is ~21–124KB (the row-log firehose), but a
   final-turn prefix is ~1.39M tokens — so the **overwhelming majority is the agent's own accumulated tool
   output**, re-read every turn (full `mix test` dumps + `mix run -e` experiments + file reads). The
   firehose is dominant for *short* sessions; tool-output growth is dominant for *long* productive ones.

---

## Locked decisions (the build spec)

### Lever 1 — Distill the agent prompt (the re-sent firehose)  [zero recall risk]

**Problem:** `RowLog` pins a `:debug` logger handler that captures *everything* — `Validator` dumps the
full module code, test code, before/after Credence fix, compile/credo/test output, **for every one of up
to 5 solve retries** — and the whole blob is injected as `## Row log` and re-sent every turn.

**Decisions:**
- **Source = the log (NOT a structured artifact).** Rejected the structured "final result" approach because
  an over-triggering rule can fire on an *intermediate* attempt and be masked by Qwen's later rewrite — the
  final state would hide it, losing a real rule-fix opportunity. The log holds **every attempt**.
- **Keep ONLY the Qwen-solver interaction + Credence fix trace; everything else is poison.**
  - **Keep:** the task+test **once** (round 1 — `build_retry` already omits the task on rounds 2+); then
    **every attempt's** Credence fix trace (before/after/`applied_rules`/issues), un-deduped. The fix
    trace's "before" *is* that attempt's Qwen output, so no separate code copies needed.
  - **Drop:** ALL translate/round-trip output — the **original Python** and the **reference Elixir
    solution** are actively harmful (anchor the agent / cross-language poison; solve is reference-blind by
    design and the prompt must be too). Also drop all `Validator` stdout (compile/credo/test) and metadata.
- **Robustness mechanism = marker-fencing at the SOURCE, not heuristic text-filtering.** Brittleness =
  any chance of dropping a fix diff; the bloat is multi-line *untagged* blobs, so a tag/line denylist is
  exactly the brittle thing. Instead, emit explicit stable markers (code constants) around each high-value
  block, **per attempt** (`<<FIX_TRACE rule=.. attempt=N>> .. <<END>>`, `<<APPLIED_RULES ..>>`,
  `<<SOLVE_CODE attempt=N>>`, `<<ISSUES>>`). Distiller rule: **keep fenced verbatim, drop everything
  unfenced.** Depends only on marker constants → a log-format drift can't drop a diff. Translate/round-trip
  content is never fenced → dropped for free. The natural markers already in old logs (`module BEFORE/AFTER
  credence fix`, `APPLIED_RULES`) get promoted to those constants so the existing corpus is still auditable.
- **Distillation changes only the PROMPT, not the disk log.** Full firehose still written to
  `var/run/logs/` for forensics. Flag-gated, instant revert.

**Validation methodology (3 of 4 steps free, on data we already have):**
1. `distill/1` as a pure function; full logging unchanged.
2. **Exhaustive deletion audit (free):** run over **every** `committed/*.log` + `escalated/*.log`; assert
   invariant — fenced fix-trace count **raw == distilled, per attempt**; final solve code+test, every
   `APPLIED_RULES`, remaining issues all survive. If any *landed-rule* row loses a diff → distiller wrong,
   fix before live.
3. **Savings estimate (free):** token-count distilled vs raw × the `num_turns` distribution → projected
   per-session bucket saving (remember the ~per-turn multiplier).
4. **Live confirm (bounded):** flip flag ~50–100 rows; compare **console Δ/row** (ground truth) +
   summed-usage/session + **committed rows/day** (must not drop) + spot-check that over-firing-narrowing
   rules still land.

### Lever 2 — Starter kit (stop the agent exploring)  [zero recall risk]

Observed waste: agent `ls`-es with wildcards, and reads a *random* (possibly massive) rule/test file "to
get a feel". Each wasted read sits in the prefix, billed ~40×.

**Decisions (option a — one curated exemplar + named-small fallbacks):**
- **Path-convention line** (replaces `ls`/`tree` — a full 303-file tree would itself cost ~3K tok × ~40):
  "rules `lib/<phase>/<name>.ex`, tests `test/<phase>/<name>_test.exs`, dispatchers `lib/<phase>.ex`,
  helpers `lib/rule_helpers.ex`." (AI reads `tree` fine, but the convention line is ~30 tokens vs ~3K.)
- Keep the existing **rule-name index**.
- **One inlined small pattern exemplar** (rule + test) — pattern is the dominant phase (every committed
  rule we saw was `pattern/`). Curation targets (hand-pick, FIXED, never dynamic — dynamic risks grabbing a
  huge file): `lib/pattern/prefer_enum_reverse_two.ex` (64 lines) +
  `test/pattern/no_kernel_shadowing_check_test.exs` (63 lines) or similar small clean ones.
- **Named small fallbacks** for the rare non-pattern case: "writing a syntax rule? read
  `lib/syntax/fix_scientific_notation.ex` (65 lines) — don't browse." Only *small* files are ever named.

### Lever 3 — Turn handling  [backstop + byproduct, not aggressive cap]

- **`max_turns` = 80** (unchanged — see data; never clip a real rule).
- **Per-session token breaker (b):** kill a live session when its **`summed_usage`** (already accumulated
  in `claude_code.ex collect/2`) crosses a ceiling — bucket-aligned (lets a cheap distilled 50-turn session
  run, kills a token-hog). **Ceiling TBD after measurement** (must sit above the most expensive *legitimate*
  committed session, below runaways; no `summed_usage` captured yet → set generously high first, tighten
  after one measured pass).
- **Reduce turn COUNT via Levers 1+2** (better context → fewer exploration turns) — the only "fewer turns"
  path that doesn't trade against yield.

### Testing — explicitly NOT restricted

Agent runs **whatever tests it wants, as often as it wants**. The **Gate** is the backstop (rule + all work
dropped if the full suite isn't green). We rejected wrapping/forbidding `mix test`. (`mix test` is terse on
success and verbose only on failures — which the agent needs — so it isn't the main driver once exploration
is fixed.)

### `decisions.md` ledger — LEFT AS-IS

Considered recency-capping the injected slice (it's re-sent ~40× and grows all run), but decided to leave
it. It only logs dead-ends (not the 62% no_opp), and `mix tunex.reset` clears it every few days.

### Measurement fix — record `summed_usage` as the cost basis

`claude_code.ex` already computes `summed_usage` (Σ per-round-trip usage = the real bucket debit) but only
RECON-logs it; `Budget.record` persists the undercounting result-event usage. **Change: log/record
`summed_usage`** so `mix tunex.usage` ≈ console. Validate once via `mix tunex.diag` (auto console
before/after recon) to name the exact multiplier. Project ALL savings off summed/console, never the
result-event count.

### Escalated dead-ends → Credence `failed` branch  (Q11–Q12)

Move escalated artifacts off the local machine into the repo, reviewable on GitHub (the `gave_up` queue is
human rule-mining feedstock for the primary goal).

- **Separate full clone** (option b — simplest; "just another repo", no worktree concepts, no branch
  switching in the main clone). Lives at sibling `../credence_failed` via `Config.credence_failed_clone/0`
  (gitignored). **Branch base = `main`** (stable; NOT `evolution`, which is volatile/PR'd/reset).
- **Preflight + boot must ensure it exists & is healthy:** if missing → create (`cp -r` the clone or fresh
  `git clone` from origin — carries the PAT remote), checkout `failed`, set noreply identity. If present →
  ensure on `failed` + reconcile. **No deps/compile** (data-only). Fail Preflight loudly if broken.
- **Format:** `failed/{gave_up,rejected,phantom}/<index>.json` — one **non-compilable** JSON blob per
  dead-end (decision + solve code + test + distilled log + transcript). Never live `.ex`/`.exs` (would break
  `mix`/the Gate). Orchestrator writes+commits+pushes there; the agent's evolution clone is never touched,
  so no grep-pollution and a clean evolution→main PR.

---

## Build sequencing (with measurement gates)

> Order = lowest-risk, highest-leverage, measure-before-trusting. Each gate reads the **console Δ** (ground
> truth) over a fixed window, not the ledger.

0. **Measurement fix** (record `summed_usage`) + run `mix tunex.diag` once → name the real multiplier.
   *Prereq for trusting every later number.*
1. **Lever 1 (distill prompt)** + the free offline audit on `committed/`+`escalated/` → then live-confirm
   ~50–100 rows. Gate: console Δ/row down, committed rows/day stable, over-fire rules still land.
2. **Lever 2 (starter kit)** → live-confirm. Gate: fewer exploration tool-calls/session, committed stable.
3. **Per-session token breaker** — set ceiling from the now-measured `summed_usage` distribution.
4. **`failed`-branch escalation** (independent; can land any time).
5. **MEASURE the combined cut vs the 4–8× target.** If short → **triage (the open branch)**.

---

## OPEN — tomorrow's branch: TRIAGE (cut whole sessions)

The user's stated priority ("use agentic mode less"). Deferred to *after* measuring Levers 1–3 because it's
the only lever with **rule-recall risk** and the shrink levers may cover much of the 4–8× alone.

**The target:** 62% of rule-gen rows return `no_opportunity` — a full agentic session to conclude "nothing
to do." Replace that with cheaper decisions.

**Design seed (from `04` §1/§3, to revisit with the corrected cost model):**
- **Tier 1 — deterministic pre-filter (zero LLM):** decide "no rule" from data Credence *already computed*
  (`analyze`/`fix`: compile-fail, AST-equivalent-to-reference, fully-covered-by-applied-rule). **Caveat we
  surfaced:** the *highest-value* signal — clean, passing, zero-issue but non-idiomatic code — is invisible
  to deterministic checks (Credence sees nothing). So Tier 1 can only safely drop the *clearly dead*; the
  clean-zero-issue bulk still needs judgment.
- **Tier 2 — one cheap single-shot classifier (no tools, no agentic loop):** keep/drop decision; the
  agentic session fires only on confirmed candidates. This is the real "less agentic" win — replacing the
  multi-turn no_opp session with one structured call.
- **False-negative protection is non-negotiable:** permanent ~10% **shadow lane** (route some triaged-out
  rows to the full agent) to bound the miss rate; dropping a real rule is the existential failure.

**Open questions for tomorrow:**
1. Deterministic-only first, or straight to deterministic + single-shot classifier?
2. What fraction of the 62% is "clearly dead" (safe deterministic drop) vs "clean-zero-issue" (needs the
   classifier)? — answerable from `rows.jsonl` + the saved logs.
3. Classifier prompt + the keep/drop threshold (start generous, tighten via shadow data).
4. Does triage even get built, or do Levers 1–3 already clear 4–8×? (Gate after step 5 above.)

---

## Decision log (quick reference)

| # | Decision |
|---|---|
| Target | Max rules per 38B bucket, 24/7; optimise rules-per-token; duty-cycle = last resort |
| Global breaker | A safety bolt-on only (NOT the focus); the real work is reducing agentic burn |
| Order | Shrink prefix first (no recall risk) → measure → triage |
| Distill source | The **log** (keeps every attempt's fix trace), NOT a structured final artifact |
| Distill keep-set | Qwen interaction + every attempt's Credence fix trace; drop ALL translate/Python/reference/stdout |
| Distill mechanism | **Marker-fencing at source** (keep fenced, drop rest); not heuristic text-filter |
| Distill safety | Full log still on disk; flag-gated; exhaustive free offline audit on committed/escalated |
| Starter kit | Convention line + index + ONE small pattern exemplar + named-small fallbacks (no tree dump) |
| `max_turns` | **80, unchanged** (data: rules need up to 56 turns; capping kills yield) |
| Token breaker | Per-session `summed_usage` ceiling, kills runaways; ceiling set after measurement |
| Testing | Unrestricted; Gate is the backstop |
| `decisions.md` | Left as-is |
| Measurement | Record `summed_usage` as cost basis; validate via `mix tunex.diag`; trust console for absolutes |
| Escalation archive | Separate clone `../credence_failed`, branch off **`main`**, `failed/{type}/<index>.json` data blobs, Preflight-ensured |
| TRIAGE | **OPEN — tomorrow** |
