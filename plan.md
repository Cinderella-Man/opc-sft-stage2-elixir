# Plan: Self-Evolving Elixir SFT Converter (Tunex v2)

## Primary goal (read first)
**Generate and validate/improve as many Credence rules as possible.** Converting the SFT dataset is
**not** the goal — it is merely a good 24/7, human-free *workload* that surfaces where Credence is weak.
Every design choice is judged by "does this yield more/better rules?" and "is this the simplest thing
that works?" Dataset quality is a secondary byproduct.

## Context
`scripts/convert.exs` (790 lines) outgrew a script. Today convert→refine→validate run in one tangled
flow where the local LLM sees Python instruction/code/tests *while* writing the Elixir solution —
causing **translationese / source-language interference** (Python idioms bleed into Elixir). That bleed
is useful: it is exactly the non-idiomatic code that reveals **missing Credence rules**. Crucially,
non-idiomatic-but-correct Elixir **compiles, passes tests, and trips no linter issue** — so the
*output code itself* is the rule-discovery signal, not any error/issue. Validation depends on
**Credence** (custom AST linter, local clone at `/home/car/projects/credence`; **90 rules** across
`lib/{pattern,syntax,semantic}` — 77/6/7; 138 test files; rules auto-discovered by `@behaviour` scan).

Restructure into a proper OTP app running a self-evolving loop. Per SFT row: translate (remote) → solve
(local, Python-blind) → validate → **learn** (a Claude-Code agent, driven by Mimo, generates/
extends/fixes a Credence rule). The app walks the **~118k-row dataset once, forward**, in a seeded-
shuffle order, until the user stops it (118k × minutes-per-row ≈ years, so it never finishes a pass — it
runs for days, the user stops it, inspects/PRs the new rules, then manually reinitializes for the next
run). Old code preserved runnable under `v1/`.

---

## Confirmed decisions

