# Tunex v2 — self-evolving Elixir SFT converter

## What this is
A supervised Elixir/OTP app (`:tunex`) that walks the OpenCoder SFT dataset (~118k Python rows) once in a
seeded-shuffle order and, per row: **translate** (Python→Elixir, remote Mimo) → **round-trip check** →
**solve** (Elixir-only, Python-blind) → **validate** (via Credence) → **rule-gen** (a Claude-Code agent,
driven by Mimo, writes/extends/fixes a Credence rule). Old single-script code is preserved under `v1/`.

**PRIMARY GOAL = generate/validate/improve as many Credence rules as possible.** Converting the dataset is
NOT the goal — it's a 24/7 human-free *workload* that surfaces where Credence (a custom Elixir AST linter at
`/home/car/projects/credence`) is weak. Judge every choice by "more/better rules?" + "simplest thing that
works?". Dataset quality is a secondary byproduct. The run never finishes (118k × minutes ≈ years) — run it
for days, stop, PR the rules from `evolution` → `main`, then `mix tunex.reset` for a fresh run.

Full design: **`docs/01_plan.md`**. **COST: read [`docs/05_token_budget_truth_and_plan.md`](docs/05_token_budget_truth_and_plan.md) FIRST**
— it supersedes the absolute numbers in `03_cost_and_observability.md` / `04_cost_again.md` (those priced a
TOKEN-bucket plan in pay-as-you-go USD, and built every multiplier off a ledger that undercounts the real
bucket burn by ~20–50×). Setup/run guide for forkers: **`README.md`**. Detailed build log + gotchas: the
auto-memory `v2-build-status.md` / `v2-evolve-architecture.md` / `v2-cost-economics.md`.

## Cost reality (2026-06-01 — the binding constraint)
- **The plan is a TOKEN BUCKET, not dollars: Pro $50/mo = 38,000,000,000 tokens/mo** (Credits = tokens 1:1).
  Pay-as-you-go USD rates are irrelevant; ignore every `$` figure in docs 03/04.
- **Ground truth = the MiMo console**, readable via `mix tunex.budget` (`Tunex.MimoConsole` → the console's
  own `platform.xiaomimimo.com/api/v1/tokenPlan/usage`). Auth = a **Xiaomi-Account browser cookie** (NOT the
  `tp-` key) in `TUNEX_MIMO_COOKIE` / secrets `mimo_console_cookie`; it **expires** (re-grab from DevTools).
- **The in-band ledger (`usage.jsonl`, `mix tunex.usage`) UNDERCOUNTS the bucket ~20–50×** — it logs one
  Claude-Code `result` event per session; the bucket bills every multi-turn re-send. Trust the console for
  absolute spend; the ledger only for *relative* stage/outcome ranking.
- 2026-06-01 state: **26.78% of 38B used, ~7-day runway**; need **~4–8×** burn cut. Burn is **100% rule-gen**
  (solve is free local Qwen on the GPU server); within rule-gen **92% is re-sent context across turns**.
- **Plan to cut it (NOT yet built): cap `max_turns` 80→12–15 + a console-polling token circuit breaker;
  triage out the 62% `no_opportunity` rows; distill prompt + focused `mix test`.** See `docs/05`.

