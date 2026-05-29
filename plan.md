# Plan: Self-Evolving Elixir SFT Converter (v2 app)

## Context

`scripts/convert.exs` (790 lines) outgrew a script. Today convert→refine→validate run in one tangled
flow where the local LLM sees Python instruction/code/tests *while* writing the Elixir solution —
causing **translationese / source-language interference** (Python idioms bleed into Elixir; avoiding
this is the whole point). Validation depends on **Credence** (custom AST linter, local clone at
`/home/car/projects/credence`, 81 rules, 137 tests, rules auto-discovered).

Goal: restructure main dir into a proper OTP app running a 24/7 self-evolving loop. Per SFT row:
translate (remote) → solve (local, Python-blind) → refine/validate → **learn** (cheap Mimo triage +
authoring, Claude only to rescue hard cases) → on a new rule, **revalidate** previously-failed rows.
Long-term: Credence rules self-improve so more locally-generated Elixir auto-fixes/converts. Old code
preserved runnable under `v1/`.

### Confirmed decisions
1. **Translate** = remote **Xiaomi Mimo**; produces Elixir instruction + Elixir tests **+ an Elixir
   reference solution (validation-only, never emitted/trained)**. Cached **forever**, key =
   `sha256(system_prompt + rendered_user_prompt + model)` (prompt change auto-invalidates).
2. **Test-faithfulness gate (round-trip)** = run the Elixir reference solution against the translated
   Elixir tests; require PASS before trusting the tests / running Solve. Fail → re-translate once →
   else mark row a **translation-failure** (not emitted as success), log.
3. **Canonical names** = module pinned to `Solution`; function = deterministic Elixir name from
   `entry_point` (`Parser.elixir_name`, e.g. is_palindrome→palindrome?). Injected into translate +
   reference + solve prompts; `NamingFixup` enforces. Tests/reference/solution agree by construction.
4. **Solve** = **local Qwen**, Python-blind (prompt = ONLY Elixir instruction + Elixir tests).
   Env-swappable to a remote provider for GPU-less dev. Retry + refine loop reused from v1.
5. **Evolve cascade** (cheap→expensive):
   a. **Triage = Mimo** chat: reads the row log → `{investigate?, suggestions[{what,example,rule}]}`.
      Fires only on rows with issues whose **signature is not already resolved/gave-up** (dedup).
   b. **Author = Mimo hand-rolled loop** (Mimo can't drive Claude Code): we stuff context (example
      rule+test pairs, `RuleHelpers`/`Issue` API, failing case + suggestions), Mimo returns rule +
      tests, our Elixir writes files & runs `mix test`, feeds failures back, **≤4 rounds**.
   c. **Escalate = agentic `claude -p`** in the clone, **continuing from Mimo's working-tree WIP**,
      explores repo + fixes to green, **≤3 rounds**. Only on Mimo failure → Claude usage stays rare.
6. **Gate/commit** = the agent (Mimo loop or claude -p) **edits only**, no git creds in its env.
   After it exits, our Elixir **Gate** runs `mix test` fresh; green **+ diff** → our **Git** commits
   & pushes. No diff / still red after escalation → `git checkout -- .` discard.
7. **Regression net** = full Credence `mix test` green **+** brief REQUIRES negative/regression tests
   (rule must NOT fire on good code). **No** external v1-SFT regression sample.
8. **Rule edits** = may **add AND modify** existing rules.
9. **Revalidation (closes the loop)** = error rows stored with **failure signature + last Elixir
   code**. When a new rule lands, re-run the SAVED code of error rows whose signature matches the
   rule's domain through new Credence+validate (**no LLM**); promote passers to success.
10. **Signatures** (first-class) = set of unfixable issue ids per row {remaining credence rules +
    credo checks + compile/test failure kind}. Drive (a) triage dedup, (b) revalidation targeting.
    Outcomes persisted: `resolved` (rule committed) / `gave-up` (escalation exhausted).
11. **Git topology** = dedicated **agent GitHub user** forks Credence; bot commits+pushes only to the
    **fork's `evolution` branch**. Canonical repo never gets bot commits. Two SSH identities on one
    box → per-remote `core.sshCommand`/host alias for the agent-user key.
