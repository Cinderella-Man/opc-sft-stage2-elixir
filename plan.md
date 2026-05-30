# Plan: Self-Evolving Elixir SFT Converter (v2 app)

## Primary goal (read first)
**Generate and validate/improve as many Credence rules as possible.** Converting the SFT dataset is
**not** the goal — it is merely a good 24/7, human-free *workload* that surfaces where Credence is weak.
Every design choice is judged by "does this yield more/better rules?" and "is this the simplest thing
that works?" Dataset quality is a secondary byproduct.

## Context
`scripts/convert.exs` (790 lines) outgrew a script. Today convert→refine→validate run in one tangled
flow where the local LLM sees Python instruction/code/tests *while* writing the Elixir solution —
causing **translationese / source-language interference** (Python idioms bleed into Elixir). That bleed
is useful: it is exactly the non-idiomatic code that reveals **missing Credence rules**. Validation
depends on **Credence** (custom AST linter, local clone at `/home/car/projects/credence`, 81 rules,
137 tests, rules auto-discovered from `lib/{pattern,syntax,semantic}`).

Restructure main dir into a proper OTP app running a 24/7 self-evolving loop. Per SFT row: translate
(remote) → solve (local, Python-blind) → refine/validate → **learn** (Mimo authors/extends/fixes a
Credence rule). The loop runs the **whole dataset repeatedly**; new rules change outcomes of
already-processed rows, so re-passes are how regressions (both directions) get caught. Old code
preserved runnable under `v1/`.

### Confirmed decisions
1. **Translate** = remote **Xiaomi Mimo**; produces Elixir instruction + Elixir tests **+ an Elixir
   reference solution (validation-only, never emitted/trained)**. Cached **forever**, key =
   `sha256(system_prompt + rendered_user_prompt + model)` (prompt change auto-invalidates).
2. **Round-trip check** = run the Elixir reference solution against the translated Elixir tests; require
   PASS before running Solve. Fail → re-translate once → else **permanently blacklist the row**
   ("broken by definition"). *Purpose:* keep future full re-passes cheap by never re-attempting rows
   that can't work — **not** dataset quality.
3. **Canonical names** = module pinned to `Solution`; function = deterministic Elixir name from
   `entry_point` (`Parser.elixir_name`, e.g. is_palindrome→palindrome?). Injected into translate +
   reference + solve prompts; `NamingFixup` enforces. Tests/reference/solution agree by construction.
4. **Solve** = **local Qwen**, Python-blind (prompt = ONLY Elixir instruction + Elixir tests).
   Env-swappable to a remote provider for GPU-less dev. Retry + refine loop reused from v1. Qwen's
   non-idiomatic output is the **rule-discovery feedstock**.
5. **Evolve = Mimo only** (Claude dropped entirely). Deterministic **issue-dedup gate** (Elixir) in
   front of **Author**:
   a. **Author = Mimo hand-rolled loop, ≤3 rounds.** Always receives the **full current rule set**
      (all files in `lib/{pattern,syntax,semantic}`, as a cached system-prompt prefix) + the row log +
      `RuleHelpers`/`Issue` API + the row's **novel issues**. Round 1 is a **4-way decision** per issue:
      **(1) Extend** an existing rule (e.g. add `Map.sort → Enum.sort` to a conversion-list rule),
      **(2) Create** a new rule, **(3) Bugfix** an existing rule (over-firing / wrong-fix — the log
      shows tests passed *before* a `Credence.fix` and failed *after*, plus which rule edited the code),
      **(4) `NO_RULE`** (logic bug, nothing a rule can do). Mimo writes rule + tests; our Elixir runs
      `mix test`, feeds failures back, ≤3 rounds.
   b. **On Author failure** (still red after 3 rounds): dump the row's full log + Mimo's last attempt
      into an **`escalated/`** dead-letter dir for later human review; mark the issue(s) `gave-up`;
      move on. **No Claude, no automation beyond the disk write.**
6. **Trust boundary / commit** = Author **edits only** (no git creds in its env). After it exits, our
   Elixir **Gate** runs `mix test` fresh; green **+ diff** → our **Git** commits & pushes. No diff /
   still red → `git checkout -- .` discard.
7. **Regression net** = full Credence `mix test` green **+** Author-written negative/regression tests
   (rule must NOT fire on good code). Cross-dataset regressions (a new rule over-fires on
   previously-good rows) are caught by the **next full re-pass**, not by targeted machinery.
