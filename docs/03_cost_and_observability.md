# Cost analysis, observability & the token-burn plan

*Written 2026-05-31, from measured production data. Supersedes the recommendations in
[`02_research.md`](02_research.md), whose central premise turned out to be empirically false.*

## TL;DR

The original worry was "agentic Credence rule-gen burns tokens like there's no tomorrow," and
[`02_research.md`](02_research.md) concluded the fix was to **abandon Claude Code** for Aider (claimed
3–5× cheaper) or a custom Elixir ReAct loop (claimed 25× cheaper), because **prompt caching against MiMo
was supposedly broken**.

Measuring the actual transcripts inverted every load-bearing claim:

| `02_research.md` claimed | Measured reality |
|---|---|
| Caching broken; ~0% hit rate; MiMo returns no cache fields | **Caching works.** ~58.7M cache-read tokens billed at the cheap rate; MiMo *does* return `cache_read_input_tokens`. |
| Re-sent context billed at full price; 5× overcharge | cache-read is **~$0.0036/M** (≈free) and ~9% of cost. |
| ~$1.2–4.8 per rule | **~$0.05 per rule** (the research read Claude Code's Anthropic-priced `total_cost_usd`, which we explicitly ignore). |
| Switch harness for 3–25× | **62% of spend is model output**, which *no* harness can reduce. A harness switch is **~1.2×** for a full rewrite — not worth it. |

**Real per-token prices** (mimo token-plan pay-as-you-go, post-2026-05-27; the prior `config.exs` values
were ~83× too high on cache and wrong on in/out):

| | input (miss) | cache hit | output |
|---|---|---|---|
| `mimo-v2.5-pro` (translate, rule-gen) | $0.435/M | $0.0036/M | $0.87/M |
| `mimo-v2.5` non-pro (remote solve) | $1.00/M | $0.20/M | $3.00/M |

> The $50/mo plan meters **discounted Credits**, so pay-as-you-go USD is only a *relative* estimate. Exact
> **token counts** are ground truth; the **MiMo console credit delta** is the authoritative absolute cost.

## Where the money actually goes

Three paid cost centers (local Qwen solve is free):

1. **translate** — `mimo-v2.5-pro`, cached forever (`var/cache/`); cheap, mostly a one-time cost per row.
2. **solve** — *was* remote `mimo-v2.5` non-pro, which is the **expensive** tier ($3/M output) and ~92% of
   its own cost is output. This was the GPU-less dev fallback accidentally left on in production.
3. **rule-gen** — the Claude Code agent on `mimo-v2.5-pro[1m]`. Its cost is **input-bound**: ~57–63%
   cache-*miss* input (row log fed once + per-turn tool reads, dominated by repeated `mix test`), ~30%
   output, ~9% (free) cache-read.

Per outcome, `no_opportunity` rows are individually **cheap** (~$0.009 rule-gen each — the agent bails
fast); the spend is concentrated in the **productive** committed-rule sessions (~$0.046/rule). That is a
*healthy* place for spend to sit.

## The levers (measured, not theorized)

| Lever | Effect | Risk | Status |
|---|---|---|---|
| **solve → local Qwen** | removes ~46% of spend → **~1.85×**; *also* restores the intended weaker/non-idiomatic feedstock | none (it's the original design) | **done** (`stages.solve: :local_qwen_thinking`) |
| **distill rule-gen input** | feed the agent solve-code + Credence fix-trace, not the whole raw transcript; ~1.1× | none | planned |
| **triage/build split** | one cheap pro chat call decides `no_opportunity` vs `candidate`; full Claude Code session only on candidates. ~1.3× (no_opp rows are already cheap, so the win is modest) | rule-recall false-negatives — mitigate with a generous threshold + shadow-eval on a random sample of triaged-out rows | planned, gated on measurement |
| off-peak scheduling | UTC 16:00–24:00 (= 18:00–02:00 Andorra/CEST) → 0.8× | — | ~7% ambient for 24/7; not a real lever |

**Calendar math** (budget is spent per row, so slower Qwen throughput stretches calendar days/$):
- Qwen + distillation ≈ 2× cost → ~12 budget-days, ×~2 slower throughput ≈ **~24 calendar days**.
- + triage ≈ 2.7× cost → ~16 budget-days ≈ **~32 calendar days** — clears a 24/7 month.

A harness switch (Aider / custom loop) adds **~0×** on top of these, for a large rewrite. Dropped.

## Observability (added 2026-05-31)

The point of all of this is to **decide from data, not theory**. Everything is instrumented:

- **`var/run/usage.jsonl`** — one line per paid Mimo/CC call: exact `in / cache_read / cache_create / out`
  tokens + provider + model + row index + derived `cost_usd`. (Raw counts exact; `$` approximate.)
- **`var/run/rows.jsonl`** — one line per row: outcome, translate source, solve result, decision,
  `elapsed_s`, `cost_est` (Budget spend-delta for the row), `ts`.
- **`var/run/heartbeat.jsonl`** — 5-min time-series of cumulative spend + token totals (spot drift).
- **Live logs** — per-row `[idx=N] finished in Xs (est $Y)`; per-row `[progress] … rate=R rows/hr →
  ~$Z/day`; 5-min `[Budget] HEARTBEAT …`.
- **`mix tunex.usage`** — by-stage · by-outcome · triage estimate · 24/7 **projection** (rows/hr, est
  $/day, est $/month, runway days on $50). Reads the two ledgers; `Tunex.Budget.stats/0` is the live
  snapshot.

### Measuring 24/7 feasibility (the authoritative method)

```
1. Note the MiMo console credit balance + timestamp.
2. Run ~24h (local Qwen up; fresh rows = representative steady state).
3. Δcredits(24h) = true cost. Also run `mix tunex.usage` for the breakdown.

   24/7 feasible all month  ⟺  Δcredits(24h) ≤ monthly_allowance / 30
```

Trust **token counts** (ledger) for *where* spend goes; trust the **console credit delta** for the
absolute *can-I-afford-it* answer. The projection's `$/day` is an early-warning gauge, not the verdict.

## Decisions & open questions

**Decided:** solve → local Qwen (default); keep Claude Code (no harness switch); fix Budget pricing to
real per-provider rates; instrument everything before optimizing further.

**Open (need data from the 24h run):**
1. Qwen throughput factor vs remote solve (drives the calendar projection).
2. Whether triage's ~1.3× is worth its rule-recall risk, or ~24 days/run + more-frequent `mix tunex.reset`
   is acceptable instead.
3. Build order: ship Qwen + distillation, re-measure, then decide triage from real numbers.
