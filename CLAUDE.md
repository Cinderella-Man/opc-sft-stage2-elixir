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

Full design: **`docs/plan.md`**. Detailed build log + gotchas: the auto-memory `v2-build-status.md` /
`v2-evolve-architecture.md`.

## Run it
```
TUNEX_RUN=1 mix run --no-halt
```
- Orchestrator starts ONLY with `TUNEX_RUN=1` (so `mix test` / `mix run -e` / dev don't kick off a paid run).
- `mix tunex.preflight` — validate clone + Mimo + CC creds without starting the loop.
- `mix tunex.reset` — wipe `var/run/` (keeps `var/cache/` = translations) for a fresh run.
- Per-stage provider override: `TUNEX_SOLVE_PROVIDER=…` / `TUNEX_TRANSLATE_PROVIDER=…`.

## Models (all Xiaomi Mimo via `token-plan-sgp.xiaomimimo.com`; one paid dep)
- **translate** → `mimo-v2.5-pro` (strongest)
- **solve** → `mimo-v2.5` (non-pro; weaker → less-idiomatic output = rule feedstock) — default `stages.solve`
- **rule-gen** → Claude Code CLI with `ANTHROPIC_MODEL=mimo-v2.5-pro[1m]` (the harness ≠ the model; still Mimo)
- `mimo-v2-pro/-omni` are DEPRECATED (gone 2026-06-30) — dropped. `mimo-v2-flash` is OpenRouter-only + a
  strong coder (idiomatic), so NOT useful for solve. Secrets in `config/secrets.exs` (gitignored).

## Architecture (lib/tunex/)
- `application.ex` — supervises `Cache`, `Budget`, and (if `TUNEX_RUN=1`) `Orchestrator`.
- `orchestrator.ex` — the seeded-shuffle pass; per-row try/rescue; API-error backoff; SFT append; `Progress`.
- `preflight.ex` — boot checks + reconciliation (git reset, identity, deps, recompile, CC/Mimo smoke).
- `pipeline/{translate,round_trip,solve}.ex` — the three model stages. RoundTrip writes the single `Cache.put`.
- `evolve/{credence_rule_generator,gate,git,ledger}.ex` — drive the agent, the 5-part Gate, commit→push, ledger.
- `claude_code.ex` — Claude Code subprocess: **stream-json over a Port** (live `step N` logs + wall-clock
  timeout). NOTE: logged `step N` = streamed assistant messages, NOT `--max-turns` (Mimo emits many/turn).
- `cache.ex` / `budget.ex` / `row_log.ex` / `config.ex` / `llm.ex` / `validator.ex` / `workspace.ex`.

## Storage (var/, gitignored)
- `var/cache/translations.jsonl` — translations + blacklist verdicts (survives `tunex.reset`).
- `var/run/` — regenerable: `progress`, `seed`, `decisions.md` (dead-end ledger), SFT output, `escalated/`
  (gave_up/reject/phantom logs), `committed/` (landed-rule logs + CC JSON transcript), `workspace/`, `logs/`.
- Committed rules are pushed to the **`evolution`** branch of `Cinderella-Man/credence`; PR to `main` manually.

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

## Status (2026-05-30)
M0–M5 built; all unit tests + the credence suite green. Live run works end-to-end — **first rule landed +
pushed**: `Credence.Pattern.NoListDuplicateFlatten`. ~7 min / ~$0.50 per committed rule on slow Mimo
(acceptable). Runaway-$ ceiling = $500 (config). v1 still runs under `v1/` for reference.
