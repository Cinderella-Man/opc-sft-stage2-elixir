# Token-budget ground truth + the burn-reduction plan

*Written 2026-06-01 from live console data. **Supersedes the absolute cost numbers in
[`03_cost_and_observability.md`](03_cost_and_observability.md) and [`04_cost_again.md`](04_cost_again.md).***
Those docs are still useful for *lever ranking* and *mechanism*, but every dollar figure and
every multiplier in them was computed off the in-band ledger — which we now know undercounts
reality by ~20–50× (see below). Read this first.

---

## TL;DR

1. **The constraint is TOKENS, not dollars.** The plan is MiMo **Pro: $50/mo → 38,000,000,000
   tokens/month** ("Credits" = tokens 1:1; field is literally `month_total_token`). Pay-as-you-go USD
   rates ($0.435/$0.87/etc.) **do not apply** — pricing our token counts against them ("$252", "$211/mo")
   is comparing usage to a price list we never pay from. Ignore all USD figures in docs 03/04.

2. **We are burning the bucket ~20–50× faster than the ledger claims.** Console ground truth:
   **26.78% of 38B used, ~7-day runway** (period ends 2026-06-30). The ledger/`mix tunex.usage`
   says ~200M tok/day → "$211/mo"; the console says ~3.8–5.7B tok/day. **The console is the only truth.**

3. **The burn is 100% rule-gen** (the Claude-Code agent on Mimo). `solve` is FREE on this server
   (it has the GPU → local Qwen, off-budget). Within rule-gen, **92% of tokens are `cache_read` =
   context re-sent every turn**. Real cost ≈ `sessions × turns × growing-prefix`.

4. **We need ~4–8× reduction to fit 38B/month** — so it's the *stack*, not one lever:
   **(a) cap `max_turns` 80→12–15 + a console-polling token circuit breaker**, **(b) triage out the
   62% `no_opportunity` rows**, **(c) distill the prompt + focused `mix test`**.

5. **Nothing more needs to be measured to start.** Per-row economics are identical at row 20 and
   row 20,000. One *optional* `mix tunex.diag` run names the exact undercount multiplier (to size the
   breaker); not required.

---

## How we got here (the reframe, in order)

This is the reasoning chain from the 2026-06-01 session, kept so it isn't re-litigated:

1. **"$250" was never real.** Docs 03/04 priced token counts at pay-as-you-go USD. The user is on a
   **token-bucket plan** ($50 → 38B tokens). USD is irrelevant; the only question is tokens/month vs 38B.

2. **First (wrong) estimate from the ledger said "no problem":** ledger ≈ 4–6B tok/month vs 38B → looked
   like 12% usage, 6× headroom. **The ledger was lying.**

3. **The console says 10–15%/day** → ~7-day runway. So the ledger undercounts the bucket by ~20–50×.

4. **Why the ledger undercounts:** `Tunex.Budget` records token usage **once per Claude-Code session**
   from the final `result` event's `usage`. A session is **many API round-trips**, each re-sending the
   whole growing conversation (system prompt + row log + every prior `mix test` output). The token bucket
   bills *every token of every round-trip*; the ledger logs ~one round-trip's worth. With `max_turns: 80`
   and "Mimo emits several messages per turn," that's the ~20× gap. (`result.usage.cache_read` *scales*
   with `num_turns` — 15 turns→434K, 34 turns→1.84M — but appears to be roughly the final/per-turn prefix,
   not the cumulative Σ over all turns, which is ~`num_turns/2 ×` larger.)

5. **Cache discounts are irrelevant to a token bucket.** Doc 03's "caching works, it's ~free, 9% of cost"
   is a *dollar* argument. The 38B bucket debits cache-read tokens **by count**; whether they're "cheap" in
   USD doesn't matter. The re-sent context *is* the burn.

---

## The numbers (2026-06-01)

**Console (ground truth, via `mix tunex.budget`):**
```
used:      10,176,138,248 tokens   (26.78% of 38B)
limit:     38,000,000,000 tokens
remaining: 27,823,861,752 tokens
plan: Pro · period ends 2026-06-30 · auto-renew on
=> runway ≈ 7 days at current pace; need ~4–8× cut to last the month
```

**Ledger (`mix tunex.usage`, 22.21h / 231 rows — UNDERCOUNTS the bucket ~20–50×):**

| stage | calls | in | cache_rd | out | (ledger $) |
|---|---:|---:|---:|---:|---:|
| translate | 268 | 146,754 | 0 | 581,630 | $0.57 |
| **rule-gen** | **223** | **9,555,917** | **171,308,736** | **2,998,747** | **$7.38 (87%)** |
| other | 565 | 504,949 | 0 | 324,741 | $0.50 |
| TOTAL | 1056 | 10.2M | 171.3M | 3.9M | $8.45 |

- **No `solve` line** → solve is local Qwen on this server (free, off-budget). The GPU is here; the dev
  laptop is the one without Qwen.
- **rule-gen is 92% `cache_read`** = re-sent context across turns.

**By outcome (ledger $, still directional):**

| outcome | rows | mean $ | mean out-tok | note |
|---|---:|---:|---:|---|
| committed | 61 | $0.064 | 30,726 | the product |
| no_opportunity | 135 | $0.019 | 7,203 | **62% of rule-gen rows — full session to find nothing** |
| exception | 21 | $0.091 | **46,161** | **runaways — priciest, no turn cap** |
| blacklist:roundtrip_fail | 13 | $0.006 | 6,419 | cheap, pre-agent |
| gave_up | 1 | $0.024 | 5,278 | |

