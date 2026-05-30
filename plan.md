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
depends on **Credence** (custom AST linter, local clone at `/home/car/projects/credence`, 87 rules,
138 test files, rules auto-discovered from `lib/{pattern,syntax,semantic}`).

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
2. **Round-trip check** = run the Elixir reference solution against the translated Elixir tests via a
   **fix-free runner** (`mix compile --warnings-as-errors` + `mix test` ONLY — **no Credence-fix, no
   credo, no credence-check**); require PASS before running Solve. Credence-fix is for Qwen's messy
   output, not Mimo's clean canonical-named reference — and since the verdict is **cached forever**,
   running the evolving (sometimes over-firing) rule set over the reference could permanently blacklist
   usable rows when a transient bad rule rewrites it. The fix-free runner makes the cached verdict a
   **pure function of `(reference, tests)`**, immune to the rule set. Fail → re-translate once → else
   **permanently blacklist the row** ("broken by definition"). **Verdict is cached with the translation**
   (deterministic → run once, not per pass). *Purpose:* keep future passes cheap by never re-attempting
   rows that can't work — **not** data quality.
3. **Canonical names** = module pinned to `Solution`; function = deterministic Elixir name from
   `entry_point` (`Parser.elixir_name`, e.g. is_palindrome→palindrome?). **Injected into the prompts**
   (translate + reference + solve) and **trusted** — the only programmatic enforcement is `NamingFixup`'s
   `is_ → ?` fix (convert.exs:99–165); module/function naming is NOT hard-enforced. A mismatch just fails
   validation (tests target the canonical name) → normal retry. No separate enforcement step.
4. **Solve** = **local Qwen**, Python-blind (prompt = ONLY Elixir instruction + Elixir tests).
   Env-swappable to a remote provider for GPU-less dev. Retry + refine loop reused from v1. Qwen's
   non-idiomatic output is the **rule-discovery feedstock**.