1. **Translate** = remote **Xiaomi Mimo** (`mimo-v2.5-pro`, plain chat-completions); produces Elixir
   instruction + Elixir tests **+ an Elixir reference solution (validation-only, never emitted/trained)**.
   Cached **forever**, key = `sha256(system_prompt + rendered_user_prompt + model)` (prompt change
   auto-invalidates). Token floor **32k**. **Truncation** (output didn't fit) → retry once with a
   **raised ceiling** (up to Mimo's 131k max), *not* a same-ceiling re-roll; if it still truncates →
   durable **negative-cache blacklist** (`verdict: :blacklist, reason: :untranslatable`, no payload). A
   truncated/partial translation is **never** cached as usable.

2. **Round-trip check (blacklist filter)** = run the Elixir reference against the translated tests via a
   **fix-free runner** (`mix compile --warnings-as-errors` + `mix test` ONLY — **no Credence-fix, no
   credo, no credence-check**); require PASS before Solve. Fix-free makes the verdict a **pure function
   of `(reference, tests)`**, immune to the evolving rule set. Fail → re-translate once → else
   **permanently blacklist the row** (`verdict: :blacklist, reason: :roundtrip_fail` — "broken by
   definition"). **Verdict cached with the translation** (run once, not per pass). *Purpose:* never waste
   an expensive Solve+CredenceRuleGenerator session on a mistranslated/ unsatisfiable row — **not** data quality.

3. **Canonical names** = module pinned to `Solution`; function = deterministic Elixir name from
   `entry_point` (`Parser.elixir_name`, e.g. `is_palindrome`→`palindrome?`). **Injected into all prompts**
   (translate + reference + solve) and **trusted**; the only programmatic enforcement is `NamingFixup`'s
   `is_ → ?` fix. A mismatch just fails validation (tests target the canonical name) → normal retry.

4. **Solve** = **local Qwen**, Python-blind (prompt = ONLY Elixir instruction + Elixir tests + canonical
   fn name). **Plain single-shot generation + retry** — reuse v1's `ConvertLoop.attempt` loop skeleton;
   the Validator runs the pipeline and feeds failures back into the retry prompt. **No agent harness**
   (a 3090 cannot host Claude Code's payload, and Solve needs no tools). Env-swappable to a remote
   provider for GPU-less dev (`TUNEX_SOLVE_PROVIDER=xiaomi_mimo_2_5_pro`). Qwen's non-idiomatic output is
   the **rule-discovery feedstock**.

5. **Evolve = a Claude-Code agent driven by Mimo.** The CredenceRuleGenerator shells out to the **Claude Code
   CLI** (`claude -p … --output-format json`) with **`cwd` = the credence clone** and
   `ANTHROPIC_MODEL=mimo-v2.5-pro[1m]`.
   - **"Claude Code" (the harness) ≠ "Claude" (the model).** The model behind it is **Mimo** — so this
     does **not** reintroduce the Anthropic/Claude dependency that was deliberately cut. Mimo stays the
     **only paid model**.
   - **Runs on EVERY row** (not gated on issues): the most valuable rows — clean, passing, non-idiomatic —
     have **zero** issues, so an issue-gate would skip exactly the rows that matter. Trades row-throughput
     (~2× per-row time) for rule-discovery thoroughness — the correct trade for the primary goal.
   - **Input = the row's full raw log** (the output code + the Credence before/after fix trace). The agent
     **reads rule files off the filesystem itself** (`Read`/`Grep` in the clone) — **no rule-body
     injection, no index, no retrieval protocol.** Prompt is tiny: raw log + the current `decisions.md`
     ledger + an open-ended task ("do you see any, even smallest, opportunities to deterministically
     improve this output code with a new/extended rule? or any bug in an existing rule visible in the
     fix trace?").
   - **Sandbox (trust boundary):** `--allowedTools "Read Grep Glob Edit Write Bash(mix test:*)"`,
     `--disallowedTools "Bash(git:*)"`, `--add-dir <clone>`, `--max-turns 30` (config), **no git
     credentials in its env**. The agent edits + runs `mix test`; it cannot commit or push.
   - **`--max-turns` hit without finishing → treated as `gave_up`.**
   - **Test strategy:** prompt the agent to **iterate with targeted tests** (`mix test
     test/<phase>/<rule>_test.exs` — fast) and **run the full suite once before finishing** to catch
     collateral breakage; the Gate's full-suite-green is the authoritative backstop regardless.
   - **Decision signal:** the agent's final message carries a parseable `DECISION:` line
     (`gave_up: <reason>` vs a rule proposal). This drives ledger-writing + provenance; the **Gate** (not
     the agent's self-report) decides commit/reject.

6. **Trust boundary / Gate** = the agent **edits only** (no git creds). **If the working tree is clean
   after the agent exits (a `gave_up` with no edits), the Gate — and its full-suite `mix test` — is
   skipped entirely** (nothing to verify). So the expensive full-suite run happens only on rows where a
   rule was actually proposed (the minority). Otherwise our Elixir **Gate** stages everything
   (`git add -A`) and enforces a **hard 5-part contract** on `git diff --cached`:
   - **(a)** full Credence `mix test` **green**;
   - **(b)** diff touches **`lib/`** (a rule/infra file changed);
   - **(c)** diff touches **`test/`** (a regression test added/modified);
   - **(d) mutation check** (on **added/modified** test files only): snapshot the touched `lib/` files →
     restore `lib/` to HEAD (`git checkout HEAD -- <tracked>`; `rm` new untracked) → run the changed test
     file(s) → assert **non-zero exit** (the test genuinely needs the rule; **a compile error on revert
     counts as RED**) → restore the snapshot;
   - **(e) scope check** — the diff touches **only `lib/` and `test/`**; anything else (`mix.exs`,
     `config/`, `.formatter.exs`, `deps/`, README, CI) → reject.

   **Deletions/renames are allowed** (a rename is delete+add; supersession is legitimate consolidation) —
   the **branch-protected `main` + manual PR review** is the backstop for "was this removal warranted,"
   not the Gate. All checks pass → `commit → recompile → push` (#11/#14). Any miss →
   `git checkout -- . && git clean -fd` discard + `gave_up` + append to `decisions.md` + escalate.
   The commit message **tags the decision type and flags removals** (e.g.
   `cred-gen: supersede X [removes rule Y] [row 4127]`) to direct human PR attention.

7. **Eager rule generation — even micro-rules are welcome.** The agent proposes a rule for *any* genuine
   deterministic improvement, however small; volume is fine. Two safety nets make over-firing acceptable:
   - **Generation-time gate:** every add/extend/bugfix ships a **new regression test** (Gate-enforced via
     diff-touches-`test/` + the mutation check). New rules *should* include a "must-NOT-fire on good code"
     case (good hygiene; not separately gated). Pure deletion/rename needs no new test. Compile-failing
     fixes self-revert via Credence's `:reverted` gate (harmless).
   - **Self-correction of over-firing (NEW — supersedes the old "not self-corrected" caveat):** because
     the CredenceRuleGenerator runs **every row** and reads the **full Credence fix trace** (before/after +
     `applied_rules`), a rule that wrongly rewrites correct code surfaces at the **first occurrence** it
     over-fires — as a broken test or a visibly-wrong before/after — and the agent fixes it as a
     **bugfix**. The old "over-firing looks like `test:generic` and isn't self-corrected" limitation was an
     artifact of the deleted issue-gated generator; with every-row generation + full-trace input, over-firing
     *is* catchable. The **main SFT *emission*** stays decoupled (the row's emitted result never depends on
     whether a rule was generated), but the **CredenceRuleGenerator track is the self-correction path.**
   - **Final curation** = the human PR from `evolution` → protected `main`.

8. **Dedup (no issue-id machinery).** Two mechanisms, no exact keys:
   - **Emergent:** once a rule is committed + Credence recompiled, it auto-fixes that pattern → the
     pattern vanishes from all future output → the agent never sees it → never re-proposes it.
   - **`var/run/decisions.md` ledger** for *dead-ends* (patterns the agent couldn't turn into a rule, or
     the Gate rejected): **written by the orchestrator** (not the agent — keeps the agent sandboxed to the
     clone), **inlined into every CredenceRuleGenerator prompt** so the agent won't retry them. **The agent composes the
     entry** when it gives up (its `DECISION: gave_up` block carries a one-line pattern description + a
     minimal offending snippet); the orchestrator appends it verbatim. **On a Gate rejection** (the agent
     thought it succeeded), the orchestrator instead composes a terse entry from the Gate failure reason +
     the attempted rule. **Append-always** (no auto-dedup — the agent reading the ledger is what prevents
     re-proposing; redundancy is cheap). **Run-scoped** (in `var/run/`, wiped by `mix tunex.reset`) — a
     dead-end on a small Qwen may be solvable after a model swap, so a fresh run re-attempts.
   - **DROPPED entirely:** `Tunex.Issues`, the issue-id scheme (`credence:`/`credo:`/`compile:`/
     `test:generic`), the compile-error regex bank, the `gave_up` set, `test:generic` collapse. The agent
     reads any failures straight from the raw log; nothing else consumes structured issue-ids.

9. **Single forward pass — NO infinite loop, NO re-passes, NO convergence/wipe.** Walks the ~118k-row
   dataset once in a **seeded-shuffle order** (deterministic permutation of `0..n-1` from a fixed seed
   persisted in `var/run/`; a representative *sample*, not parquet's topic-clustered order, maximizing
   failure-mode diversity; resume reproducible). 118k × minutes ≈ years ⇒ never finishes; run for days,
   then stop. Everything just **persists for the run** — translation cache, blacklist, `decisions.md`,
   `escalated/`, `committed/`, append-only SFT output, committed rules. `Progress` gives crash-resume.
   **Re-init is MANUAL:** `mix tunex.reset` (wipes `var/run/`, keeps `var/cache/`), then rerun. Rules are
   already pushed on `evolution`; the user manually PRs them to `main`.

10. **Providers — hardcoded per stage** (no `mechanism` field; they never change at will):
    - `translate` → Mimo via `LLM.call` (`/v1/chat/completions`),
    - `solve` → local Qwen via `LLM.call`,
    - `rule-gen` → Mimo via the **Claude Code subprocess** (`/anthropic` endpoint).
    `stages` map selects model/provider for the two chat stages; `TUNEX_{TRANSLATE,SOLVE}_PROVIDER` env
    overrides apply only to them. The rule-gen path is hardcoded in `Tunex.Evolve.CredenceRuleGenerator`. Keys in
    `secrets.exs`; git auth lives in the clone's SSH remote, not the app.

11. **Git topology** = **single canonical repo** `Cinderella-Man/credence`, **cloned by the user** at
    `/home/car/projects/credence` (current `origin` = `git@github.com:Cinderella-Man/credence.git`, **SSH
    key**), **on a hand-created `evolution` branch** (clone currently has only `main` — user must create +
    push `evolution` first), with a **commit identity** set. The app runs plain `git commit` +
    `git push origin evolution` — **never handles credentials**. **`main` is branch-protected** (the hard
    safety rail). Same clone is what the loop compiles against (path dep) and pushes from.

12. **Budget (single concern)** = **Mimo is the only paid dependency** (Translate + CredenceRuleGenerator; local Qwen is
    free) and runs **essentially uncapped** with a **runaway-safety ceiling** only (abort at absurd spend,
    e.g. 50× expected — catches loops, not rationing; **size it for a Mimo CredenceRuleGenerator session on every row**).
    Accumulate **Mimo `usage` tokens × configured price** from each Translate response **and from the
    Claude Code JSON output** (`input_tokens`/`output_tokens` incl. cache fields). **Ignore CC's
    `total_cost_usd`** — it is computed from Anthropic pricing and is wrong/zero for a custom Mimo model.
    Fallback: request/session count if `usage` is absent. **Mimo exhaustion / runaway → graceful
    `Tunex.shutdown(reason)`**: log raw body → flush/close RowLog → `File.sync`+close SFT/error handles →
    **`System.halt(1)`** (clean exit, never a raise, so the supervisor can't restart into a fatal storm).

13. **Runtime** = supervised **Orchestrator GenServer**, `mix run --no-halt`, **single stream** (no
    parallel workers, one GPU, one clone). After an accepted rule: `mix deps.compile credence --force`.
    **Per-row `try/rescue`:** a row that throws → log it, `git checkout -- . && git clean -fd` the clone,
    skip the row, continue (don't crash the loop). Reserve process-crash + supervisor restart +
    reconciliation for unexpected death (kill/OOM).

14. **Boot preflight (fail fast, DX)** = before processing any row, verify preconditions and **halt
    (`System.halt(1)`) with actionable fix instructions** on any miss (no crash-loop): clone exists + is a
    git repo + **current branch == `evolution`** + tree clean (post-reconciliation); `claude` on `PATH`
    (`--version`) **and a one-shot CC smoke test against Mimo** (`claude -p "reply OK" --output-format
    json` — validates base URL + token + model end-to-end so a bad CredenceRuleGenerator-path auth doesn't masquerade as
    "agent always gives up"); `secrets.exs` has both Mimo-chat + CC credentials; Mimo chat endpoint
    reachable; credence compiles in the workspace.

    **Boot reconciliation** = on start: **`git reset --hard HEAD && git clean -fd`** (reset to **HEAD**,
    NOT `origin/evolution` — preserve un-pushed local commits; discard half-written WIP); log "evolution at
    <sha>, origin at <sha>, N ahead"; **best-effort** `git push origin evolution` catch-up (non-fatal);
    force-recompile credence; load `decisions.md`; load/derive the shuffle permutation from the persisted
    seed; resume from the explicit `Progress` file.

15. **Logging = plain `Logger` + a per-row file capture.** v1 already `Logger.debug/info`s everything
    (every LLM call in/out, code before/after each `Credence.fix`, all validator output). Keep the default
    `:logger` console handler (watch live) **and** add a native `:logger` file handler (OTP's
    `:logger_std_h` — **not** the legacy `:logger_file_backend`). Per row, swap the file handler's path via
    `:logger.update_handler_config(:row_file, :config, %{file: ~c"var/run/logs/<index>.log"})`; **the row's
    raw log file is the literal input the CredenceRuleGenerator reads** (force a filesync before reading).
    `applied_rules` lands in it for free: `run_credence_fix.exs` does `IO.puts(inspect(applied_rules))`
    (entries = `{module, count | :reverted}` — full module names) and the Validator logs the captured
    subprocess stdout. **Per-row lifecycle:** on completion **delete the log** — UNLESS the agent
    **gave up** → **move** to **`escalated/<index>.log`** (manual queue), OR the row **committed a rule** →
    **move** to **`committed/<index>.log`** (rule provenance; pair it with the agent's JSON transcript).
    Invariant: the only logs surviving on disk are `escalated/` and `committed/`.

16. **Storage layout = keep-vs-wipe split:**
    - **`var/cache/`** — survives re-init. `translations.jsonl` = Mimo's instruction+tests+reference
      ("tasks"), **with a `verdict: :ok | :blacklist` + `reason: :roundtrip_fail | :untranslatable`
      field**. So **blacklist is not a separate file** — a row is blacklisted iff its cached record has
      `verdict: :blacklist` (covers both unsatisfiable tests and untranslatable/truncated rows; the latter
      is a payload-less negative-cache entry).
    - **`var/run/`** — everything regenerable: `decisions.md`, the **`Progress`** file (explicit, one
      index per line — `mark_done` is called on **every** finished row: success, hard error, **and**
      blacklist-skip), the **shuffle seed**, SFT output, `escalated/` + `committed/` (the only surviving
      logs), the validation `workspace/`.
    - **Re-init = `rm -rf var/run/`** (cache untouched), exposed as `mix tunex.reset`.
    - **`.gitignore`** (tunex repo): `/var/`, `/config/secrets.exs`, `/_build/`, `/deps/`, `*.parquet`,
      + generated artifacts under `v1/`. The credence **clone** is a separate repo, unaffected.

Research backing: translationese / source-language interference (arxiv 2503.04369, 2503.13620,
2403.17214); learn-from-failure loops (AutoHarness 2603.03329, BitsAI-Fix 2508.03487). Principle =
isolate target-language generation from source + gate self-generated artifacts behind their own passing
tests.

---

## Verified integration facts (Mimo + Claude Code, researched 2026-05-30)
- **Mimo chat API** (`https://api.xiaomimimo.com/v1/chat/completions`, or your `token-plan-sgp` host) is
  OpenAI-compatible: supports `tools`/`tool_choice`/`tool_calls`, returns `usage`
  (`prompt_tokens`/`completion_tokens`/`total_tokens`) and `finish_reason`. Token-limit param spelling is
  **`max_completion_tokens`** (verify whether `max_tokens` is also honored).
- **Claude Code ↔ Mimo (official):** point Claude Code at Mimo's **Anthropic-compatible** endpoint —
  `ANTHROPIC_BASE_URL=https://api.xiaomimimo.com/anthropic` (or the `token-plan-*/anthropic` host),
  `ANTHROPIC_AUTH_TOKEN=tp-…`, `ANTHROPIC_MODEL=mimo-v2.5-pro[1m]` (`[1m]` = 1M context). Requires
  Node 18+.
- **Credence module⇄path:** `Credence.Pattern.Foo` → `lib/pattern/foo.ex` (snake_case); phase dispatchers
  live at `lib/{pattern,syntax,semantic}.ex` (lib root), shared helpers at `lib/rule_helpers.ex`,
  `lib/credence.ex`, `lib/function_matcher.ex`, `lib/issue.ex`. (Rule edits sometimes legitimately touch
  these — hence Gate scope = all of `lib/`, not just the three rule subdirs.)
- **Credence API:** `Credence.analyze/2` → `%{valid, issues}`; `Credence.fix/2` →
  `%{code, issues, applied_rules}` (`applied_rules` = `[{module, count | :reverted}]`). `Issue` =
  `%{rule, message, meta: %{line}}`. Tests: one `_check_test`/`_fix_test` per rule, using
  `Sourceror.parse_string!/1` + `RuleHelpers.apply_rule_fix/3`. Extend-prototype =
  `Credence.Pattern.HallucinatedGuard` (`@hallucinated_guards` map).
- **`LLM.call` latent bugs (v1):** drops `opts[:max_tokens]` (reads only active_provider/url/headers/
  timeout); returns flattened `"HTTP <status>"`; and the `content != "" -> {:ok, content}` branch wins
  before the `finish == "length"` check, so truncated-but-nonempty output is silently accepted (llm.ex
  47–63). All fixed in T1.4.

---

## Architecture
```
Tunex.Application            supervision tree; adds the native :logger row-file handler
Tunex.Orchestrator (GenServer) single seeded-shuffle pass: pick row → translate → round-trip → solve →
                             validate → rule-gen → gate → git → emit SFT; per-row try/rescue; graceful
                             shutdown on Mimo halt
Tunex.RowLog                 swaps the :logger file-handler path per row; on done deletes / MOVES to
                             escalated/ or committed/
Tunex.Cache                  translate cache (var/cache/translations.jsonl + roundtrip verdict = blacklist)
Tunex.Config                 stage→provider resolution + env overrides + CC env/paths
Tunex.ClaudeCode             thin subprocess wrapper: build argv/env, run `claude -p`, capture JSON,
                             extract usage (→ Budget) + the DECISION line
Pipeline:
  Tunex.Pipeline.Translate   Mimo: Python→Elixir instruction + tests + reference (ONLY Python stage); cached
  Tunex.Pipeline.RoundTrip   fix-free runner (compile+test only) reference vs tests; pass → Solve; fail →
                             re-translate/blacklist
  Tunex.Pipeline.Solve       local Qwen: Elixir instruction + tests → solution (Python-blind); retry
                             on validation failure (no separate Refine stage — dropped)
Evolve:
  Tunex.Evolve.CredenceRuleGenerator        builds the prompt (raw row log + decisions.md + task), invokes ClaudeCode in
                             the clone (≤30 turns, sandboxed), parses DECISION; on gave_up → ledger +
                             escalate. (Drives the Claude Code agent.)
  Tunex.Evolve.Gate          git add -A → 5-part contract (full mix test green + diff touches lib/ + diff
                             touches test/ + mutation check + scope check); else discard
  Tunex.Evolve.Git           commit (tagged msg) → recompile → push origin evolution (non-fatal push)
Tunex.Budget                 accumulate Mimo usage×price (Translate + CC JSON); runaway ceiling; fatal/
                             transient classification; graceful System.halt
```
**Copy & adapt from v1:** `LLM` (multi-provider), `Parser`, `Validator` (capture Credence before/after
trace), `Workspace` (drop pool; path dep), `Dataset`, `Progress`, `JSONL`, `Report`, `NamingFixup`.
**Dropped vs earlier draft:** `Tunex.Issues` + the whole issue-id/regex-bank/`gave_up` apparatus; the
hand-rolled rule-generator tool loop (→ Claude Code); `Evolve.Triage`/`Escalate`/`Revalidate`; the
Anthropic pool / Claude-the-model escalation; prompt-cache-prefix injection of the full rule set.

## Flow per row
1. `Progress` → next index in the shuffled permutation not in the completed set; `RowLog.open`.
   (Blacklisted rows — `Cache` `verdict: :blacklist` — are skipped and `mark_done` immediately; on a
   post-reset run they re-walk once, hit the cache, and re-mark.)
2. **Translate** (Mimo, cached): instruction + tests + reference solution.
3. **RoundTrip** (fix-free, compile+test only): reference must pass tests; else re-translate once → else
   **blacklist** + skip. Verdict cached forever = pure fn of (ref, tests).
4. **Solve** (Qwen, Python-blind, canonical names): plain generation + retry on validation failure.
5. **Validate**: `Validator.run` (credence fix→compile→format→credo→credence→test); retry the solve on
   failure (`max_retries`). All before/after + `applied_rules` are `Logger`ed → land in the row's log
   file. (No Refine stage — dropped; raw solve output is both the emitted record and the rule feedstock.)
6. **CredenceRuleGenerator** (decoupled learning track — does NOT change this row's emitted result): on **every** row,
   `Tunex.Evolve.CredenceRuleGenerator` invokes the Claude Code agent (Mimo, ≤30 turns, sandboxed, `cwd`=clone) with the
   raw row log + `decisions.md` + the open-ended task. Agent reads/greps rule files itself, edits, runs
   `mix test`, emits `DECISION:`. If the tree is clean (no edits) the Gate is skipped. Else **Gate** runs
   the 5-part contract; pass → **Git** `commit → recompile →
   push origin evolution` (non-fatal push) + move log to `committed/`; fail/gave_up → discard, append a
   dead-end entry to `decisions.md`, move log to `escalated/`.
7. Append the SFT success/error record (synced) **based on step 5** (independent of step 6); a
   hard-errored row emits an error record and is **done — not retried on resume**. Delete the row log
   unless step 6 moved it. `Progress.mark_done` (**LAST**, after the synced append); next row. Runs
   forward through the shuffled permutation until killed (no re-pass, no wipe).

## Credence dependency strategy
`Workspace` deps → local **path dep** `{:credence, path: "/home/car/projects/credence", only: [:dev,:test],
runtime: false}`. The loop compiles + validates against the LOCAL checkout (push = backup/share). During a
row's steps 2–5 the clone sits at committed `evolution` HEAD (the agent edits it only in step 6), so
validation always sees the **last-committed** ruleset. Single stream ⇒ no lock. The CredenceRuleGenerator runs its
own `mix test` in the same clone; the Gate's mutation check and `Git.recompile` also operate there.

## Files
- **Create:** `lib/tunex/{application,orchestrator,row_log,cache,config,claude_code,budget}.ex`,
  `lib/tunex/pipeline/{translate,round_trip,solve}.ex`,
  `lib/tunex/evolve/{credence_rule_generator,gate,git}.ex`, `docs/plan.md`, `var/run/{escalated,committed}/`.
  Add `:xiaomi_mimo_2_5_pro` provider + `stages` map + CC env/paths to `config/config.exs`; Mimo key +
  CC auth token in `secrets.exs`; `mod:` in `mix.exs`.
- **Modify:** `workspace.ex` (path dep, drop pool, `recompile_credence`), `validator.ex` (Credence
  before/after trace capture), `llm.ex` (per-stage provider + T1.4 fixes). Move the Solve prompt into
  `Pipeline.Solve` (rewritten Python-free).
- **Copy & adapt:** `parser.ex`, `dataset.ex`, `progress.ex`, `jsonl.ex`, `report.ex`, `naming` helpers.
- **Snapshot to `v1/`:** whole current project.

## Implementation tasks

Build strategy: vertical slice first (M0–M3 = runnable convert loop, no evolve), then layer the
Claude-Code CredenceRuleGenerator + Gate (M4) and the supervised Orchestrator + Budget (M5).
**Principle:** v1 is COPIED into v2 as raw material and freely rewritten — NOT imported or signature-
preserved. Reshape into the most obvious v2 form; don't contort v2 to match a v1 signature. v1 stays
runnable under `v1/` only as reference.

### M0 — Snapshot to `v1/` + new app skeleton
- **T0.1** Move the entire current project into `v1/` (`mix.exs, mix.lock, lib/, scripts/, config/,
  .formatter.exs, test/, *.jsonl, *.parquet, tunex_workspace_0/, README.md, output_v1/`). Leave at root
  only `.git/` + `plan.md`. Verify `cd v1 && mix run scripts/convert.exs educational_instruct --start 0`.
- **T0.2** `plan.md` → `docs/plan.md`.
- **T0.3** New root `mix.exs`: `app: :tunex`, `mod: {Tunex.Application, []}`, deps `{:req,"~> 0.5"},
  {:explorer,"~> 0.10"},{:jason,"~> 1.4"}` (**no `:logger_file_backend`** — RowLog uses OTP's native
  `:logger_std_h`). New `config/config.exs` (`config :logger, level: :debug`; default console handler +
  the row-file handler added in `Tunex.Application`), `.formatter.exs`. (Main app does NOT dep on
  credence — it shells into the workspace.) `.gitignore` per #16.
- **T0.4** Copy reused modules into `lib/tunex/`: `parser, dataset, progress, jsonl, report, llm,
  workspace, validator` (last three modified later). Drop `cli`/`trajectory_logger` (→ RowLog).
- **T0.5** `Mix.Tasks.Tunex.Reset` (`mix tunex.reset`) = `rm -rf var/run/` + recreate empty dirs; leaves
  `var/cache/` intact.

### M1 — Config + per-stage providers + CC integration  *(dep: M0)*
- **T1.1** `config.exs`: **rename `:xiaomi` → `:xiaomi_mimo_2_5_pro`** (`model: "mimo-v2.5-pro"`), update
  `secrets.exs` to match, **add a floor `max_tokens`/`max_completion_tokens`** (currently none → Mimo
  truncates). Keep `max_retries: 5` (Refine dropped → no `max_refine_retries`). Add
  `subset: "educational_instruct"` + a
  persisted **shuffle seed**. Add `stages %{translate: :xiaomi_mimo_2_5_pro, solve: :local_qwen_thinking}`
  (the rule-gen stage is hardcoded). Add **CC config**: `claude_code %{base_url, auth_token (secrets), model:
  "mimo-v2.5-pro[1m]", max_turns: 30}`, `credence_clone` path, and the `var/cache/` vs `var/run/` paths.
  Add **Budget config**: per-token price + runaway ceiling.
- **T1.2** `Tunex.Config`: `provider_for(stage)` = `TUNEX_<STAGE>_PROVIDER` env → `stages[stage]` (chat
  stages only); CC + path helpers.
- **T1.3** `config/secrets.exs` (gitignored): Mimo chat `Authorization` header + CC `ANTHROPIC_AUTH_TOKEN`.
  *(No git creds — SSH key lives in the clone's remote.)*
- **T1.4** **Fix `LLM.call`** (Translate/Solve only): (1) merge per-call `opts` overrides
  (`max_tokens`/`temperature`) into `body_params`; (2) return **classified errors** `{:error, {:http,
  status, body}}` / `{:error, {:network, reason}}`; (3) read `usage`; (4) **reorder `handle_response`** so
  `finish_reason == "length"` returns `{:truncated, content}` **even when content is non-empty**. Then
  `LLM.for_stage(stage, …)` injects `active_provider` + the stage's token floor. **Translate:**
  `{:truncated, _}` = hard error — retry once with a **raised ceiling** (up to 131k), never cache a
  partial; still truncated → negative-cache blacklist (`reason: :untranslatable`). **Solve:**
  `{:truncated, _}` = normal failed attempt → retry.

### M2 — Workspace: single + path dep + richer scripts  *(dep: M0)*
- **T2.1** `workspace.ex`: delete pool fns; **single workspace at `var/run/workspace/`**, `clean_workspace`
  between rows. Deps → `{:credence, path: "/home/car/projects/credence", only: [:dev,:test], runtime:
  false}`. Replace `update_credence/1` with `recompile_credence/1` (`mix deps.compile credence --force`,
  dev+test).
- **T2.2** Enhance `@credence_fix_script`: in addition to `FIXED/NO_CHANGES`,
  `IO.puts(inspect(result.applied_rules))` and print remaining issues (`#{rule}: …`) — plain stdout,
  captured into the row log. (Feeds the CredenceRuleGenerator.s before/after fix trace.)
- **T2.3** Single-path workspace bootstrap; `deps.get` + `deps.compile` (dev+test) against the path dep.

### M3 — Pipeline + RowLog: translate → round-trip → solve  *(dep: M1,M2)*
- **T3.1** `Tunex.Cache` (`var/cache/translations.jsonl`): `key=sha256(system+rendered+model)`, `get/put`.
  Each record carries `verdict: :ok | :blacklist` + `reason: :roundtrip_fail | :untranslatable`;
  `blacklisted?/1` = `verdict == :blacklist`. A blacklist may be a payload-less negative-cache entry
  (truncation). Survives `mix tunex.reset`.
- **T3.2** `Pipeline.Translate` (Mimo, **token floor 32k**): instruction + tests + **reference**; canonical
  names injected; markers `---INSTRUCTION---/---TEST---/---REFERENCE---/---END---` →
  `Parser.parse_translate/1`. **Never cache a truncated/`:empty` response;** cache only complete parses.
  On `{:truncated,_}` retry once with a raised ceiling, then negative-cache blacklist (`:untranslatable`).
- **T3.3** `Pipeline.RoundTrip`: reference vs tests via a **fix-free runner** (write reference+tests,
  `mix compile --warnings-as-errors` + `mix test` ONLY). Fail → re-translate once (bypass cache) → else
  `Cache` writes `verdict: :blacklist, reason: :roundtrip_fail` + skip. Cache the verdict with the
  translation (run once, not per pass).
- **T3.4** `Pipeline.Solve` (Qwen, **Python-blind**): reuse the loop skeleton of `ConvertLoop.attempt` +
  `NamingFixup.fix_is_prefix`, `Validator.run/3`, `Parser.parse_module_test`. **Rewrite ALL prompts
  Python-free** (v1 prompts at convert.exs:13–45,261–281,677–684 are saturated with Python — MUST NOT be
  reused). New system = "write idiomatic Elixir satisfying this Elixir spec + tests" (no Python mention);
  new user = Elixir instruction + tests + canonical fn name ONLY; new retry = previous Elixir attempt +
  Validator errors + canonical-name reminder (no `## Original Python`). **Guard:** unit test asserts
  assembled prompts contain no `` ```python `` and not the row's Python source.
- **T3.5** `Tunex.RowLog` — thin manager of a native `:logger` file handler (`:logger_std_h`):
  `open(index)` → swap path to `var/run/logs/<index>.log`; `path/0` (CredenceRuleGenerator reads after a forced
  filesync); `close/0` deletes; `escalate(index)` moves to `escalated/`; `commit(index)` moves to
  `committed/`. Handler added in `Tunex.Application`. `Validator` also returns the credence-fix **trace**
  (before/after/`applied_rules`) → logged for the CredenceRuleGenerator.

### M4 — Evolve: CredenceRuleGenerator (Claude Code) → gate → git  *(dep: M2,M3)*
- **T4.1** `Tunex.ClaudeCode`: build argv (`claude -p <prompt> --output-format json --add-dir <clone>
  --allowedTools "Read Grep Glob Edit Write Bash(mix test:*)" --disallowedTools "Bash(git:*)" --max-turns
  30`) + env (`ANTHROPIC_BASE_URL`/`ANTHROPIC_AUTH_TOKEN`/`ANTHROPIC_MODEL`; **no git creds**), run via
  `System.cmd` (cwd=clone), parse JSON → `{result_text, usage, num_turns}`; feed usage to Budget; extract
  the `DECISION:` line; max-turns-without-finish → `gave_up`.
- **T4.2** `Tunex.Evolve.CredenceRuleGenerator`: build the prompt = raw row log (`RowLog.path` contents) + current
  `decisions.md` + open-ended task; call `ClaudeCode`; route on `DECISION`. On `gave_up` → append a
  dead-end entry (pattern + snippet) to `decisions.md` → `Gate`/escalate.
- **T4.3** `Tunex.Evolve.Gate`: `git add -A` → **5-part contract** (#6): full `mix test` green + diff
  touches `lib/` + diff touches `test/` + **mutation check** (snapshot touched `lib/`, restore to HEAD —
  `checkout HEAD` tracked, `rm` new — run changed *added/modified* test files, assert non-zero exit incl.
  compile error, restore) + **scope check** (only `lib/` + `test/`). Any miss → `git checkout -- . &&
  git clean -fd` + append to `decisions.md`.
- **T4.4** `Tunex.Evolve.Git`: **`commit → recompile → push`**. `git -C clone add -A && commit -m
  "cred-gen: <decision> <rule> [removes …] [row <idx>]"` → `recompile_credence` (auto-dedups) →
  `git push origin evolution` **non-fatal** (warn + continue on failure; boot catch-up reconciles). On
  success, `RowLog.commit(idx)` (+ save the CC JSON transcript beside it for provenance).

### M5 — Orchestrator + Application + Budget  *(dep: M3,M4)*
- **T5.1** `Tunex.Budget` + **error classification**: accumulate Mimo `usage`×price (Translate responses +
  CC JSON); **fatal** Mimo errors (`401/402/403`, or `429`×N consecutive) → halt immediately; **transient**
  (`5xx`/network) → bounded retry+backoff → halt if it won't clear; always **log raw body**. **Runaway $
  ceiling** sized for a CC CredenceRuleGenerator session every row; fallback to session-count if `usage` absent. **"Halt"
  = graceful `Tunex.shutdown(reason)`** → flush/sync/close handles → `System.halt(1)`.
- **T5.2** `Tunex.Orchestrator` GenServer — **single seeded-shuffle pass**: boot **preflight** (fail fast
  w/ guidance, incl. CC smoke test) + reconciliation (#14);
  per-row flow over the permutation (translate→roundtrip→solve→validate→rule-gen→gate→git→append SFT (synced)
  →`RowLog.commit/escalate/close`→`Progress.mark_done` **LAST**); advance until killed/exhausted, then
  exit. **Per-row `try/rescue`** (#13).
- **T5.3** `Tunex.Application`: supervision tree (Orchestrator child; `:transient`/`:permanent` so an
  unexpected crash restarts → reconciliation, but `System.halt` ends cleanly); add the row-file `:logger`
  handler; `mix run --no-halt`.

### M6 — Verification  *(dep: all)*
1. `cd v1 && mix run scripts/convert.exs educational_instruct --start 0` → old path runs.
2. **Solve Python-free:** assembled initial+retry prompts contain no `` ```python `` and not the row's
   Python source; canonical module/function present in tests+solution.
3. **RoundTrip:** mistranslated test → reference fails compile/test → row **blacklisted** + skipped; a
   stylistically-poor-but-passing reference is **not** blacklisted (fix-free runner ignores credo/
   credence).
4. **Cache:** row twice → 2nd is a hit; edit translate prompt → miss; truncated translate never cached.
5. **GPU-less:** `TUNEX_SOLVE_PROVIDER=xiaomi_mimo_2_5_pro mix run --no-halt` runs end-to-end, no local
   model.
6. **CredenceRuleGenerator runs every row:** a clean, passing, non-idiomatic row (zero issues) still invokes the agent.
7. **CredenceRuleGenerator create/extend/bugfix:** novel idiom → new rule + regression test; hallucinated fn → added to
   an existing conversion-list rule; over-firing rule → bugfixed + a test locking the case.
8. **Gate:** rejects (a) no new regression test, (b) a test that stays green when the rule is
   stashed (mutation), (c) a diff touching files outside `lib/`+`test/` (scope), and allows a
   rename/supersession (delete+add). Pass → `commit → recompile → push origin evolution` (non-fatal push).
9. **Dedup:** a committed rule's pattern stops recurring in later rows' output (emergent); a dead-end
   logged to `decisions.md` is not re-attempted (it's inlined into the next prompt).
10. **CredenceRuleGenerator gave_up / max-turns:** force it → log moved to `escalated/`, working tree clean, dead-end
    appended to `decisions.md`.
11. **Git safety:** bot push to `main` rejected (branch protection); push to `evolution` succeeds.
12. **Mimo exhaustion / runaway:** graceful `shutdown` halts cleanly (handles flushed/synced, no torn
    lines); ceiling trips on absurd spend; CC `total_cost_usd` ignored, Mimo `usage` accumulated.
13. **Single pass + resume:** kill mid-run → restart → `Progress` skips done rows, blacklist (cache) +
    `decisions.md` reload, run continues forward; dataset exhaustion/kill → clean exit.
14. **Log lifecycle:** a pure convert success leaves **no** log; a gave-up row's log sits in `escalated/`;
    a rule-committing row's log + CC transcript sit in `committed/`.
15. **Boot recovery:** kill mid-rule-generation (dirty tree) **+ un-pushed commits** → restart → `reset --hard
    HEAD` discards WIP but **keeps** un-pushed commits, best-effort push catch-up, credence recompiled.
16. `cd /home/car/projects/credence && mix test` green before/after.

### Sequencing
Critical path **M0 → M1/M2 (parallel) → M3 → M5**; M4 after M2+M3. Earliest runnable slice =
**M0+M1+M2+M3** (convert loop, no evolve).

## Unresolved (values/setup, not design)
- **Mimo values:** context **1M**, max output **131k**; pricing **$1/M in, $3/M out** (≤256K tier; 2×/6×
  for 256K–1M), cache hit **$0.2–0.4/M in**. TODO: runaway-ceiling **$ number** (size for a CC CredenceRuleGenerator
  session every row); confirm `max_tokens` vs `max_completion_tokens`; confirm out-of-credit status code
  (refine classifier after first hit).
- **Setup (user-owned):** Mimo chat `Authorization` + CC `ANTHROPIC_AUTH_TOKEN` (+ `/anthropic` base URL)
  in `secrets.exs`. **Claude Code installed** (Node 18+). User clones `Cinderella-Man/credence` at
  `/home/car/projects/credence`, **creates + checks out `evolution`** (only `main` exists today),
  `origin` pre-authenticated (SSH key) + commit identity set; `main` branch-protected.
- **`escalated/` review:** manual-only; no triage workflow.