12. **Providers** = `stages` map (`translate→mimo`, `solve→local_qwen`, `triage→mimo`,
    `author→mimo`, `evolve_escalation→claude_code`) + per-stage `TUNEX_*_PROVIDER` env overrides;
    `providers` map (url/model), keys in env/`secrets.exs`.
13. **Two budgets**: Anthropic Agent-SDK pool **$3.33/day** (= 1/30 of Max-5x's $100/mo, live
    2026-06-15) governs **only `claude -p` escalation** — when hit, Mimo keeps working and would-be
    escalations queue (signature left unresolved) until refresh. **Mimo** has its own separate
    configurable daily $ cap. Spend read from each run's `--output-format json total_cost_usd`.
14. **Runtime** = supervised **Orchestrator GenServer**, `mix run --no-halt`, single stream (no
    parallel workers, one GPU). After accepted rule: `mix deps.compile credence --force`.
15. **Boot reconciliation** = on start: `git reset --hard && git clean -fd` clone to clean
    `evolution` HEAD (discard half-written WIP); best-effort `git push` catch-up; force-recompile
    credence; resume conversion from `Progress`.
16. **Logging** = **full** Markdown digest + JSONL events for **every** row (audit). Markdown MUST
    capture code **before vs after each `Credence.fix`** + rules fired (top triage signal).
17. **Per-run agent bounds** = `--max-turns ~40` + ~15min timeout; clean working tree between rows.

Research backing: translationese / source-language interference (arxiv 2503.04369, 2503.13620,
2403.17214); learn-from-failure loops (AutoHarness 2603.03329, BitsAI-Fix 2508.03487); headless
`claude -p` agentic invocation (code.claude.com agent-sdk); Mimo-v2.5-pro pricing/SWE-bench
(platform.xiaomimimo.com, artificialanalysis.ai). Principle = isolate target-language generation from
source + gate self-generated artifacts behind their own passing tests.

## Step 0 — Snapshot current project into `v1/`
Move the whole runnable project into `v1/` (so `cd v1 && mix run scripts/convert.exs ...` works).
Keep at repo root only `.git/` and this plan (→ new `docs/`). Everything else (`mix.exs`, `mix.lock`,
`lib/`, `scripts/`, `config/`, `.formatter.exs`, existing `v1/*.jsonl`) lands under `v1/`.

## Architecture
```
Tunex.Application            supervision tree
Tunex.Orchestrator (GenServer) 24/7: pick row → translate → solve → refine → evolve → revalidate
Tunex.RowLog                 full Markdown + JSONL per row; snapshots Credence before/after
Tunex.Cache                  translate cache (cache/translations.jsonl), key=sha256(sys+rendered+model)
Tunex.Config                 stage→provider resolution + env overrides
Tunex.Signatures             compute/persist failure signatures + outcomes (resolved/gave-up)
Pipeline:
  Tunex.Pipeline.Translate   Mimo: Python→Elixir instruction + tests + reference (ONLY stage w/ Python); cached
  Tunex.Pipeline.RoundTrip   run Elixir reference vs translated tests; gate faithfulness
  Tunex.Pipeline.Solve       local Qwen: Elixir instruction + tests → solution (Python-blind); retry
  Tunex.Pipeline.Refine      review→improve→validate loop (from ConvertLoop.refine/do_refine)
Evolve:
  Tunex.Evolve.Triage        Mimo chat: row log → {investigate?, suggestions}; signature-dedup gated
  Tunex.Evolve.Author        Mimo hand-rolled loop (≤4): write rule+tests, run mix test, feed back
  Tunex.Evolve.Escalate      agentic `claude -p` (≤3) continuing from Mimo WIP; no push creds
  Tunex.Evolve.Gate          fresh `mix test`; require diff+green; else discard
  Tunex.Evolve.Git           commit + push evolution→fork; recompile workspace
  Tunex.Evolve.Revalidate    re-run saved error solutions (matching signature) through new Credence
  Tunex.Evolve.Budget        two budgets (Anthropic pool vs Mimo); pause escalation at cap
```
**Reused:** `LLM` (multi-provider), `Parser`, `Validator` (capture Credence before/after), `Workspace`
(drop pool; path dep), `Dataset`, `Progress`, `JSONL`, `Report`, `NamingFixup`, `revalidate.exs` logic.