## Run it
```
TUNEX_RUN=1 mix run --no-halt
```
- Orchestrator starts ONLY with `TUNEX_RUN=1` (so `mix test` / `mix run -e` / dev don't kick off a paid run).
- `mix tunex.preflight` — validate clone + Mimo + CC creds without starting the loop.
- `mix tunex.reset` — wipe `var/run/` (keeps `var/cache/` = translations) for a fresh run.
- Per-stage provider override: `TUNEX_SOLVE_PROVIDER=…` / `TUNEX_TRANSLATE_PROVIDER=…`.

## Models (Mimo via `token-plan-sgp.xiaomimimo.com`; Mimo is the only PAID dep; local Qwen is free)
- **translate** → `mimo-v2.5-pro` (strongest), cached forever in `var/cache/`
- **solve** → **local Qwen** (`stages.solve: :local_qwen_thinking`, default since 2026-05-31) — FREE on a
  3090; weaker → less-idiomatic output = rule feedstock (this is the ORIGINAL design). The remote
  `mimo-v2.5` non-pro path is the **GPU-less fallback** via `TUNEX_SOLVE_PROVIDER=xiaomi_mimo_2_5` (note:
  non-pro is the EXPENSIVE tier — $3/M out — and was ~46% of total cost when left on in prod).
- **rule-gen** → Claude Code CLI with `ANTHROPIC_MODEL=mimo-v2.5-pro[1m]` (the harness ≠ the model; still Mimo)
- `mimo-v2-pro/-omni` are DEPRECATED (gone 2026-06-30) — dropped. `mimo-v2-flash` is OpenRouter-only + a
  strong coder (idiomatic), so NOT useful for solve. Secrets in `config/secrets.exs` (gitignored).
- **Real token-plan prices** (in `config.exs` `budget.prices`; the old flat 1/0.3/3 was ~83× wrong):
  pro $0.435/$0.0036(cache)/$0.87 per M; non-pro $1/$0.20/$3 per M. Plan meters discounted *Credits*, so
  logged `$` is a RELATIVE estimate — token COUNTS are exact; the MiMo console credit delta is authoritative.

## Architecture (lib/tunex/)
- `application.ex` — supervises `Cache`, `Budget`, and (if `TUNEX_RUN=1`) `Orchestrator`.
- `orchestrator.ex` — the seeded-shuffle pass; per-row try/rescue; API-error backoff; SFT append; `Progress`.
- `preflight.ex` — boot checks + reconciliation (git reset, identity, deps, recompile, CC/Mimo smoke,
  + a LOCAL-solve-endpoint smoke test: if `solve` resolves to a localhost provider, it pings it so a down
  Qwen server fails preflight instead of mid-run; remote solve providers are skipped — Mimo's host is
  already proven and a paid smoke call is avoided).
- `pipeline/{translate,round_trip,solve}.ex` — the three model stages. RoundTrip writes the single `Cache.put`.
- `evolve/{credence_rule_generator,gate,git,ledger}.ex` — drive the agent, the 5-part Gate, commit→push, ledger.
- `claude_code.ex` — Claude Code subprocess: **stream-json over a Port** (live `step N` logs + wall-clock
  timeout). NOTE: logged `step N` = streamed assistant messages, NOT `--max-turns` (Mimo emits many/turn).
- `cache.ex` / `budget.ex` / `row_log.ex` / `config.ex` / `llm.ex` / `validator.ex` / `workspace.ex`.
- `diag.ex` / `mimo_console.ex` — diagnostics sink (`diag.jsonl`) + the ground-truth console token-bucket
  reader. Tasks: `mix tunex.budget` (live remaining), `mix tunex.diag` (one session + auto console recon).

## Storage (var/, gitignored)
- `var/cache/translations.jsonl` — translations + blacklist verdicts (survives `tunex.reset`).
- `var/run/` — regenerable: `progress`, `seed`, `decisions.md` (dead-end ledger), SFT output, `escalated/`
  (gave_up/reject/phantom logs), `committed/` (landed-rule logs + CC JSON transcript), `workspace/`, `logs/`,
  + **observability ledgers**: `usage.jsonl` (per paid call: exact tokens + provider + row + est cost),
  `rows.jsonl` (per row: outcome + timing + `cost_est`), `heartbeat.jsonl` (5-min spend time-series),
  `diag.jsonl` (verbatim per-interaction capture: full chat usage + response headers, CC usage/modelUsage/
  timings, for EVERY outcome — the raw reconciliation feedstock).
- Committed rules are pushed to the **`evolution`** branch of `Cinderella-Man/credence`; PR to `main` manually.
- `credence_clone` is **optional** in `config.exs`: when unset/nil, `Config.credence_clone/0` defaults to a
  sibling `../credence` dir (resolved from the project root via `File.cwd!`), so a fresh deploy needs no edit.
- **Observe cost:** `mix tunex.budget` (GROUND TRUTH — console token bucket) > `mix tunex.usage` (by-stage ·
  by-outcome · triage est · projection — but UNDERCOUNTS the bucket ~20–50×, relative-only); live
  `[progress]`/`[Budget] HEARTBEAT`/`[ClaudeCode] USAGE RECON` log lines; `Tunex.Budget.stats/0`.

## Non-obvious facts / gotchas (don't re-litigate)
- **Logs are intentionally FULL/untruncated** (the point is to see exactly what happened); only short-SHA +
  commit-subject are clipped.
- **Git push needs a noreply email** — a real email → `GH007 "would publish a private email"` → silent
  non-fatal push failure. `git_identity` in config.exs (`1019893+Cinderella-Man@users.noreply.github.com`)
  is applied by Preflight. The clone uses an HTTPS PAT remote (not SSH).
- **RowLog** uses a fresh `logger_std_h` handler per row (OTP forbids changing a live handler's file).
- **Workspace mix.exs** injection is idempotent (`Workspace.rewrite_deps/1`) — an earlier non-greedy regex
  corrupted it on re-inject and blacklisted every row.
- **Solve parser** falls back to bare `defmodule` blocks (models drop `---MODULE---/---TEST---` on retries).
- **Rule-gen prompt** injects a rule-name INDEX (so the agent doesn't read all ~90 rule files) and now allows
  **CHECK-ONLY rules** (`fix_patches/2 -> []`) when a clean auto-fix is too complex.
- A `gave_up` pattern goes into `decisions.md` and is then NOT re-attempted in the same run (cleared by
  `tunex.reset`).
- **Prompt caching WORKS against MiMo** (~58.7M cache-read tokens measured; `cache_read_input_tokens` is
  returned). `02_research.md`'s "caching broken → switch to Aider/custom loop for 3–25×" is FALSE: cache is
  ~free and ~9% of cost; ~62% of cost is model OUTPUT (harness-invariant). A harness switch is ~1.2×. Don't.
- **Cost drivers** (measured): real $/rule ≈ $0.05 (NOT the $1.59 CC reports — that's Anthropic-priced
  `total_cost_usd`, which we IGNORE). Post-Qwen the bill is rule-gen, dominated by cache-MISS input
  (row log + per-turn `mix test` re-reads). Levers: solve→Qwen (~1.85×, done) > triage/build split (~1.3×,
  planned) > input distillation (~1.1×, planned). See `docs/03_cost_and_observability.md`.

## Status (2026-06-01)
M0–M5 built; all unit tests + credence suite green; live run works end-to-end; rules landing + pushing.
**Cost reckoning done (see `docs/05`):** the plan is a 38B-tokens/mo bucket, the console is the only true
meter, the in-band ledger undercounts it ~20–50×, and at 26.78% used the runway is ~7 days → need ~4–8× cut.
Burn is 100% rule-gen (solve = free local Qwen on the GPU server); 92% is re-sent context across turns.
**Ground-truth + raw diagnostics SHIPPED** (`MimoConsole`, `mix tunex.budget`, `Diag`/`diag.jsonl`,
`mix tunex.diag` auto console-recon, `modelUsage` logging) — observability only, no behavior change.
**NEXT (not built — the burn-cut plan in `docs/05`): cap `max_turns` 80→12–15 + console-polling token
circuit breaker (replaces the wrong-unit `runaway_ceiling_usd: 500`); triage out `no_opportunity`; distill
prompt + focused `mix test`.** v1 still under `v1/`.
