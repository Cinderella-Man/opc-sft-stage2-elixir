# Tunex — a self-evolving Elixir SFT converter that grows a linter

Tunex is a supervised Elixir/OTP application that walks the
[OpenCoder `opc-sft-stage2`](https://huggingface.co/datasets/OpenCoder-LLM/opc-sft-stage2) dataset
(~118k Python rows) and, for each row, runs a pipeline:

**translate** (Python → Elixir, remote MiMo) → **round-trip check** → **solve** (Elixir-only,
Python-blind) → **validate** (via [Credence](https://github.com/Cinderella-Man/credence)) → **rule-gen**
(a Claude-Code agent, driven by MiMo, writes/extends/fixes a Credence rule).

> **The primary goal is to generate, validate and improve as many Credence rules as possible.**
> Credence is a custom Elixir AST linter. Converting the dataset is *not* the goal — it's a 24/7,
> human-free *workload* that surfaces where the linter is weak. Non-idiomatic-but-correct Elixir compiles,
> passes its tests, trips no linter issue — so the **generated code itself** is the rule-discovery signal.
> Dataset quality is a secondary byproduct. The run never finishes (118k × minutes ≈ years): you run it
> for days, stop, PR the new rules, then `mix tunex.reset` for a fresh run.

Design history and the cost/observability analysis live in [`docs/`](docs/):
[`01_plan.md`](docs/01_plan.md) (full design) · [`02_research.md`](docs/02_research.md) (a token-cost
investigation — **note its conclusions were overturned**) · [`03_cost_and_observability.md`](docs/03_cost_and_observability.md)
(the corrected, measured economics + how to read the instrumentation).

---

## What you'll need

| Requirement | Why | Notes |
|---|---|---|
| **Elixir ~1.17 + Erlang/OTP** | the app | `mix` on `PATH` |
| **A MiMo API token** (`tp-…`) | the only paid model (translate + rule-gen) | [platform.xiaomimimo.com](https://platform.xiaomimimo.com) — a Token Plan subscription works well |
| **Claude Code CLI** (Node 18+) | the rule-gen *harness* (pointed at MiMo, **not** Anthropic) | `claude --version` must work |
| **A clone of Credence** | the linter being evolved; the loop compiles/validates/pushes against it | you should **fork** it so rules push to *your* repo |
| **A GPU + local Qwen server** *(optional)* | free local `solve` (the recommended "local" mode) | OpenAI-compatible server (e.g. vLLM) on `:8000`; omit it and run "MiMo-only" mode |

"Claude Code (the harness) ≠ Claude (the model)" — `ANTHROPIC_MODEL` is set to a MiMo model, so rule-gen
introduces **no** Anthropic dependency. MiMo stays the only paid model.

---

## Two run modes

Tunex runs in one of two modes, selected entirely by **which provider serves the `solve` stage** — no
separate code branches needed:

| Mode | `solve` provider | Cost | Needs a GPU? | When |
|---|---|---|---|---|
| **Local** (recommended) | local Qwen on your 3090 | **free** | yes | you have a GPU; weaker Qwen output is *better* rule feedstock |
| **MiMo-only** | remote `mimo-v2.5` non-pro | paid (~46% of total) | no | no GPU available |

The committed default is **Local** (`stages.solve: :local_qwen_thinking` in `config/config.exs`). To run
**MiMo-only** for a single run, override at launch — no edits:

```bash
TUNEX_SOLVE_PROVIDER=xiaomi_mimo_2_5 TUNEX_RUN=1 mix run --no-halt
```

> If you prefer permanent separation you *can* keep two git branches that differ only in
> `stages.solve`, but the env override above is the maintained mechanism and avoids branch drift.
> See [`docs/03_cost_and_observability.md`](docs/03_cost_and_observability.md) for why Local mode is
> ~1.85× cheaper.

---

## Setup

### 1. Fork & clone Tunex

```bash
# fork this repo on GitHub, then:
git clone git@github.com:<you>/<this-repo>.git tunex && cd tunex
mix deps.get
```

### 2. Fork & clone Credence (the linter you'll grow)

Fork [`Cinderella-Man/credence`](https://github.com/Cinderella-Man/credence) so generated rules push to
**your** repo. Then clone it and create the `evolution` branch the bot pushes to:

```bash
git clone git@github.com:<you>/credence.git ~/projects/credence
cd ~/projects/credence
git checkout -b evolution && git push -u origin evolution
```

- `main` should be **branch-protected** (the hard safety rail — the bot never commits to it; you PR
  `evolution` → `main` manually after reviewing rules).
- The bot runs plain `git commit` + `git push origin evolution` and **never handles credentials** — your
  clone's `origin` must already be authenticated (SSH key or a PAT remote).

### 3. Point the app at your Credence clone + a noreply git identity

`credence_clone` is **optional**: when unset it defaults to a sibling `credence/`
directory next to this project (`../credence`), so if you cloned both repos side
by side (as in step 2) you can skip the path entirely. Set it only to override.

In `config/config.exs`:

```elixir
# credence_clone: "/home/<you>/projects/credence",   # optional — defaults to ../credence
git_identity: %{
  name: "Your Name",
  # MUST be a GitHub noreply email — a real email triggers GH007
  # "would publish a private email" → silent push failure.
  email: "<id>+<user>@users.noreply.github.com"
},
```

### 4. Secrets

```bash
cp config/secrets.dummy.exs config/secrets.exs   # gitignored
```

Fill in your MiMo token in `config/secrets.exs` (same `tp-…` token works for all three slots):

```elixir
config :tunex,
  secret_providers: %{
    xiaomi_mimo_2_5_pro: %{headers: %{Authorization: "Bearer tp-XXXX"}},
    xiaomi_mimo_2_5:     %{headers: %{Authorization: "Bearer tp-XXXX"}}  # MiMo-only mode
  },
  claude_code_auth_token: "tp-XXXX"   # Claude Code → MiMo Anthropic endpoint
```

The Claude Code endpoint/model are set under `:claude_code` in `config/config.exs`
(`base_url: ".../anthropic"`, `model: "mimo-v2.5-pro[1m]"`). Adjust the `base_url` host to your plan's
region (e.g. `token-plan-sgp` vs `api.xiaomimimo.com`).

### 5. (Local mode only) Start a Qwen server

Serve an OpenAI-compatible endpoint on `localhost:8000`. The model name must match
`providers.local_qwen_thinking.model` in `config/config.exs` (default `Qwen/Qwen3.6-27B`). Example with
vLLM:

```bash
vllm serve Qwen/Qwen3.6-27B --port 8000
```

### 6. Verify everything before spending a cent

```bash
mix tunex.preflight
```

This checks: the Credence clone exists, is on `evolution`, and the tree is clean (after reconciliation);
`claude` is on `PATH`; secrets are present; a one-shot Claude-Code smoke test against MiMo succeeds; the
MiMo chat endpoint is reachable; Credence compiles. It **halts with actionable fix instructions** on any
failure — no paid run starts until it's green.

---

## Running

```bash
TUNEX_RUN=1 mix run --no-halt
```

- The orchestrator starts **only** with `TUNEX_RUN=1`, so `mix test` / `mix run -e` / dev never kick off
  a paid run.
- The dataset parquet auto-downloads on first run.
- It walks the dataset in a seeded-shuffle order, persists progress, and resumes after a kill. It runs
  until you stop it (it never finishes a full pass).

After a stretch of running: review the rules pushed to your Credence fork's `evolution` branch, open a PR
to `main`, then start fresh:

```bash
mix tunex.reset   # wipes var/run/ (progress, logs, ledgers); keeps var/cache/ (translations)
```

---

## Observing cost & throughput

Everything is instrumented so you can decide whether you can afford 24/7 from data (see
[`docs/03_cost_and_observability.md`](docs/03_cost_and_observability.md) for the full story):

```bash
mix tunex.usage          # by-stage · by-outcome · triage estimate · 24/7 projection
```

While running, watch the live log lines (`[progress] … rate=R rows/hr → ~$Z/day`, and a 5-min
`[Budget] HEARTBEAT …`). On disk under `var/run/`:

- `usage.jsonl` — exact tokens + cost per paid call
- `rows.jsonl` — per-row outcome, timing, cost
- `heartbeat.jsonl` — 5-min spend time-series

**Trust rule:** token counts are exact; the `$` figures are *approximate* (the Token Plan meters
discounted Credits). For the real "can I run 24/7?" answer, compare your **MiMo console credit delta** over
a ~24h window against `monthly_allowance / 30`.

---

## Storage layout (`var/`, gitignored)

- `var/cache/translations.jsonl` — translations + round-trip verdicts; **survives `tunex.reset`**.
- `var/run/` — everything regenerable: `progress`, `seed`, `decisions.md` (dead-end ledger), the SFT
  output, `escalated/` + `committed/` (surviving row logs + Claude-Code transcripts), `workspace/`, and
  the observability ledgers above.

---

## Project layout

```
lib/tunex/
  application.ex      supervision tree (Cache, Budget, and — if TUNEX_RUN=1 — Orchestrator)
  orchestrator.ex     the seeded-shuffle pass; per-row try/rescue; progress; observability
  preflight.ex        boot checks + reconciliation (git reset, identity, recompile, smoke tests)
  pipeline/           translate.ex · round_trip.ex · solve.ex
  evolve/             credence_rule_generator.ex · gate.ex · git.ex · ledger.ex
  claude_code.ex      Claude Code subprocess (stream-json over a Port; live logs; wall-clock timeout)
  budget.ex           per-provider spend + token accounting; runaway ceiling; heartbeat
  cache.ex · config.ex · llm.ex · validator.ex · workspace.ex · row_log.ex · dataset.ex · …
lib/mix/tasks/        tunex.preflight · tunex.reset · tunex.usage
v1/                   the original single-script implementation, preserved & runnable for reference
docs/                 design + cost/observability docs
```

See [`CLAUDE.md`](CLAUDE.md) for the condensed architecture + the non-obvious gotchas (read it before
hacking on the loop).

---

## License & provenance

This evolves [Credence](https://github.com/Cinderella-Man/credence) and processes the OpenCoder
`opc-sft-stage2` dataset. Generated rules are committed to *your* Credence fork's `evolution` branch for
human review before landing on `main`.