## Flow per row
1. `Progress` → next unprocessed index; `RowLog.open`.
2. **Translate** (Mimo, cached): instruction + tests + reference solution.
3. **RoundTrip gate**: reference must pass translated tests; else re-translate once → else mark
   translation-failure + skip.
4. **Solve** (Qwen, Python-blind, canonical names): solution; retry on validation failure.
5. **Refine/validate**: `Validator.run` (credence fix→compile→format→credo→credence→test) + refine.
   Capture per-attempt Credence before/after into RowLog. Compute signature on failure.
6. **Evolve** (if issues + novel signature + within budgets): Triage(Mimo) → if YES, Author(Mimo ≤4)
   → if red, Escalate(claude -p ≤3) → Gate(`mix test`) → green+diff → Git commit+push +
   `deps.compile credence --force`; mark signature resolved. Else discard, mark gave-up.
7. **Revalidate**: if a rule landed, re-run saved error solutions of matching signatures (no LLM);
   promote passers.
8. Write SFT success/error JSONL. Loop.

## Credence dependency strategy
`Workspace` deps → local **path dep** `{:credence, path: "/home/car/projects/credence"}`. Clone on
`evolution`; remote `fork` = agent-user fork; push `evolution`→fork only. Loop compiles against LOCAL
checkout (push = backup/share). Single stream ⇒ no lock.

## Files
- **Create:** `lib/tunex/{application,orchestrator,row_log,cache,config,signatures}.ex`,
  `lib/tunex/pipeline/{translate,round_trip,solve,refine}.ex`,
  `lib/tunex/evolve/{triage,author,escalate,gate,git,revalidate,budget}.ex`, `docs/plan.md`.
  Add `:mimo`/`:claude_code` providers + `stages` map to `config/config.exs`; keys in `secrets.exs`;
  `mod:` in `mix.exs`.
- **Modify:** `workspace.ex` (path dep, drop pool, recompile helper), `validator.ex` (Credence
  before/after capture), `llm.ex` (per-stage provider). Move prompts into `Pipeline.*`.
- **Reuse:** `parser.ex`, `dataset.ex`, `progress.ex`, `jsonl.ex`, `report.ex`, `naming` helpers.
- **Snapshot to `v1/`:** whole current project.

## Verification
1. `cd v1 && mix run scripts/convert.exs educational_instruct --start 0` → old path runs.
2. Unit: Solve prompt contains NO Python; canonical module/function present in tests+solution.
3. RoundTrip: feed a deliberately mistranslated test → reference fails → row marked translation-failure.
4. Cache: row twice → 2nd is a hit; edit translate prompt → miss.
5. GPU-less: `TUNEX_SOLVE_PROVIDER=mimo mix run --no-halt` runs end-to-end, no local model.
6. Evolve happy path: stub Triage=YES → Mimo authors rule+tests → Gate green → Git commits on
   `evolution` + pushes to fork; signature marked resolved.
7. Escalation: Mimo loop can't fix (force red) → claude -p continues from WIP → green → commit. Hard
   case → discard after ≤3, working tree clean, signature gave-up.
8. Revalidation: a stored error row matching the new rule's signature gets promoted to success, no LLM.
9. Budgets: Anthropic cap hit → escalation pauses, Mimo triage/author continue, would-be escalations queue.
10. Boot recovery: kill mid-author (dirty tree) → restart → tree reset clean, credence recompiled.
11. `cd /home/car/projects/credence && mix test` green before/after.

## Unresolved (values/setup, not design)
- **Agent GitHub user + fork**: created yet? Need username, fork URL, SSH key path for per-remote
  `core.sshCommand`.
- **Mimo daily $ cap** value? And confirm Mimo API key/endpoint in `secrets.exs`.
- **Anthropic auth for `claude -p`**: subscription (Max-5x credit, live 2026-06-15) vs `ANTHROPIC_API_KEY`?

### Resolved earlier
- Daily-cap unit = dollars from `total_cost_usd`. Translate key includes prompt+model (no version tag).
- v1 `extract_*.exs` DPO mining = deferred. Credence rules auto-discovered (no registry edit).