8. **Rule edits** = Author may **extend, create, OR bugfix** existing rules (see 5a). Enabled by giving
   Author the full current rule set in context.
9. **Full re-passes (the simple model)** = one **infinite loop** over the dataset; wrap at the end.
   Each pass **re-translates (cache hit, free)** + **re-solves FRESH with Qwen** (Solve is **never
   cached** — fresh sampling = new idiom variety = more discovery; GPU time is the free 24/7 workload).
   **No saved-code re-runs, no separate regression pass, no `Evolve.Revalidate`.** Regression is caught
   **statistically**: an over-firing rule breaks a *recurring* pattern, which fresh solves re-hit across
   the huge dataset → surfaces as `credence:<rule>`/`rule_regression:<rule>` → Author **bugfixes**.
   (Tradeoff accepted: a rule over-firing on a *rare* pattern lingers until that pattern recurs —
   low-stakes for a linter.) Blacklisted rows skipped; `resolved`/`gave-up` sets **persist across
   passes** (granular issue-ids make this safe — a non-generalizing rule leaves a *different*, novel
   issue-id that re-triggers Author to extend it).
   **Convergence stop:** count **Git commits to Credence per pass** (add/extend/bugfix that passed Gate
   + committed; `gave-up` and re-confirmed-`resolved` don't count). **Zero commits across one full
   start→end pass → halt cleanly** ("converged" — diminishing returns; human restarts after new
   data/prompt changes).
10. **Issues (replaces per-row signatures)** = dedup at the level of the **individual issue id**, not
    the row. Two persistent global sets: **`resolved`** and **`gave-up`**. A row triggers Author iff it
    has ≥1 issue in *neither* set; Author handles only those novel issues; each is marked independently.
    **Issue-id scheme:**
    - `credence:<rule_name>` — a rule still fires after fix.
    - `credo:<check_name>`.
    - `compile:<kind>:<token>` — via a small **regex-extractor bank** over common Elixir compile-error
      shapes (e.g. `compile:undef:Map.sort/1`); unmatched → **`compile:other`** catch-all.
    - `rule_regression:<rule_name>` — tests passed *before* a `Credence.fix`, failed *after* (buggy
      rule). Deterministic from before/after capture.
    - `test:generic` — all other (logic-bug) test failures **collapse into one id**. Author returns
      `NO_RULE` once → marked `gave-up` → **all future logic-bug rows are deduped out of authoring**
      (kills the biggest noise source). Refine still tries to fix the logic for the dataset byproduct;
      only *rule-authoring* is suppressed.
11. **Git topology (simplified)** = **single canonical repo** `Cinderella-Man/credence`. Bot commits to
    **`evolution`** branch and pushes over **HTTPS with a fine-grained PAT** scoped to `evolution` only.
    **`main` is branch-protected** (the hard safety rail). **No fork, no second GitHub account, no dual
    SSH.** The local clone at `/home/car/projects/credence` is the same checkout the loop compiles
    against (path dep) and pushes from.
12. **Providers** = `stages` map (`translate→mimo`, `solve→local_qwen`, `author→mimo`) + per-stage
    `TUNEX_*_PROVIDER` env overrides; `providers` map (url/model), keys in env/`secrets.exs`. **No
    `claude_code` / `evolve_escalation` stage.**
13. **Budget (single concern)** = **Mimo is the only paid dependency** and runs **essentially uncapped**
    with a **runaway-safety ceiling** only (abort if daily spend is absurd, e.g. 50× expected — catches
    infinite-loop bugs, not rationing). **Mimo token exhaustion → halt the whole program** (nothing
    works without Mimo). **No Anthropic pool, no `Evolve.Budget` module.**
14. **Runtime** = supervised **Orchestrator GenServer**, `mix run --no-halt`, single stream (no
    parallel workers, one GPU). After accepted rule: `mix deps.compile credence --force`.
15. **Boot reconciliation** = on start: `git reset --hard && git clean -fd` clone to clean `evolution`
    HEAD (discard half-written WIP); best-effort `git push` catch-up; force-recompile credence; resume
    from `Progress`.
16. **Logging (the feedstock, not just audit)** = **full** Markdown digest + JSONL events for **every**
    row. MUST capture code **before vs after each `Credence.fix`** + rules fired + initial vs final
    code. This log **is the literal input** Author reads to discover/extend/fix rules.
17. **Author loop bounds** = ≤3 rounds; clean working tree between rows.

Research backing: translationese / source-language interference (arxiv 2503.04369, 2503.13620,
2403.17214); learn-from-failure loops (AutoHarness 2603.03329, BitsAI-Fix 2508.03487). Principle =
isolate target-language generation from source + gate self-generated artifacts behind their own passing
tests.

## Step 0 — Snapshot current project into `v1/`
Move the whole runnable project into `v1/` (so `cd v1 && mix run scripts/convert.exs ...` works).
Keep at repo root only `.git/` and this plan (→ new `docs/`). Everything else (`mix.exs`, `mix.lock`,
`lib/`, `scripts/`, `config/`, `.formatter.exs`, existing `v1/*.jsonl`) lands under `v1/`.

## Architecture
```
Tunex.Application            supervision tree
Tunex.Orchestrator (GenServer) 24/7: pick row → translate → solve → refine → evolve; loop full passes
Tunex.RowLog                 full Markdown + JSONL per row; snapshots Credence before/after each fix
Tunex.Cache                  translate cache (cache/translations.jsonl), key=sha256(sys+rendered+model)
Tunex.Config                 stage→provider resolution + env overrides
Tunex.Issues                 compute row issue-ids; persist resolved/gave-up sets; dedup; blacklist
Pipeline:
  Tunex.Pipeline.Translate   Mimo: Python→Elixir instruction + tests + reference (ONLY Python stage); cached
  Tunex.Pipeline.RoundTrip   run reference vs translated tests; pass → Solve; fail → re-translate/blacklist
  Tunex.Pipeline.Solve       local Qwen: Elixir instruction + tests → solution (Python-blind); retry
  Tunex.Pipeline.Refine      review→improve→validate loop (from ConvertLoop.refine/do_refine)
Evolve:
  Tunex.Evolve.Author        Mimo loop (≤3): sees full rule set; 4-way (extend/create/bugfix/NO_RULE);
                             write rule+tests, run mix test, feed back; fail → dump to escalated/
  Tunex.Evolve.Gate          fresh `mix test`; require diff+green; else discard
  Tunex.Evolve.Git           commit + push evolution→canonical via PAT; recompile workspace
```
**Reused:** `LLM` (multi-provider), `Parser`, `Validator` (capture Credence before/after), `Workspace`
(drop pool; path dep), `Dataset`, `Progress`, `JSONL`, `Report`, `NamingFixup`.
**Dropped vs earlier draft:** `Evolve.Triage` (folded into Author round 1), `Evolve.Escalate` +
`Evolve.Revalidate` + `Evolve.Budget` (Claude/targeted-revalidation/Anthropic-pool all cut).

## Flow per row
1. `Progress` → next unprocessed index; `RowLog.open`. (Blacklisted rows skipped.)
2. **Translate** (Mimo, cached): instruction + tests + reference solution.
3. **RoundTrip**: reference must pass translated tests; else re-translate once → else **blacklist** + skip.
4. **Solve** (Qwen, Python-blind, canonical names): solution; retry on validation failure.
5. **Refine/validate**: `Validator.run` (credence fix→compile→format→credo→credence→test) + refine.
   Capture per-attempt Credence before/after into RowLog. Compute the row's **issue-ids** on failure.
6. **Evolve** (if the row has ≥1 issue in neither `resolved` nor `gave-up`): **Author** (Mimo ≤3) on the
   novel issues → 4-way decision (extend/create/bugfix/NO_RULE) → write rule+tests, `mix test` feedback.
   Green+diff → **Gate** (`mix test`) → **Git** commit+push `evolution` via PAT + `deps.compile credence
   --force`; mark issue(s) `resolved`. Still red after 3 → dump to `escalated/`, mark `gave-up`.
7. Write SFT success/error JSONL. Loop. When dataset exhausted, **start a new full pass** (fresh
   re-solve). **If the just-finished pass committed zero rule changes → halt (converged).**

## Credence dependency strategy
`Workspace` deps → local **path dep** `{:credence, path: "/home/car/projects/credence"}`. Clone on
`evolution`; push `evolution`→canonical via PAT (`main` protected). Loop compiles against LOCAL
checkout (push = backup/share). Single stream ⇒ no lock.

## Files
- **Create:** `lib/tunex/{application,orchestrator,row_log,cache,config,issues}.ex`,
  `lib/tunex/pipeline/{translate,round_trip,solve,refine}.ex`,
  `lib/tunex/evolve/{author,gate,git}.ex`, `docs/plan.md`, `escalated/` (dead-letter dir).
  Add `:mimo` provider + `stages` map to `config/config.exs`; keys + PAT in `secrets.exs`; `mod:` in
  `mix.exs`.
- **Modify:** `workspace.ex` (path dep, drop pool, recompile helper), `validator.ex` (Credence
  before/after capture + issue-id extraction incl. compile-error regex bank), `llm.ex` (per-stage
  provider). Move prompts into `Pipeline.*`.
- **Reuse:** `parser.ex`, `dataset.ex`, `progress.ex`, `jsonl.ex`, `report.ex`, `naming` helpers.
- **Snapshot to `v1/`:** whole current project.

## Verification
1. `cd v1 && mix run scripts/convert.exs educational_instruct --start 0` → old path runs.
2. Unit: Solve prompt contains NO Python; canonical module/function present in tests+solution.
3. RoundTrip: feed a deliberately mistranslated test → reference fails → row **blacklisted**, skipped on
   re-pass.
4. Cache: row twice → 2nd is a hit; edit translate prompt → miss.
5. GPU-less: `TUNEX_SOLVE_PROVIDER=mimo mix run --no-halt` runs end-to-end, no local model.
6. Issue dedup: same issue id across two rows → 2nd row does not re-enter Author. `test:generic` →
   gave-up once → later logic-bug rows skip authoring (but Refine still runs).
7. Issue-ids: hallucinated `Map.sort` → `compile:undef:Map.sort/1`; obscure error → `compile:other`;
   rule that breaks passing tests → `rule_regression:<rule>`.
8. Author **extend**: with the rule set in context, a new hallucinated fn is **added to the existing
   conversion-list rule**, not made into a new rule.
9. Author **create/bugfix**: novel idiom → new rule + negative tests; over-firing rule → bugfixed; Gate
   green → Git commits on `evolution` + pushes via PAT.
10. Author **fail**: force red 3 rounds → log dumped to `escalated/`, working tree clean, issue gave-up.
11. Git safety: bot push to `main` is rejected (branch protection); push to `evolution` succeeds.
12. Mimo exhaustion → program halts cleanly. Runaway ceiling trips on absurd spend.
13. Convergence: a full pass with zero Credence commits → program halts ("converged"); a pass with ≥1
    commit wraps into another pass. Solve is re-run fresh (not cache-hit) on each pass.
14. Boot recovery: kill mid-author (dirty tree) → restart → tree reset clean, credence recompiled.
15. `cd /home/car/projects/credence && mix test` green before/after.

## Unresolved (values/setup, not design)
- **Compile-error extractor bank:** initial set of regex shapes to ship (undef function, unknown var,
  bad arity, syntax). Grow as `compile:other` cases accumulate.
- **Mimo:** confirm API key/endpoint in `secrets.exs`; pick runaway-ceiling number.
- **PAT:** confirm fine-grained token is in `secrets.exs` and scoped to `evolution` push; `main`
  protection enabled on `Cinderella-Man/credence`.
- **`escalated/` review:** manual-only for now; no triage workflow.

### Resolved this session
- Round-trip kept but repurposed as a **blacklist filter** for cheap re-passes (not dataset quality).
- **Cut** targeted Revalidation + per-row signatures → full re-passes + two global issue-id sets.
- **Dropped Claude** entirely (escalation, Anthropic pool, budget module, max-turns) → `escalated/`
  dead-letter dir on Author failure.
- **Mimo uncapped** (runaway ceiling only); exhaustion halts the program.
- **Git simplified** to single repo + PAT + protected `main` (no fork / 2nd account / dual SSH).
- **Triage folded** into Author round 1; Author **sees the full rule set** and does 4-way
  extend/create/bugfix/NO_RULE.
- Dedup unit = **individual issue id**; `test:generic` collapse suppresses logic-bug noise.
- Re-pass = **infinite loop, fresh re-solve, never-cache Solve, statistical regression catch**; persist
  `resolved`/`gave-up` across passes; **halt when a full pass commits zero rule changes** (converged).