---

## The plan (priority order; build later)

> All multipliers below are rough. Because real cost ≈ `turns × context`, levers that cut **turns** and
> **sessions** are worth MORE than the undercounting ledger's $ implies. Re-measure each against the
> **console delta**, never the ledger.

### Lever 1 — cap `max_turns` + a real (token) circuit breaker  ★ highest leverage, lowest risk
- **Change `claude_code.max_turns` 80 → 12–15** (`config/config.exs`). The 21 `exception` rows are
  uncapped runaways (mean 46K out-tok, the priciest rows). Committed rows finalize ~13–17 turns
  (from `var/run/committed/*.json`), so 12–15 keeps most converging sessions intact.
- Optionally add `--max-budget-usd` to the CC invocation as a secondary stop (Anthropic SDK supports it;
  may overshoot by ~1 call).
- **Build a token circuit breaker in `Tunex.Budget`:** poll `Tunex.MimoConsole.usage/0` on the 5-min
  heartbeat; trip `Tunex.shutdown/1` when `remaining < floor` (config) or daily Δ exceeds a cap.
  **MUST fail-safe:** on `:auth_expired`/network error, keep running on the local estimate and warn
  loudly — never crash, never assume infinite budget. This *replaces* the useless
  `budget.runaway_ceiling_usd: 500` (wrong unit, fed by the undercounting ledger).

### Lever 2 — triage out `no_opportunity` before launching the agent
- 135/219 rule-gen rows (62%) run a full agent session to conclude "nothing to do."
- Cheapest first cut = **deterministic Stage-A pre-filter** (free, from `Credence.analyze/fix` results —
  see doc 04 §1.2). Then optionally a one-shot Mimo-pro classifier (doc 04 §1.3).
- Keep a **permanent ~10% shadow lane** (route some triaged-out rows to the full agent) to bound
  false-negatives — dropping a real rule opportunity is the existential failure (doc 04 §3).

### Lever 3 — distill the rule-gen input + focused `mix test`
- The 92% `cache_read` is the row log + per-turn `mix test` output re-sent every turn. Feed the agent the
  **solve-code + Credence fix-trace** instead of the raw row log, and run **only the new rule's test file**
  per turn (full `mix test` once at the end). Directly shrinks the per-turn prefix that dominates the bill.

### Structural fallback (only if 1–3 don't reach ~4–8×)
- Positive-filter triage (agent only on `new_rule_candidate`; cheap Mimo-write path for `extend_existing`),
  or reduced calendar duty-cycle. See doc 04 §4.3 Options A/B. (Option C Qwen-gather is moot here — solve is
  already free; the burn is the rule-gen agent, not solve.)

---

## What already exists (built + committed/staged 2026-06-01, observability only)

These are **visibility, not savings** — they change no run behavior or cost:

- **`Tunex.MimoConsole`** — reads ground-truth `used/limit/remaining` from
  `platform.xiaomimimo.com/api/v1/tokenPlan/{usage,detail,list}`. **Auth = Xiaomi-Account browser
  session cookie** (NOT the `tp-` key) via `TUNEX_MIMO_COOKIE` or `config/secrets.exs`
  `mimo_console_cookie`. **Cookie expires** (days–weeks) → re-grab from DevTools → Network →
  `tokenPlan/usage` → Copy as cURL. 401/`code:401` → `{:error, :auth_expired}` (non-fatal).
- **`mix tunex.budget`** — live remaining + runway.
- **`Tunex.Diag` + `var/run/diag.jsonl`** — verbatim per-interaction capture: full chat `usage` objects +
  **all response headers** (a quota header would show here), CC `usage`/`modelUsage`/timings/`stop_reason`,
  `summed_usage` (per-round-trip sum), for **every** outcome incl. no_opp/timeout.
- **`mix tunex.diag`** — one isolated rule-gen session + a chat header probe, with **automatic console
  before/after reconciliation** of the real debit vs the in-band figures. `mix tunex.diag --report`
  summarizes `diag.jsonl`.
- **`ClaudeCode`** — sums per-round-trip usage; logs `USAGE RECON` (result vs summed); threads row index;
  captures `modelUsage`.
- **`Budget` / `usage.jsonl`** — now also logs `modelUsage` (runs ~2% higher than `usage`).
- **`mix tunex.usage`** — `modelUsage`-vs-`usage` reconciliation section.

> NOTE: the console endpoint + the cookie auth were reverse-engineered from the live console JS bundle;
> there is **no documented** token-auth usage API (checked official docs, LiteLLM, integration issues).

---

## Open questions / next session

1. **Run `mix tunex.diag` once** (with the cookie set) → it auto-prints Δconsole vs ledger for one
   rule-gen session = the exact undercount multiplier. Sizes the circuit-breaker floor correctly.
2. **Confirm the billing period start** — runway math assumes the 26.78% accrued over ~1–2 days. The
   `tokenPlan/detail` response gives `currentPeriodEnd` but not start; check the console UI.
3. **After Lever 1 ships,** measure console Δ over a fixed window (not the ledger) to confirm the real
   multiplier, then decide whether Lever 2/3 or the structural fallback is needed.
4. **Cookie refresh story** — the breaker depends on a cookie that expires. Decide: manual re-grab when
   `mix tunex.budget` reports `:auth_expired`, vs. a longer-lived auth path (none found yet).
