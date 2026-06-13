# 11 — Corpus over-firing as a free Gate signal

## Context
Credence added a **real-world over-firing corpus** (`../credence/docs/09`): it runs the
Pattern rules over the `lib/` of ~10 pinned hex packages and pins every accepted finding as
`"<path>:<line>  <rule>"` in `test/corpus/accepted_findings.txt`. It is a **snapshot ratchet
in Credence's default `mix test`**:

- a **NEW** finding (a rule starts firing on idiomatic real code) → red = a likely over-fire;
- a **GONE** finding (a rule narrowed / was removed) → red = re-pin needed.

Re-pin with `mix credence.corpus --update-snapshot`.

This harness already runs the clone's full `mix test` in one token-free place — the **Gate**
(`Gate.check_full_suite/1`, `System.cmd`, 0 model tokens). So the corpus gives us deterministic
over-fire detection on every candidate rule for free. The binding constraint here is the token
bucket (see `docs/05`), and burn is ~100% rule-gen with ~92% re-sent context — so the goal is
to extract this signal **without** spending agent turns on it.

## Decision (2026-06-13): BLOCK-AT-GATE, not auto-fix
Maintainer's call. Keep the full `mix test` (corpus included) as the **always-on enforcer** so
"stupid rules" can't land; when a corpus finding makes the suite red, **escalate** for the
maintainer to either **DROP** the rule or **ACCEPT + whitelist** (re-pin the snapshot).

Explicitly rejected alternatives:
- **Exclude corpus from the Gate** + run it in a separate harness loop that feeds NEW findings
  back as bugfix tasks. Rejected: loses the free block-at-commit (bad rules would briefly land
  on `evolution`) and adds a second rule-gen pass for self-inflicted over-fires.
- **Auto-repin GONE diffs / auto-fix NEW diffs.** Rejected: re-pinning and dropping are
  product calls the maintainer wants to make by hand ("drop or accept + whitelist").

## Two effects

### Lever 1 — the agent runs FOCUSED tests only (token saving)
The rule-gen agent must never run the full `mix test`. The token-free Gate is the single
full-suite enforcer; the agent re-running it dumps the (now corpus-laden) suite output into its
context, which is re-sent on every subsequent turn (the ~92% re-send cost). Enforced in:
- `lib/tunex/implement/seed.ex` — the **live** Router→Implement agent task (`mix test <focused>`
  only, with an explicit "do NOT run the full `mix test`" rule).
- `lib/tunex/evolve/credence_rule_generator.ex` — the dormant pre-rebuild generator prompt
  (kept consistent).

The live path already ran focused tests; the explicit wording prevents a future prompt edit
from regressing it. The dormant generator had the actual `then run the full mix test ONCE`
instruction, now removed.

### Corpus-aware, actionable Gate rejects
`lib/tunex/evolve/corpus.ex` — deterministic, 0-token:
- `classify_failure/1` — returns `nil` when any **non-corpus** test is red (`mix test --exclude
  corpus` ≠ 0 → a genuinely broken rule, ordinary `:full_suite_red`). Otherwise the failure is
  corpus-only; it computes the snapshot `delta/1` and tags:
  - `:over_fire` — NEW findings present (rule fires on real code → DROP);
  - `:narrowing` — only GONE findings (rule no longer fires → ACCEPT means re-pinning);
  - `:unknown` — corpus red with no clean snapshot drift (investigate).
- `delta/1` — regenerates the snapshot via `mix credence.corpus --update-snapshot`, diffs it
  against the on-disk (committed) snapshot, then **restores the original file** (never mutates
  committed state). Pure helpers `diff/2` + `findings/1` are unit-tested
  (`test/tunex/corpus_test.exs`).
- `persist_reject/2` — for a `{:corpus, …}` reject, writes to `var/run/logs/escalated/`:
  - `<index>.patch` — the agent's full staged diff, **preserved instead of discarded**
    (the Gate otherwise `reset --hard`s the tree), so ACCEPT = `git apply` it;
  - `<index>.corpus.md` — the NEW/GONE finding lists + exact drop-or-accept commands.
  Returns a **compact** reason (patch/finding bodies stripped) so the ledger + outcome stay
  small.

`Gate.check_full_suite/1` captures the staged patch **before** classification (which touches
the snapshot file), then returns `{:reject, {:corpus, kind, %{new, gone, patch}}}` or plain
`{:reject, :full_suite_red}`. The live `Router.gate/3` (and the dormant generator) calls
`Corpus.persist_reject/2` on the reject branch.

## Maintainer workflow on a corpus reject
Read `var/run/logs/escalated/<index>.corpus.md`. Then either:
- **DROP** — do nothing; the tree was already reset to HEAD.
- **ACCEPT + whitelist**:
  ```
  cd ../credence
  git apply <path>/<index>.patch
  mix credence.corpus --update-snapshot   # re-pin the accepted findings
  mix test                                # confirm green
  ```

## Cost / behavior notes
- `classify_failure/1` runs an extra `mix test --exclude corpus` + `--update-snapshot` on the
  clone, but **only on a reject** (rare), deterministically, with **0 model tokens**.
- `corpus/` (the fetched package sources) is gitignored, so the Gate's `git clean -fd` (no
  `-x`) does NOT wipe it; `over_firing_test.exs` `setup_all` fetches once. No fetch churn.
- The Gate's mutation check still runs focused tests only — corpus never runs there.

## Files
- `lib/tunex/evolve/corpus.ex` — new (classifier + snapshot delta + reject persistence).
- `lib/tunex/evolve/gate.ex` — `check_full_suite` classifies the reject; `staged_patch`.
- `lib/tunex/evolve/router.ex` — live reject branch calls `Corpus.persist_reject/2`.
- `lib/tunex/evolve/credence_rule_generator.ex` — dormant generator kept consistent.
- `lib/tunex/implement/seed.ex` — focused-tests-only wording (lever 1).
- `test/tunex/corpus_test.exs` — unit tests for `diff/2` + `findings/1`.