5. **Evolve = Mimo only** (Claude dropped entirely). Deterministic **issue-dedup gate** (Elixir) in
   front of **CredenceRuleGenerator**:
   a. **CredenceRuleGenerator = Mimo hand-rolled loop, ≤3 rounds.** Always receives the **full current rule set**
      (full source of all ~87 files in `lib/{pattern,syntax,semantic}`) + the row log + `RuleHelpers`/`Issue`
      API + the row's **novel issues**. **Combined decide+implement, no moduledoc/triage split** — the full
      bodies are both the extend-vs-create decision context AND the few-shot library for writing new rules.
      **Prompt structure for cache hits:** stable corpus + API + examples → **system prompt** (cacheable
      prefix; Mimo = **1M window**, cache ~**$0.2–0.4/M**); per-row content (row log + novel issues) → **last
      in the user message**. (Each accepted rule busts the prefix cache once → size the runaway ceiling for
      periodic full-price re-caches.) Round 1 is a **4-way decision** per issue:
      **(1) Extend** an existing rule (e.g. add `Map.sort → Enum.sort` to a conversion-list rule),
      **(2) Create** a new rule, **(3) Bugfix** an existing rule (over-firing / wrong-fix — CredenceRuleGenerator
      *judges this by reading the RowLog*, which shows code before/after each `Credence.fix` + which
      rules fired (`applied_rules` = `[{module, count | :reverted}]` — **full module names, not rule
      atoms**); there is **no** `rule_regression` issue-id), **(4) `NO_RULE`**
      (logic bug, nothing a rule can do). Mimo writes rule + **a mandatory regression test** (see #7);
      our Elixir runs `mix test`, feeds failures back, ≤3 rounds.
   b. **On CredenceRuleGenerator failure** (still red after 3 rounds): **move** the row's log into the
      **`escalated/`** dir for later human review; mark the issue(s) `gave-up`; move on. **No Claude.**
6. **Trust boundary / commit** = CredenceRuleGenerator **edits only** (no git creds in its env). After it exits, our
   Elixir **Gate** enforces a **hard 4-part contract**: (a) full Credence `mix test` **green**, (b) the
   diff touches **`test/**`** (a regression test was added/modified), (c) the diff touches **`lib/**`** (a
   rule actually changed), (d) **mutation check** — stash the `lib/` change, re-run the **changed test
   file(s)**; they MUST go **RED** (the test genuinely exercises the rule, not an `assert true` proxy);
   restore. All four → `commit → recompile → push` (see #15/#11). Any miss → `git checkout -- .` discard.
   **Apply is full-file overwrite** (CredenceRuleGenerator emits validated `{path, content}` blocks), never patches.
7. **Rule quality is guaranteed at authoring time, not policed afterward.** Every add/extend/bugfix
   MUST ship a **new regression test** (new rule: fires on bad code AND must-NOT-fire on good code;
   bugfix: locks in the case it was wrongly firing on; extend: covers the new entry) — **absolutely
   required**, enforced by the Gate (#6). The **main SFT flow is decoupled**: it never detects buggy
   rules. Consequence (accepted): an over-firing rule whose damage shows up only as a wrong-answer test
   failure looks like `test:generic` and is **not** self-corrected through the main flow; we rely on the
   mandatory regression test + full suite to keep rules correct when committed. Rules that fail to
   *compile* still self-revert via Credence's `:reverted` gate (harmless).
8. **Rule edits** = CredenceRuleGenerator may **extend, create, OR bugfix** existing rules (see 5a). Enabled by giving
   CredenceRuleGenerator the full current rule set in context.
9. **Single forward pass — NO infinite loop, NO re-passes, NO convergence/wipe.** The program walks the
   ~118k-row dataset once, in a **seeded-shuffle order** (deterministic permutation of `0..n-1` from a
   fixed seed persisted in `var/run/`, **NOT** parquet order — so the prefix actually executed in the
   limited wall-clock is a representative *sample* of all rows, not a contiguous topic-cluster, maximizing
   failure-mode/rule diversity; resume unaffected since the permutation is reproducible), until killed.
   (One Qwen solve takes minutes; 118k ≈ years, so it
   will never actually finish — it's run for a few days at a time, then stopped.) There is no end-of-pass
   wipe and no ephemeral/persistent split: **everything just persists for the run** — translation cache,
   blacklist, the `gave-up` dedup set, `escalated/`, the **append-only SFT output** (one record
   per row, like v1), and the committed Credence rules.
   **Within-run dedup:** once a rule is committed + Credence recompiled, that issue stops appearing for
   later rows (auto-dedup, no `resolved` set); the **`gave-up`** set dedups the unsolvable ones (each
   gave-up issue is attempted once per run).
   **Re-initialization is MANUAL:** to get more/different failures (e.g. swap to a smaller LLM), the user
   reinitializes the project from scratch and reruns. By then the committed rules are already pushed on
   `evolution`, and the user manually opens a PR to merge them into `main`.
   **No saved-code re-runs, no `Evolve.Revalidate`, no over-fire detection** — rule quality is
   guaranteed at authoring time (#7). The program **exits like any normal script** when killed or (in
   theory) when the dataset is exhausted.
10. **Issues (replaces per-row signatures)** = dedup at the level of the **individual issue id**, not
    the row. **One set: `gave-up`** (no `resolved` set — a committed rule + recompile makes its issue
    stop appearing, so resolved self-dedups). A row triggers CredenceRuleGenerator iff it has ≥1 issue
    **not** in `gave-up`; it handles only those issues; failures add their ids to `gave-up`.
    **Issue-id scheme:**
    - `credence:<rule_name>` — a rule still fires after fix.
    - `credo:<check_name>`.
    - `compile:<kind>:<token>` — via a small **regex-extractor bank** over common Elixir compile-error
      shapes (e.g. `compile:undef:Map.sort/1`); unmatched → **`compile:other`** catch-all.
    - `test:generic` — all other (logic-bug) test failures **collapse into one id**. CredenceRuleGenerator returns
      `NO_RULE` once → marked `gave-up` → **all future logic-bug rows are deduped out of authoring**
      (kills the biggest noise source). Refine still tries to fix the logic for the dataset byproduct;
      only *rule-authoring* is suppressed.
11. **Git topology (simplified)** = **single canonical repo** `Cinderella-Man/credence`, **cloned by the
    user** at `/home/car/projects/credence` with an **already-authenticated `origin`** (**SSH key** — the
    current clone's `origin` is `git@github.com:Cinderella-Man/credence.git` — or a credential helper)
    **and a commit identity configured**, **checked out on a hand-created `evolution` branch** (the clone
    currently has only `main` — the user must create + push `evolution` before first run). The bot just
    runs plain `git commit` + **`git push origin evolution`** — **the app never handles credentials**.
    **`main` is branch-protected** (the hard safety rail). No fork, no second account. Same clone is what
    the loop compiles against (path dep) and pushes from.
12. **Providers** = `stages` map (`translate→mimo`, `solve→local_qwen`, `author→mimo`) + per-stage
    `TUNEX_*_PROVIDER` env overrides; `providers` map (url/model), keys in env/`secrets.exs`. **No
    `claude_code` / `evolve_escalation` stage.**
13. **Budget (single concern)** = **Mimo is the only paid dependency** and runs **essentially uncapped**
    with a **runaway-safety ceiling** only (abort if daily spend is absurd, e.g. 50× expected — catches
    infinite-loop bugs, not rationing; size it for periodic prefix-cache busts, #5a). **Mimo token
    exhaustion → halt the whole program** (nothing works without Mimo) **via a graceful `shutdown(reason)`
    wrapper**: log raw body → flush/close RowLog → `File.sync`+close the SFT/error/gave-up handles →
    **`System.halt(1)`** (see #16/T6.4). Per-row appends use `:file.datasync` and `Progress.mark_done` is
    the **last** step per row, so even an abrupt kill leaves whole lines (worst case: one row re-processed).
    **No Anthropic pool, no `Evolve.Budget` module.**
14. **Runtime** = supervised **Orchestrator GenServer**, `mix run --no-halt`, single stream (no
    parallel workers, one GPU). After accepted rule: `mix deps.compile credence --force`.
15. **Boot reconciliation** = on start: **`git reset --hard HEAD && git clean -fd`** (reset to **HEAD**,
    NOT `origin/evolution` — preserve all local commits, incl. un-pushed rules from a non-fatal-push run
    (#11); discard only half-written working-tree WIP); log "evolution at <sha>, origin at <sha>, N ahead";
    **best-effort** `git push origin evolution` catch-up (non-fatal); force-recompile credence; resume
    from `Progress`.
16. **Logging = plain `Logger`, no special structured logger.** v1 already `Logger.debug/info`s
    everything (every LLM call in/out, code before/after each `Credence.fix`, all validator output).
    Keep the **default `:logger` console handler** (watch live) **and** add a **native `:logger` file
    handler** (OTP's `:logger_std_h` — **NOT** the legacy `:logger_file_backend`, which rests on the
    backend API Elixir 1.19 extracted out of core), **both at `:debug`**. Per row, swap the file handler's
    path via `:logger.update_handler_config(:row_file, :config, %{file: ~c"var/run/logs/<index>.log"})`;
    the row's raw log file **is the literal input** CredenceRuleGenerator reads (force a filesync — swap the
    file away or `:logger_std_h` sync — before reading). `applied_rules` lands in it for free:
    `run_credence_fix.exs` does `IO.puts(inspect(applied_rules))` (entries are `{module, count |
    :reverted}` tuples — full module names) and the Validator already `Logger`s the captured subprocess
    stdout (validator.ex:316). **No Markdown digest, no JSONL events, no JSON channel.**
    **Per-row lifecycle:** when the row finishes (CredenceRuleGenerator — the last step — is done),
    **delete the log** — UNLESS the rule generator **gave up** → **move** it into **`escalated/`** for
    manual review, OR the row **committed a rule** → **move** it into **`committed/<index>.log`** (rule
    provenance: every pushed rule keeps the log that motivated it, for PR review). Invariant: the *only*
    logs that survive on disk are the `escalated/` (manual queue) and `committed/` (rule provenance) ones.
17. **CredenceRuleGenerator loop bounds** = ≤3 rounds; clean working tree between rows.
18. **Storage layout = keep-vs-wipe split** (so re-init removes generated solutions but NOT tasks or
    blacklist):
    - **`var/cache/`** — survives re-init. `translations.jsonl` = Mimo's instruction+tests+reference
      ("tasks"), **with the round-trip verdict baked in as a field** (`roundtrip: :pass | :fail`). So
      **blacklist is not a separate file** — a row is blacklisted iff its cached translation has
      `roundtrip: :fail`. (Saves re-paying Mimo when only the Solve LLM is swapped.)
    - **`var/run/`** — everything Qwen-generated/regenerable: `gave_up`, `Progress`, the **shuffle seed**,
      SFT output, `escalated/` + `committed/` (the only surviving logs — failures and rule-provenance),
      the validation `workspace/`. (Per-row logs are deleted on completion, #16 — they don't accumulate;
      only `escalated/`/`committed/` do.)
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
Tunex.Orchestrator (GenServer) single seeded-shuffle pass: pick row → translate → solve → refine → evolve; graceful shutdown on Mimo halt
Tunex.RowLog                 swaps native :logger file-handler path per row; on done deletes / MOVES to escalated/ or committed/
Tunex.Cache                  translate cache (var/cache/translations.jsonl + roundtrip verdict=blacklist)
Tunex.Config                 stage→provider resolution + env overrides
Tunex.Issues                 compute row issue-ids; persist gave-up set; dedup; blacklist (via cache)
Pipeline:
  Tunex.Pipeline.Translate   Mimo: Python→Elixir instruction + tests + reference (ONLY Python stage); cached
  Tunex.Pipeline.RoundTrip   fix-free runner (compile+test only) reference vs translated tests; pass → Solve; fail → re-translate/blacklist
  Tunex.Pipeline.Solve       local Qwen: Elixir instruction + tests → solution (Python-blind); retry
  Tunex.Pipeline.Refine      review→improve→validate loop (from ConvertLoop.refine/do_refine)
Evolve:
  Tunex.Evolve.CredenceRuleGenerator  Mimo loop (≤3): sees full rule set; 4-way (extend/create/bugfix/
                             NO_RULE); writes rule + regression test, runs mix test, feeds back; fail →
                             gave-up + move row log to escalated/
  Tunex.Evolve.Gate          fresh `mix test` green + diff touches lib/+test/ + mutation check (changed test goes RED w/o rule); else discard
  Tunex.Evolve.Git           commit → recompile → push origin evolution (non-fatal push, clone pre-auth'd via SSH)
```
**Copy & adapt from v1:** `LLM` (multi-provider), `Parser`, `Validator` (capture Credence before/after), `Workspace`
(drop pool; path dep), `Dataset`, `Progress`, `JSONL`, `Report`, `NamingFixup`.
**Dropped vs earlier draft:** `Evolve.Triage` (folded into CredenceRuleGenerator round 1), `Evolve.Escalate` +
`Evolve.Revalidate` + `Evolve.Budget` (Claude/targeted-revalidation/Anthropic-pool all cut).

## Flow per row
1. `Progress` → next unprocessed index; `RowLog.open`. (Blacklisted rows skipped.)
2. **Translate** (Mimo, cached): instruction + tests + reference solution.
3. **RoundTrip** (fix-free runner — compile+test only, no Credence-fix): reference must pass translated
   tests; else re-translate once → else **blacklist** + skip. Verdict cached forever = pure fn of (ref, tests).
4. **Solve** (Qwen, Python-blind, canonical names): solution; retry on validation failure.
5. **Refine/validate**: `Validator.run` (credence fix→compile→format→credo→credence→test) + refine.
   All before/after + `applied_rules` are `Logger`ed → land in the row's log file. Compute the row's
   **issue-ids** (text-parse of `{stage, msg}` failures) on failure.
6. **Evolve** (a *decoupled* learning track — does NOT change this row's emitted result): if the row has
   ≥1 issue **not in `gave-up`**, **CredenceRuleGenerator** (Mimo ≤3) on those issues → 4-way decision
   (extend/create/bugfix/NO_RULE), writes rule + **mandatory regression test**, **full `mix test`
   feedback every round** (Mimo sees collateral breakage as it iterates). **Gate** 4-part contract (full
   green + diff touches lib/+test/ + **mutation check**: changed test goes RED when the rule is stashed) →
   **Git** `commit → recompile (deps.compile credence --force) → push origin evolution` (non-fatal push;
   issue auto-dedups). Any miss after 3 rounds → mark `gave-up`, **move the log to `escalated/`**.
7. Append the SFT success/error record (synced) **based on step 5's validation outcome** (independent of
   step 6). **Delete the row log** — UNLESS it was moved to `escalated/` (gave-up) or `committed/` (a rule
   was pushed) in step 6. Advance `Progress` (**LAST**, after the synced append); next row. Runs forward
   through the shuffled permutation until killed (no re-pass, no wipe).

## Credence dependency strategy
`Workspace` deps → local **path dep** `{:credence, path: "/home/car/projects/credence"}`. Clone on
`evolution`; `git push origin evolution` (clone pre-auth'd, `main` protected). Loop compiles against LOCAL
checkout (push = backup/share). Single stream ⇒ no lock.

## Files
- **Create:** `lib/tunex/{application,orchestrator,row_log,cache,config,issues}.ex`,
  `lib/tunex/pipeline/{translate,round_trip,solve,refine}.ex`,
  `lib/tunex/evolve/{credence_rule_generator,gate,git}.ex`, `docs/plan.md`,
  `var/run/escalated/` (manual-review queue) + `var/run/committed/` (rule-provenance logs, Q1).
  Add `:mimo` provider + `stages` map to `config/config.exs`; Mimo key in `secrets.exs` (git auth lives
  in the clone's remote, not the app); `mod:` in
  `mix.exs`.
- **Modify:** `workspace.ex` (path dep, drop pool, recompile helper), `validator.ex` (Credence
  before/after capture + issue-id extraction incl. compile-error regex bank), `llm.ex` (per-stage
  provider). Move prompts into `Pipeline.*`.
- **Copy & adapt:** `parser.ex`, `dataset.ex`, `progress.ex`, `jsonl.ex`, `report.ex`, `naming` helpers.
- **Snapshot to `v1/`:** whole current project.

## Verification
1. `cd v1 && mix run scripts/convert.exs educational_instruct --start 0` → old path runs.
2. Unit: Solve prompt contains NO Python; canonical module/function present in tests+solution.
3. RoundTrip: feed a deliberately mistranslated test → reference fails compile/test → row
   **blacklisted** + skipped; a stylistically-poor-but-passing reference is **not** blacklisted (fix-free
   runner never runs credo/credence-fix, so the verdict = pure fn of (reference, tests)).
4. Cache: row twice → 2nd is a hit; edit translate prompt → miss.
5. GPU-less: `TUNEX_SOLVE_PROVIDER=mimo mix run --no-halt` runs end-to-end, no local model.
6. Issue dedup: same issue id across two rows → 2nd row does not re-enter CredenceRuleGenerator. `test:generic` →
   gave-up once → later logic-bug rows skip authoring (but Refine still runs).
7. Issue-ids: hallucinated `Map.sort` → `compile:undef:Map.sort/1`; obscure error → `compile:other`.
   (No `rule_regression` id exists.)
8. CredenceRuleGenerator **extend**: with the rule set in context, a new hallucinated fn is **added to the existing
   conversion-list rule**, not made into a new rule.
9. CredenceRuleGenerator **create/bugfix**: novel idiom → new rule + regression test; over-firing rule → bugfixed +
   regression test locking the case. **Gate rejects** (a) a change with no new regression test, AND (b) a
   change whose new test **stays green when the rule is stashed** (mutation check — e.g. `assert true`).
   Pass → `commit → recompile → git push origin evolution` (non-fatal push).
10. CredenceRuleGenerator **fail**: force red 3 rounds → log dumped to `escalated/`, working tree clean, issue gave-up.
11. Git safety: bot push to `main` is rejected (branch protection); push to `evolution` succeeds.
12. Mimo exhaustion → **graceful `shutdown` halts cleanly** (handles flushed/synced, no torn lines).
    Runaway ceiling trips on absurd spend. Truncated Translate/Author output (`{:truncated, _}`) is never
    cached/committed; truncated Solve → retry.
13. Single pass + resume: kill mid-run → restart → `Progress` skips done rows, blacklist (cache) +
    `gave-up` reload, run continues forward. Dataset exhaustion (or kill) → clean exit. A rule committed
    mid-run + recompiled → its issue stops recurring for later rows in the same run.
14b. Log lifecycle: a pure convert success leaves **no** log; a gave-up row's log sits in `escalated/`; a
    rule-committing row's log sits in `committed/`.
14. Boot recovery: kill mid-author (dirty tree) **+ un-pushed commits** → restart → `reset --hard HEAD`
    discards WIP but **keeps the un-pushed commits**, best-effort push catch-up, credence recompiled.
15. `cd /home/car/projects/credence && mix test` green before/after.

## Unresolved (values/setup, not design)
- **Compile-error extractor bank:** initial regex shapes (undef function, unknown var, bad arity,
  syntax). Grow as `compile:other` cases accumulate.
- **Mimo values:** **verified** — context **1M tokens**, max output **131k** (32k/16k floors safe);
  pricing **$1/M in, $3/M out** (≤256K tier; 2×/6× for 256K–1M), **cache hit $0.2–0.4/M in**. Still TODO:
  runaway-ceiling **$ number** (size for prefix-cache busts, #5a); confirm responses include `usage` (else
  request-count fallback); confirm Xiaomi's out-of-credit status code (refine classifier after first hit).
- **Secrets / git setup (user-owned):** Mimo `Authorization` header + endpoint in `secrets.exs`. **User
  clones `Cinderella-Man/credence`** to `/home/car/projects/credence`, **creates + checks out the
  `evolution` branch** (clone currently has only `main`), with `origin` **pre-authenticated** (**SSH key**
  — current origin is `git@github.com:…` — or credential helper) and a **commit identity** set; `main`
  **branch-protected**. The app does plain `git commit`/`git push origin evolution`.
- **`escalated/` review:** manual-only; no triage workflow.

### Resolved this session
- Round-trip kept but repurposed as a **blacklist filter** to skip broken-by-definition rows (not data
  quality); gates on compile/test only; verdict cached with translation.
- **Cut** targeted Revalidation + per-row signatures → run-scoped issue-id sets (single forward pass).
- **Dropped Claude** entirely (escalation, Anthropic pool, budget module, max-turns) → `escalated/`
  dead-letter dir on CredenceRuleGenerator failure.
- **Mimo uncapped** (runaway ceiling only); exhaustion halts the program.
- **Git simplified** to single repo + **SSH-key auth** + protected `main` (no fork / 2nd account / dual SSH).
- **Triage folded** into CredenceRuleGenerator round 1; CredenceRuleGenerator **sees the full rule set** and does 4-way
  extend/create/bugfix/NO_RULE.
- Dedup unit = **individual issue id**; `test:generic` collapse suppresses logic-bug noise.
- **Rule quality enforced at authoring time** (mandatory regression test + full suite green, Gate **4-part
  contract** incl. **mutation check** that the new test goes red without the rule), **not** policed by the
  main flow → dropped `rule_regression` issue-id; Evolve decoupled from row emission; `bugfix` triggered by
  CredenceRuleGenerator reading the RowLog.
- **No ephemeral-pass model** (superseded): single pass means nothing is wiped at runtime. All run state
  (cache, blacklist, dedup sets, escalated, SFT output) just persists; cleared only on manual re-init.
- **Single forward pass, no infinite loop** (118k × minutes ≈ years — never loops). Runs until killed;
  exits like a normal script. No convergence, no wipe, no `PassState`. Everything persists for the run;
  `Progress` gives crash-resume. Re-init is **manual** (swap LLM → reinitialize project; rules already
  pushed on `evolution`, user PRs to `main`).

## Implementation tasks

Decomposed from the design above into ordered, dependency-aware milestones. Build strategy: vertical
slice first (M0–M3 = runnable convert loop, no evolve), then layer Issues (M4), Evolve (M5), and the
supervised Orchestrator (M6). Each milestone is independently testable.

**Principle: v1 is COPIED into v2 as raw material and freely rewritten — NOT imported or signature-
preserved.** Where a task says "copy/adapt," take the v1 code as a starting point and reshape it into the
most obvious/intuitive v2 form (clear names, purpose-built functions). Don't contort v2 to match a v1
signature. v1 stays runnable under `v1/` only as a reference/fallback.

**Grounding facts (from code exploration):**
- Credence API: `Credence.analyze/2` → `%{valid, issues}`; `Credence.fix/2` → `%{code, issues,
  applied_rules}`. `Issue` = `%{rule: atom, message, meta: %{line}}`. Rules auto-discovered by
  `@behaviour` scan (`Credence.RuleHelpers.discover_rules/1`) — add file + recompile = registered.
- Phases: **Syntax** (`analyze/1`,`fix/1`), **Semantic** (`match?/1`,`to_issue/1`,`fix/2`), **Pattern**
  (`check/2`,`fix_patches/2`). Extend-prototype = `Credence.Pattern.HallucinatedGuard`
  (`@hallucinated_guards` map). Tests: one-file-per-rule (`_check_test`/`_fix_test`), use
  `Sourceror.parse_string!/1` + `RuleHelpers.apply_rule_fix/3`.
- `Tunex.LLM.call/3` already takes `active_provider` in opts; the existing `:xiaomi` provider == Mimo
  (`mimo-v2.5-pro`) is already configured (→ rename to `:xiaomi_mimo_2_5_pro`, T1.1) → per-stage
  providers ≈ Config work.
- Workspace scripts `run_credence.exs`/`run_credence_fix.exs` are Tunex's own (the "FIXED" string is
  ours) → enhance to emit `applied_rules`. Workspace currently = Agent **pool** + **git** credence dep
  → becomes **single** workspace + **path** dep. `Validator.run/3` → `{failures, final_mod, final_test}`.

### M0 — Snapshot to `v1/` + new app skeleton
- **T0.1** Move entire current project into `v1/` (`mix.exs, mix.lock, lib/, scripts/, config/,
  .formatter.exs, test/, *.jsonl, *.parquet, tunex_workspace_0/, README.md, output_v1/`). Leave at root
  only `.git/` + `plan.md`. Verify `cd v1 && mix run scripts/convert.exs educational_instruct --start 0`.
- **T0.2** `plan.md` → `docs/plan.md`.
- **T0.3** New root `mix.exs`: `app: :tunex`, `mod: {Tunex.Application, []}`, deps `{:req,"~> 0.5"},
  {:explorer,"~> 0.10"},{:jason,"~> 1.4"}` (**no `:logger_file_backend`** — RowLog uses OTP's native
  `:logger`/`:logger_std_h`, no dep). New `config/config.exs` (keep `config :logger, level: :debug`;
  default console handler + add the row-file `:logger` handler in `Tunex.Application`), `.formatter.exs`.
  (Main app does NOT dep on credence — it shells into the workspace.) **`.gitignore`**: `/var/`,
  `/config/secrets.exs`, `/_build/`, `/deps/`, `*.parquet`, + generated artifacts under `v1/`.
- **T0.4** Copy reused modules into new `lib/tunex/`: `parser, dataset, progress, jsonl, report, llm,
  workspace, validator` (last three modified later). Drop `cli`/`trajectory_logger` (→ RowLog).
- **T0.5** `Mix.Tasks.Tunex.Reset` (`mix tunex.reset`) = `rm -rf var/run/` + recreate empty dirs;
  **leaves `var/cache/` (tasks + blacklist) intact**. The "remove generated solutions" button.

### M1 — Config + per-stage providers  *(dep: M0)*
- **T1.1** `config.exs`: **rename the Mimo provider key `:xiaomi` → `:xiaomi_mimo_2_5_pro`** (bare atom;
  `model: "mimo-v2.5-pro"` unchanged) and update `secrets.exs` to match. **Add a floor `max_tokens` to it**
  (currently none → Mimo truncates). Keep `max_retries: 5` + `max_refine_retries: 5` (Solve/Refine —
  unchanged from v1). Add `subset: "educational_instruct"` (single subset, one shuffled pass) + a
  persisted **shuffle seed**. Add `stages` `%{translate: :xiaomi_mimo_2_5_pro, solve: :local_qwen_thinking,
  author: :xiaomi_mimo_2_5_pro}`; add `credence_clone` + paths under the **`var/cache/`** (survives) vs
  **`var/run/`** (wiped) split (#18).
- **T1.2** `Tunex.Config`: `provider_for(stage)` = `TUNEX_<STAGE>_PROVIDER` env → `stages[stage]`; path
  helpers.
- **T1.3** `config/secrets.exs` (gitignored): `secret_providers: %{xiaomi_mimo_2_5_pro: %{headers:
  %{"Authorization" => "Bearer …"}}}`. *(setup — user supplies; no git creds here — git auth lives in the
  clone's remote, via SSH key.)*
- **T1.4** **Fix `LLM.call`** (4 changes): (1) merge per-call `opts` overrides (`max_tokens`,
  `temperature`) into `body_params` — currently silently dropped (llm.ex:14–28 reads only active_provider
  /url/headers/timeout), so v1's `opts[:max_tokens]` was a no-op; (2) return **classified errors**
  `{:error, {:http, status, body}}` / `{:error, {:network, reason}}` instead of the flattened
  `"HTTP <status>"` (preserve status+body for T6.4); (3) read `usage` from the response body (for Budget);
  (4) **surface truncation regardless of content** — reorder `handle_response` so `finish_reason ==
  "length"` returns **`{:truncated, content}` even when content is non-empty** (the current `content != ""
  -> {:ok, content}` branch wins first, so truncated-but-nonempty output is silently accepted as `:ok` —
  llm.ex:53–57). Then `LLM.for_stage(stage, user, system, opts)` injects `active_provider` + the stage's
  `max_tokens` (Translate 16k / CredenceRuleGenerator 32k / Solve default). **Translate/CredenceRuleGenerator:**
  `{:truncated, _}` = **hard error** (never cache/commit; re-translate once / fail the round; log the
  too-low floor). **Solve/Refine:** `{:truncated, _}` = normal failed attempt → retry (no halt).

### M2 — Workspace: single + path dep + richer scripts  *(dep: M0)*
- **T2.1** `workspace.ex`: delete pool fns; **single workspace at `var/run/workspace/`** (not the v1
  pool path), `clean_workspace` between rows (existing helper). Deps block →
  `{:credence, path: "/home/car/projects/credence", only: [:dev,:test], runtime: false}`. Replace
  `update_credence/1` with `recompile_credence/1` (`mix deps.compile credence --force`, dev+test). Note:
  during a row's steps 2–5 the clone sits at committed `evolution` HEAD (CredenceRuleGenerator edits it
  only in step 6), so validation always sees the **last-committed** ruleset — correct by construction.
- **T2.2** Enhance `@credence_fix_script`: in addition to `FIXED/NO_CHANGES`, `IO.puts(inspect(
  result.applied_rules))` and print remaining issues (`#{rule}: …`) — plain stdout, captured by the
  Validator into the row log (no JSON, no special format). `@credence_check`/check script: ensure each
  remaining issue prints its `rule` atom (for `credence:<rule>` issue-id text-parsing).
- **T2.3** Single-path workspace bootstrap; `deps.get` + `deps.compile` (dev+test) against path dep.

### M3 — Pipeline: translate → round-trip → solve → refine  *(dep: M1,M2)*
- **T3.1** `Tunex.Cache` (`var/cache/translations.jsonl`): `key=sha256(system+rendered+model)`,
  `get/put`. Each record carries the **round-trip verdict** (`roundtrip: :pass | :fail`) — this **is**
  the blacklist (no separate file). Survives `mix tunex.reset`.
- **T3.2** `Pipeline.Translate` (Mimo, `max_tokens` 16k): instruction + tests + **reference**; canonical
  names injected; markers `---INSTRUCTION---/---TEST---/---REFERENCE---/---END---` →
  `Parser.parse_translate/1`. **Never cache a truncated/`:empty` response** (T1.4); cache only complete
  parses.
- **T3.3** `Pipeline.RoundTrip`: reference vs translated tests via a **fix-free runner** (write
  reference+tests, `mix compile --warnings-as-errors` + `mix test` ONLY — **no Credence-fix/credo/
  credence-check**, so the verdict is a pure fn of `(reference, tests)`, immune to the evolving rule set,
  #2). Fail → re-translate once (bypass cache) → else `Issues.blacklist/1` + skip. **Cache pass/fail
  verdict with the translation** (T3.1) → runs once per translation, not per pass.
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
- **T4.2** Compile-error regex extractor bank — **empirically verified against Elixir 1.19.5** (run via
  `mix compile --warnings-as-errors`, so "undefined or private" warnings surface as `:compile` failures).
  Apply these ordered regexes to the `:compile` failure msg; first match wins:
  1. `undefined function (\w+[?!]?)/(\d+)` → `compile:undef_local:\1/\2`
  2. `undefined variable "([^"]+)"` → `compile:undef_var:\1`
  3. `([\w.]+\.\w+[?!]?)/(\d+) is undefined \(module` → `compile:undef_module:\1/\2` (unknown module)
  4. `([\w.]+\.\w+[?!]?)/(\d+) is undefined or private` → `compile:undef_remote:\1/\2`
     (covers **hallucinated remote fns** AND **wrong arity**, e.g. `String.isAlphanumeric?/1`, `String.length/2`)
  5. `the range step operator \(//\)` → `compile:syntax:floor_div` (Python `//`)
  6. `missing terminator: (\w+)` → `compile:syntax:missing_terminator` (unmatched `do`/`end`)
  7. `SyntaxError`/`TokenMissingError` otherwise → `compile:syntax:other`
  8. else → **`compile:other`** catch-all.
  (Note: Credence's `FixPythonModulo`/`FixDivRem` syntax rules usually rewrite `%`/`//` *before* compile,
  so those rarely reach this stage. Grow the bank from `compile:other` cases seen in logs.)
- **T4.3** Run-scoped `gave_up.txt` in `var/run/` (loaded at boot, gone on `mix tunex.reset`); **no
  `resolved` set** (committed rules auto-dedup). **`blacklisted?/1` reads the cache's `roundtrip` field**
  (T3.1) — no separate blacklist file. API: `novel_issues/1` (= issues not in `gave_up`),
  `mark_gave_up/1`, `blacklisted?/1`.

### M5 — Evolve: author → gate → git  *(dep: M2,M4)*
- **T5.1** `Evolve.CredenceRuleGenerator` (Mimo ≤3, `max_tokens` 32k — multi-file output, in clone):
  **combined decide+implement, full bodies, no moduledoc split.** **Prompt structure for cache hits:**
  **system prompt** = stable cacheable prefix (full source of all ~87 `lib/{pattern,syntax,semantic}/*.ex`
  + `Issue`/`RuleHelpers` API + behaviour cheatsheet + example rule+test pairs incl. `HallucinatedGuard`);
  **user message** = per-row (row log + novel issues), last. (Mimo 1M window; cache ~$0.2–0.4/M; each
  accepted rule busts the prefix once.) Round-1 4-way (extend/create/bugfix/NO_RULE; bugfix judged by
  reading RowLog `applied_rules` = `{module, count | :reverted}` tuples, not an issue-id). **Apply
  mechanism = full-file overwrite, no patches:** CredenceRuleGenerator emits `{path, full_content}` blocks
  (markers `---FILE <path>---` … `---END FILE---`) for rule file(s) + test file(s); has the current file in
  context for extend/bugfix. Elixir **validates each path** (under `lib/{pattern,syntax,semantic}/` or
  `test/`, module name matches `Credence.<Phase>.<Name>` ⇄ path, no unrelated-file clobber) then overwrites
  wholesale → **full `mix test` (clone) every round** (so Mimo sees collateral breakage as it iterates) →
  feed back ≤3. Edits only (no git creds).
- **T5.2** `Evolve.Gate`: hard **4-part** contract — (a) fresh full `mix test` **green** + (b/c)
  `git diff --name-only` touches **`lib/**`** (the rule) **AND `test/**`** (the regression test) +
  (d) **mutation check**: `git stash push -- lib/` (revert only the rule, keep the new test) → `mix test`
  the **changed test file(s)** → assert they go **RED** → `git stash pop`; if still green, the test
  doesn't exercise the rule (e.g. `assert true`) → reject. Any miss → `git checkout -- .`.
- **T5.3** `Evolve.Git`: **`commit → recompile → push`** (order matters — recompile is load-bearing for
  dedup and purely local; push is best-effort backup). `git -C clone add -A && commit -m
  "cred-gen: <decision> <rule> [row <idx>]"` → `recompile_credence` (committed rule auto-dedups — no
  `resolved` set) → `git push origin evolution` **wrapped non-fatal** (on failure: warn "local evolution N
  ahead of origin", continue; boot catch-up reconciles). Auth pre-configured in the clone (**SSH key**) —
  app never handles credentials. On success, **move the row log to `committed/<idx>.log`** (rule provenance).
- **T5.4** `Evolve.Escalated`: on fail → `Issues.mark_gave_up/1` + **move the row's log file** to
  `var/run/escalated/<index>.md`; `git checkout -- .`.

### M6 — Orchestrator + RowLog + Application + Budget  *(dep: M3,M4,M5)*
- **T6.1** `Tunex.RowLog` — thin manager of a **native `:logger` file handler** (`:logger_std_h`, NOT a
  structured logger, NOT `:logger_file_backend`): `open(index)` →
  `:logger.update_handler_config(:row_file, :config, %{file: ~c"var/run/logs/<index>.log"})` (default
  console handler + this file handler both at `:debug`); `path/0` returns it (CredenceRuleGenerator reads
  after a forced filesync); `close/0` **deletes** the file; `escalate(index)` **moves** it to
  `var/run/escalated/<index>.log`; **`commit(index)` moves it to `var/run/committed/<index>.log`** (rule
  provenance, #16/Q1). Handler added in `Tunex.Application` (no extra dep). Replaces `TrajectoryLogger`.
- **T6.2** `Validator` mod: also return the credence-fix **trace** (before / after / `applied_rules`).
  `applied_rules` + before/after → RowLog (and CredenceRuleGenerator's `bugfix` judgment); the
  `remaining` issues feed `credence:<rule>` issue-ids (T4.1).
- **T6.3** `Tunex.Orchestrator` GenServer — **single seeded-shuffle pass**: boot reconciliation
  (**`git reset --hard HEAD && clean -fd`** — preserve local commits, #15; best-effort push catch-up;
  recompile; load `gave-up`; load/derive the **shuffle permutation** from the persisted seed; resume via
  `Progress.load_completed_indices`); per-row flow over the permutation (translate→roundtrip→solve→refine
  →issue-ids→evolve→append SFT (synced)→**RowLog.commit/escalate/close**→`Progress.mark_done` (**LAST**));
  advance until killed or dataset exhausted, then exit. **Per-row `try/rescue`**: a row that throws → log
  it, **`git checkout -- .`** the clone (clear any half-written WIP), skip the row, continue — do NOT crash
  the loop. Reserve process-crash + supervisor restart + reconciliation for unexpected death (kill/OOM).
  **No re-passes, no convergence, no wipe, no PassState** — `Progress` suffices for crash-resume.
- **T6.4** `Tunex.Budget` + **error classification** (depends on T1.4 returning `{:error, {:http,
  status, body}}`/`{:error, {:network, reason}}`): **fatal** Mimo errors (`401/402/403`, or `429`×N
  consecutive = out of credits / bad key) → **halt immediately** with a clear message; **transient**
  (`5xx`/network) → bounded retry+backoff → halt if it won't clear. Always **log raw body** (refine the
  status→class mapping after first real exhaustion — Xiaomi codes unverified). **Runaway $ ceiling:**
  accumulate `usage` tokens × configured price from each Mimo response → halt at ceiling (size for
  prefix-cache busts, #5a/#13); **if Xiaomi omits `usage`, fall back** to a request-count ceiling. Price +
  ceiling are config values. **"Halt" = a graceful `Tunex.shutdown(reason)`** — log raw body → flush/close
  RowLog → `File.sync`+close SFT/error/gave-up handles → **`System.halt(1)`** (clean exit, NOT a raise, so
  the supervisor can't restart into a fatal-error storm; and no torn append-only lines).
- **T6.5** `Tunex.Application`: supervision tree (Orchestrator child, `:transient`/`:permanent` so an
  unexpected crash restarts → reconciliation, but `System.halt` ends cleanly); `mix run --no-halt`.

### M7 — Verification  *(dep: all)*
Port the "## Verification" list into ExUnit + manual checks (v1 still runs; Solve Python-free; RoundTrip
blacklist; cache hit/miss; GPU-less via `TUNEX_SOLVE_PROVIDER=xiaomi`; issue dedup + `test:generic`
collapse; issue-id shapes; CredenceRuleGenerator extend/create/bugfix/fail; git `main`-protection; single-pass resume;
boot recovery; credence `mix test` green).

### Sequencing
Critical path **M0 → M1/M2 (parallel) → M3 → M6**; M4 alongside M3; M5 after M2+M4. Earliest runnable
slice = **M0+M1+M2+M3** (convert loop, no evolve).

### Setup prerequisites (user-supplied)
- `secrets.exs`: Mimo `Authorization` header + endpoint (no git creds in the app — SSH key in the clone).
- User-cloned `Cinderella-Man/credence` at `/home/car/projects/credence`, **`evolution` branch created**
  + checked out (only `main` exists today), `origin` pre-authenticated (**SSH key** or credential helper)
  + commit identity set; `main` branch-protected.
- Mimo runaway-ceiling $ number (+ per-token price).
