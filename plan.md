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

Restructure main dir into a proper OTP app running a self-evolving loop. Per SFT row: translate
(remote) → solve (local, Python-blind) → refine/validate → **learn** (Mimo authors/extends/fixes a
Credence rule). The app walks the **~118k-row dataset once, forward**, until the user stops it (118k ×
minutes-per-solve ≈ years, so it never finishes a pass — it runs for days, then the user stops it,
inspects/PRs the new rules, and manually reinitializes for the next run). Old code preserved runnable
under `v1/`.

### Confirmed decisions
1. **Translate** = remote **Xiaomi Mimo**; produces Elixir instruction + Elixir tests **+ an Elixir
   reference solution (validation-only, never emitted/trained)**. Cached **forever**, key =
   `sha256(system_prompt + rendered_user_prompt + model)` (prompt change auto-invalidates).
2. **Round-trip check** = run the Elixir reference solution against the translated Elixir tests; require
   PASS before running Solve. **Gate only on `:compile` + `:test`** (ignore `:credo`/`:credence` — the
   throwaway reference's *style* is irrelevant to test faithfulness; gating on lint would falsely
   blacklist usable rows). Fail → re-translate once → else **permanently blacklist the row** ("broken by
   definition"). **Verdict is cached with the translation** (deterministic → run once, not per pass).
   *Purpose:* keep future passes cheap by never re-attempting rows that can't work — **not** data quality.
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
      **(2) Create** a new rule, **(3) Bugfix** an existing rule (over-firing / wrong-fix — Author
      *judges this by reading the RowLog*, which shows code before/after each `Credence.fix` + which
      rules fired (`applied_rules`); there is **no** `rule_regression` issue-id), **(4) `NO_RULE`**
      (logic bug, nothing a rule can do). Mimo writes rule + **a mandatory regression test** (see #7);
      our Elixir runs `mix test`, feeds failures back, ≤3 rounds.
   b. **On Author failure** (still red after 3 rounds): dump the row's full log + Mimo's last attempt
      into an **`escalated/`** dead-letter dir for later human review; mark the issue(s) `gave-up`;
      move on. **No Claude, no automation beyond the disk write.**
6. **Trust boundary / commit** = Author **edits only** (no git creds in its env). After it exits, our
   Elixir **Gate** enforces a **hard 3-part contract**: (a) full Credence `mix test` **green**, (b) the
   diff touches **`test/**`** (a regression test was added/modified — the enforceable proxy for "covers
   the change"), (c) the diff touches **`lib/**`** (a rule actually changed). All three → **Git** commits
   & pushes. Any miss → `git checkout -- .` discard. **Apply is full-file overwrite** (Author emits
   validated `{path, content}` blocks), never patches.
7. **Rule quality is guaranteed at authoring time, not policed afterward.** Every add/extend/bugfix
   MUST ship a **new regression test** (new rule: fires on bad code AND must-NOT-fire on good code;
   bugfix: locks in the case it was wrongly firing on; extend: covers the new entry) — **absolutely
   required**, enforced by the Gate (#6). The **main SFT flow is decoupled**: it never detects buggy
   rules. Consequence (accepted): an over-firing rule whose damage shows up only as a wrong-answer test
   failure looks like `test:generic` and is **not** self-corrected through the main flow; we rely on the
   mandatory regression test + full suite to keep rules correct when committed. Rules that fail to
   *compile* still self-revert via Credence's `:reverted` gate (harmless).
8. **Rule edits** = Author may **extend, create, OR bugfix** existing rules (see 5a). Enabled by giving
   Author the full current rule set in context.
9. **Single forward pass — NO infinite loop, NO re-passes, NO convergence/wipe.** The program walks the
   ~118k-row dataset once, in order, until killed. (One Qwen solve takes minutes; 118k ≈ years, so it
   will never actually finish — it's run for a few days at a time, then stopped.) There is no end-of-pass
   wipe and no ephemeral/persistent split: **everything just persists for the run** — translation cache,
   blacklist, `resolved`/`gave-up` dedup sets, `escalated/`, the **append-only SFT output** (one record
   per row, like v1), and the committed Credence rules.
   **Within-run dedup is automatic:** once a rule is committed + Credence recompiled, that issue stops
   appearing for later rows in the same run; `resolved`/`gave-up` dedup the rest across rows (each
   gave-up issue is attempted once per run).
   **Re-initialization is MANUAL:** to get more/different failures (e.g. swap to a smaller LLM), the user
   reinitializes the project from scratch and reruns. By then the committed rules are already pushed on
   `evolution`, and the user manually opens a PR to merge them into `main`.
   **No saved-code re-runs, no `Evolve.Revalidate`, no over-fire detection** — rule quality is
   guaranteed at authoring time (#7). The program **exits like any normal script** when killed or (in
   theory) when the dataset is exhausted.
10. **Issues (replaces per-row signatures)** = dedup at the level of the **individual issue id**, not
    the row. Two persistent global sets: **`resolved`** and **`gave-up`**. A row triggers Author iff it
    has ≥1 issue in *neither* set; Author handles only those novel issues; each is marked independently.
    **Issue-id scheme:**
    - `credence:<rule_name>` — a rule still fires after fix.
    - `credo:<check_name>`.
    - `compile:<kind>:<token>` — via a small **regex-extractor bank** over common Elixir compile-error
      shapes (e.g. `compile:undef:Map.sort/1`); unmatched → **`compile:other`** catch-all.
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
    row. MUST capture code **before vs after each `Credence.fix`** + rules fired (`applied_rules`) +
    initial vs final code. This log **is the literal input** Author reads to discover/extend/fix rules.
    Logs persist for the run (single pass — never wiped); copies are written into **`escalated/`** when
    Author gives up (your manual-review queue). On manual re-init the user clears them.
17. **Author loop bounds** = ≤3 rounds; clean working tree between rows.
18. **Storage layout = keep-vs-wipe split** (so re-init removes generated solutions but NOT tasks or
    blacklist):
    - **`var/cache/`** — survives re-init. `translations.jsonl` = Mimo's instruction+tests+reference
      ("tasks"), **with the round-trip verdict baked in as a field** (`roundtrip: :pass | :fail`). So
      **blacklist is not a separate file** — a row is blacklisted iff its cached translation has
      `roundtrip: :fail`. (Saves re-paying Mimo when only the Solve LLM is swapped.)
    - **`var/run/`** — everything Qwen-generated/regenerable: `resolved`/`gave_up`, `Progress`, RowLogs,
      SFT output, `escalated/`, the validation `workspace/`.
    - **Re-init = `rm -rf var/run/`** (one command; cache untouched), exposed as `mix tunex.reset`.
    - **`.gitignore`** (tunex repo): `/var/`, `/config/secrets.exs`, `/_build/`, `/deps/`, `*.parquet`,
      + generated artifacts under `v1/`. The credence **clone** (`/home/car/projects/credence`) is a
      separate repo, unaffected.

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
Tunex.Cache                  translate cache (var/cache/translations.jsonl + roundtrip verdict=blacklist)
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
  Tunex.Evolve.Gate          fresh `mix test` green + regression test present + diff; else discard
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
6. **Evolve** (a *decoupled* learning track — does NOT change this row's emitted result): if the row has
   ≥1 issue in neither `resolved` nor `gave-up`, **Author** (Mimo ≤3) on the novel issues → 4-way
   decision (extend/create/bugfix/NO_RULE), writes rule + **mandatory regression test**, `mix test`
   feedback. **Gate** 3-part contract (full green + regression test present + non-empty diff) → **Git**
   commit+push `evolution` via PAT + `deps.compile credence --force`; mark issue(s) `resolved`. Any miss
   after 3 rounds → dump to `escalated/`, mark `gave-up`.
7. Append the SFT success/error record **based on step 5's validation outcome** (independent of step 6).
   Advance `Progress`; move to the next row. The program runs forward until killed (no re-pass, no wipe).

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
3. RoundTrip: feed a deliberately mistranslated test → reference fails → row **blacklisted** + skipped;
   a reference that only trips credo/credence (not compile/test) is **not** blacklisted.
4. Cache: row twice → 2nd is a hit; edit translate prompt → miss.
5. GPU-less: `TUNEX_SOLVE_PROVIDER=mimo mix run --no-halt` runs end-to-end, no local model.
6. Issue dedup: same issue id across two rows → 2nd row does not re-enter Author. `test:generic` →
   gave-up once → later logic-bug rows skip authoring (but Refine still runs).
7. Issue-ids: hallucinated `Map.sort` → `compile:undef:Map.sort/1`; obscure error → `compile:other`.
   (No `rule_regression` id exists.)
8. Author **extend**: with the rule set in context, a new hallucinated fn is **added to the existing
   conversion-list rule**, not made into a new rule.
9. Author **create/bugfix**: novel idiom → new rule + regression test; over-firing rule → bugfixed +
   regression test locking the case. **Gate rejects** a change with no new regression test even if
   `mix test` is green. Pass → Git commits on `evolution` + pushes via PAT.
10. Author **fail**: force red 3 rounds → log dumped to `escalated/`, working tree clean, issue gave-up.
11. Git safety: bot push to `main` is rejected (branch protection); push to `evolution` succeeds.
12. Mimo exhaustion → program halts cleanly. Runaway ceiling trips on absurd spend.
13. Single pass + resume: kill mid-run → restart → `Progress` skips done rows, blacklist/resolved/
    gave-up reload, run continues forward. Dataset exhaustion (or kill) → clean exit. A rule committed
    mid-run + recompiled → its issue stops recurring for later rows in the same run.
14. Boot recovery: kill mid-author (dirty tree) → restart → tree reset clean, credence recompiled.
15. `cd /home/car/projects/credence && mix test` green before/after.

## Unresolved (values/setup, not design)
- **Compile-error extractor bank:** initial regex shapes (undef function, unknown var, bad arity,
  syntax). Grow as `compile:other` cases accumulate.
- **Mimo values:** `max_tokens` floor + per-stage limits picked (16k/32k) — confirm against Mimo's real
  cap; runaway-ceiling **$ number + per-token price**; confirm whether responses include `usage` (else
  request-count fallback); confirm Xiaomi's out-of-credit status code (refine classifier after first hit).
- **Secrets:** Mimo `Authorization` header + endpoint in `secrets.exs`; fine-grained **PAT** scoped to
  push `evolution`; `main` branch-protected on `Cinderella-Man/credence`; clone checked out on
  `evolution`.
- **`escalated/` review:** manual-only; no triage workflow.

### Resolved this session
- Round-trip kept but repurposed as a **blacklist filter** to skip broken-by-definition rows (not data
  quality); gates on compile/test only; verdict cached with translation.
- **Cut** targeted Revalidation + per-row signatures → run-scoped issue-id sets (single forward pass).
- **Dropped Claude** entirely (escalation, Anthropic pool, budget module, max-turns) → `escalated/`
  dead-letter dir on Author failure.
- **Mimo uncapped** (runaway ceiling only); exhaustion halts the program.
- **Git simplified** to single repo + PAT + protected `main` (no fork / 2nd account / dual SSH).
- **Triage folded** into Author round 1; Author **sees the full rule set** and does 4-way
  extend/create/bugfix/NO_RULE.
- Dedup unit = **individual issue id**; `test:generic` collapse suppresses logic-bug noise.
- **Rule quality enforced at authoring time** (mandatory regression test + full suite green, Gate 3-part
  contract), **not** policed by the main flow → dropped `rule_regression` issue-id; Evolve decoupled
  from row emission; `bugfix` triggered by Author reading the RowLog.
- **No ephemeral-pass model** (superseded): single pass means nothing is wiped at runtime. All run state
  (cache, blacklist, dedup sets, escalated, SFT output) just persists; cleared only on manual re-init.
- **Single forward pass, no infinite loop** (118k × minutes ≈ years — never loops). Runs until killed;
  exits like a normal script. No convergence, no wipe, no `PassState`. Everything persists for the run;
  `Progress` gives crash-resume. Re-init is **manual** (swap LLM → reinitialize project; rules already
  pushed on `evolution`, user PRs to `main`).

## Implementation tasks

Decomposed from the design above into ordered, dependency-aware milestones. Build strategy: vertical
slice first (M0–M3 = runnable convert loop, no evolve), then layer Issues (M4), Evolve (M5), and the
supervised 24/7 Orchestrator (M6). Each milestone is independently testable.

**Grounding facts (from code exploration):**
- Credence API: `Credence.analyze/2` → `%{valid, issues}`; `Credence.fix/2` → `%{code, issues,
  applied_rules}`. `Issue` = `%{rule: atom, message, meta: %{line}}`. Rules auto-discovered by
  `@behaviour` scan (`Credence.RuleHelpers.discover_rules/1`) — add file + recompile = registered.
- Phases: **Syntax** (`analyze/1`,`fix/1`), **Semantic** (`match?/1`,`to_issue/1`,`fix/2`), **Pattern**
  (`check/2`,`fix_patches/2`). Extend-prototype = `Credence.Pattern.HallucinatedGuard`
  (`@hallucinated_guards` map). Tests: one-file-per-rule (`_check_test`/`_fix_test`), use
  `Sourceror.parse_string!/1` + `RuleHelpers.apply_rule_fix/3`.
- `Tunex.LLM.call/3` already takes `active_provider` in opts; `:xiaomi` provider == Mimo
  (`mimo-v2.5-pro`) already configured → per-stage providers ≈ Config work.
- Workspace scripts `run_credence.exs`/`run_credence_fix.exs` are Tunex's own (the "FIXED" string is
  ours) → enhance to emit `applied_rules`. Workspace currently = Agent **pool** + **git** credence dep
  → becomes **single** workspace + **path** dep. `Validator.run/3` → `{failures, final_mod, final_test}`.

### M0 — Snapshot to `v1/` + new app skeleton
- **T0.1** Move entire current project into `v1/` (`mix.exs, mix.lock, lib/, scripts/, config/,
  .formatter.exs, test/, *.jsonl, *.parquet, tunex_workspace_0/, README.md, output_v1/`). Leave at root
  only `.git/` + `plan.md`. Verify `cd v1 && mix run scripts/convert.exs educational_instruct --start 0`.
- **T0.2** `plan.md` → `docs/plan.md`.
- **T0.3** New root `mix.exs`: `app: :tunex`, `mod: {Tunex.Application, []}`, deps `{:req,"~> 0.5"},
  {:explorer,"~> 0.10"},{:jason,"~> 1.4"}`. New `config/config.exs`, `.formatter.exs`. (Main app does
  NOT dep on credence — it shells into the workspace.) **`.gitignore`**: `/var/`, `/config/secrets.exs`,
  `/_build/`, `/deps/`, `*.parquet`, + generated artifacts under `v1/`.
- **T0.4** Copy reused modules into new `lib/tunex/`: `parser, dataset, progress, jsonl, report, llm,
  workspace, validator` (last three modified later). Drop `cli`/`trajectory_logger` (→ RowLog).
- **T0.5** `Mix.Tasks.Tunex.Reset` (`mix tunex.reset`) = `rm -rf var/run/` + recreate empty dirs;
  **leaves `var/cache/` (tasks + blacklist) intact**. The "remove generated solutions" button.

### M1 — Config + per-stage providers  *(dep: M0)*
- **T1.1** `config.exs`: keep `providers`; treat `:xiaomi` as mimo. **Add a floor `max_tokens` to the
  `:xiaomi` config** (currently none → Mimo truncates). Add `stages`
  `%{translate: :xiaomi, solve: :local_qwen_thinking, author: :xiaomi}`; add `credence_clone` +
  paths under the **`var/cache/`** (survives) vs **`var/run/`** (wiped) split (#18).
- **T1.2** `Tunex.Config`: `provider_for(stage)` = `TUNEX_<STAGE>_PROVIDER` env → `stages[stage]`; path
  helpers.
- **T1.3** `config/secrets.exs` (gitignored): `secret_providers: %{xiaomi: %{headers: %{"Authorization"
  => "Bearer …"}}}` + `git_pat`. *(setup — user supplies.)*
- **T1.4** **Fix `LLM.call`** (3 changes): (1) merge per-call `opts` overrides (`max_tokens`,
  `temperature`) into `body_params` — currently silently dropped (llm.ex:14–28 reads only active_provider
  /url/headers/timeout), so v1's `opts[:max_tokens]` was a no-op; (2) return **classified errors**
  `{:error, {:http, status, body}}` / `{:error, {:network, reason}}` instead of the flattened
  `"HTTP <status>"` (preserve status+body for T6.4); (3) read `usage` from the response body (for
  Budget). Then `LLM.for_stage(stage, user, system, opts)` injects `active_provider` + the stage's
  `max_tokens` (Translate 16k / Author 32k / Solve default). Treat `finish_reason == "length"` /
  `{:empty, "token limit reached"}` as a **hard error** for Translate/Author (never cache/accept
  truncated output).

### M2 — Workspace: single + path dep + richer scripts  *(dep: M0)*
- **T2.1** `workspace.ex`: delete pool fns; keep single `setup/1`. Deps block →
  `{:credence, path: "/home/car/projects/credence", only: [:dev,:test], runtime: false}`. Replace
  `update_credence/1` with `recompile_credence/1` (`mix deps.compile credence --force`, dev+test).
- **T2.2** Enhance `@credence_fix_script` to print parseable trace: `FIXED/NO_CHANGES` + `applied_rules`
  (`{rule, count|:reverted}`) + remaining issues as `RULE\t<atom>\tLINE\t<n>`. Same for check script.
- **T2.3** Single-path workspace bootstrap; `deps.get` + `deps.compile` (dev+test) against path dep.

### M3 — Pipeline: translate → round-trip → solve → refine  *(dep: M1,M2)*
- **T3.1** `Tunex.Cache` (`var/cache/translations.jsonl`): `key=sha256(system+rendered+model)`,
  `get/put`. Each record carries the **round-trip verdict** (`roundtrip: :pass | :fail`) — this **is**
  the blacklist (no separate file). Survives `mix tunex.reset`.
- **T3.2** `Pipeline.Translate` (Mimo, `max_tokens` 16k): instruction + tests + **reference**; canonical
  names injected; markers `---INSTRUCTION---/---TEST---/---REFERENCE---/---END---` →
  `Parser.parse_translate/1`. **Never cache a truncated/`:empty` response** (T1.4); cache only complete
  parses.
- **T3.3** `Pipeline.RoundTrip`: reference vs translated tests via `Validator.run/3`, **decide on
  `:compile`/`:test` failures only** (ignore `:credo`/`:credence`); fail → re-translate once (bypass
  cache) → else `Issues.blacklist/1` + skip. **Cache pass/fail verdict with the translation** (T3.1) →
  runs once per translation, not per pass.
- **T3.4** `Pipeline.Solve` (Qwen, **Python-blind**): reuse only the **loop skeleton** of
  `ConvertLoop.attempt` (`v1` convert.exs:177) + `NamingFixup.fix_is_prefix`, `Validator.run/3`,
  `Parser.parse_module_test`. **Rewrite ALL prompts Python-free** — the v1 system/initial/retry prompts
  are converter prompts saturated with Python (convert.exs:13–45, 677–684, 261–281) and MUST NOT be
  reused. New system prompt = "write idiomatic Elixir satisfying this Elixir spec + tests" (no mention
  of Python/translation); new user prompt = Elixir instruction + Elixir tests + canonical fn name ONLY;
  new retry prompt = previous **Elixir** attempt + `Validator` errors + canonical-name reminder (no
  `## Original Python` block). **Guard:** unit test asserts assembled prompts (initial+retry) contain no
  ```` ```python ```` and not the row's Python source.
- **T3.5** `Pipeline.Refine`: port `ConvertLoop.refine`/`do_refine` (convert.exs:352–615); swap
  `TrajectoryLogger` → `RowLog`.

### M4 — Issues: issue-ids + dedup/blacklist  *(dep: M2)*
- **T4.1** `Tunex.Issues`: compute issue-id list — `credence:<rule>`, `credo:<check>`,
  `compile:<kind>:<token>`|`compile:other`, `test:generic`. **No `rule_regression`** — rule quality is
  guaranteed at authoring time (#7), not detected by the main flow.
- **T4.2** Compile-error regex extractor bank (undef fn, unknown var, bad arity, syntax) + fallback.
- **T4.3** Run-scoped sets in `var/run/` (loaded at boot, never wiped at runtime, gone on
  `mix tunex.reset`): `resolved.txt`/`gave_up.txt`. **`blacklisted?/1` reads the cache's `roundtrip`
  field** (T3.1) — no separate blacklist file. API: `novel_issues/1`, `mark_resolved/1`,
  `mark_gave_up/1`, `blacklisted?/1`. (Once a rule is committed + recompiled its issue stops recurring;
  `resolved`/`gave-up` dedup the rest across rows.)

### M5 — Evolve: author → gate → git  *(dep: M2,M4)*
- **T5.1** `Evolve.Author` (Mimo ≤3, `max_tokens` 32k — multi-file output, in clone): context = full
  rule set (`lib/{pattern,syntax,semantic}/*.ex`, cached prefix) + row log + novel issues +
  `Issue`/`RuleHelpers` + behaviour cheatsheet +
  example rule+test pairs (incl. `HallucinatedGuard`). Round-1 4-way (extend/create/bugfix/NO_RULE;
  bugfix judged by reading RowLog `applied_rules`, not an issue-id). **Apply mechanism = full-file
  overwrite, no patches:** Author emits `{path, full_content}` blocks (markers `---FILE <path>---` …
  `---END FILE---`) for rule file(s) + test file(s); Author has the current file in context for
  extend/bugfix. Elixir **validates each path** (under `lib/{pattern,syntax,semantic}/` or `test/`,
  module name matches `Credence.<Phase>.<Name>` ⇄ path, no unrelated-file clobber) then overwrites
  wholesale → `mix test` (clone) → feed back ≤3. Edits only (no git creds).
- **T5.2** `Evolve.Gate`: hard 3-part contract — fresh `mix test` **green** + `git diff --name-only`
  touches **`lib/**`** (the rule) **AND `test/**`** (the regression test) + diff non-empty; any miss →
  `git checkout -- .`.
- **T5.3** `Evolve.Git`: commit `evolution` + push via PAT HTTPS; `recompile_credence`; mark resolved.
- **T5.4** `Evolve.Escalated`: on fail → write `var/run/escalated/<row>.md`; `mark_gave_up`;
  `git checkout -- .`.

### M6 — Orchestrator + RowLog + Application + Budget  *(dep: M3,M4,M5)*
- **T6.1** `Tunex.RowLog`: Markdown + JSONL per row; capture before/after **each** `Credence.fix` +
  `applied_rules` + initial/final code. Replaces `TrajectoryLogger`.
- **T6.2** `Validator` mod: also return credence-fix **trace** (before/after/applied_rules/remaining) —
  consumed by **RowLog + Author** (so Author can judge `bugfix`); **not** used for issue-id computation.
- **T6.3** `Tunex.Orchestrator` GenServer — **single forward pass**: boot reconciliation
  (`git reset --hard && clean -fd` evolution, push catch-up, recompile, load `resolved`/`gave-up`/
  blacklist, resume via `Progress.load_completed_indices`); per-row flow
  (translate→roundtrip→solve→refine→issue-ids→evolve→append SFT→`Progress.mark_done`); advance to next
  row until killed or dataset exhausted, then exit. **No re-passes, no convergence, no wipe, no
  PassState** — `Progress` (single-pass, as in v1) is sufficient for crash-resume.
- **T6.4** `Tunex.Budget` + **error classification** (depends on T1.4 returning `{:error, {:http,
  status, body}}`/`{:error, {:network, reason}}`): **fatal** Mimo errors (`401/402/403`, or `429`×N
  consecutive = out of credits / bad key) → **halt immediately** with a clear message; **transient**
  (`5xx`/network) → bounded retry+backoff → halt if it won't clear. Always **log raw body** (refine the
  status→class mapping after first real exhaustion — Xiaomi codes unverified). **Runaway $ ceiling:**
  accumulate `usage` tokens × configured price from each Mimo response → halt at ceiling; **if Xiaomi
  omits `usage`, fall back** to a request-count ceiling. Price + ceiling are config values.
- **T6.5** `Tunex.Application`: supervision tree; `mix run --no-halt`.

### M7 — Verification  *(dep: all)*
Port the "## Verification" list into ExUnit + manual checks (v1 still runs; Solve Python-free; RoundTrip
blacklist; cache hit/miss; GPU-less via `TUNEX_SOLVE_PROVIDER=xiaomi`; issue dedup + `test:generic`
collapse; issue-id shapes; Author extend/create/bugfix/fail; git `main`-protection; single-pass resume;
boot recovery; credence `mix test` green).

### Sequencing
Critical path **M0 → M1/M2 (parallel) → M3 → M6**; M4 alongside M3; M5 after M2+M4. Earliest runnable
slice = **M0+M1+M2+M3** (convert loop, no evolve).

### Setup prerequisites (user-supplied)
- `secrets.exs`: Mimo `Authorization` header + `git_pat`.
- Credence clone on `evolution`; `main` branch-protected; PAT scoped to push `evolution`.
- Mimo runaway-ceiling $ number.
