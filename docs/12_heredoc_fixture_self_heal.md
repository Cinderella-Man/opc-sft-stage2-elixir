# 12 — Self-heal plain-string fixtures → heredocs (in Credence), stop escalating genuine rules

## STATUS (updated)
**§A (Credence) is IMPLEMENTED** — and the convention evolved past this doc's first draft. Credence shipped
the **3-form fixture convention** + a newline-insensitive `confirm_fix/2` fix-test helper + the self-heal,
wired into `credence/test/test_helper.exs` (`heal_dirs/0` runs before the suite compiles, on every
`mix test`). See Credence's own `docs/10`. Net rule:

| fixture value | canonical form |
|---|---|
| no newline, no `"` | `"foo"` (plain) |
| no newline, has `"` | `~S'foo "bar"'` (single-quote sigil) |
| has a newline | `"""…"""` heredoc |

Fix tests use `confirm_fix(fix(R, input), expected)` (trims trailing `\n` both sides), not `assert == `.

**Harness (Tunex): NOTHING is required for correctness.** The Credence heal is in `test_helper.exs`, so it
fires inside Tunex's `focused_test` AND the Gate's full `mix test` — both heal before compile, and the Gate
stages the canonical files. Whatever fixture form the model emits gets normalized locally (0 tokens); the
healer's ordering rule keeps a non-rewritable `==` paired with heredocs, so byte-equality never breaks.
`implement.ex`'s `mix credence.fix_tests` / `credence.normalize_tests` calls are unchanged Credence tasks
(`fix_tests` now also matches `confirm_fix`; `normalize_tests` is assertion-agnostic).

**Remaining harness work = §B only, prompt-only, OPTIONAL (quality, not correctness):** update `seed.ex`'s
two now-stale `conventions_block` lines (they contradict the new gates) + add the syntax parser-fix nudge.

## Context
`escalated/` review: **every** escalated case was a *genuine, useful* (mostly syntax) Credence rule,
rejected **solely** because the rule-writer wrote test fixtures as plain `"..."` strings instead of
`"""` heredocs. (2 also used line/text `fix` heuristics — see Tunex §B.)

Mechanism (confirmed end-to-end):
- Credence convention = every code fixture is a `"""` heredoc, enforced by meta-test
  `credence/test/fixture_string_escaping_test.exs` (walks each test file's AST via Sourceror; fails if any
  fixture-position node isn't a heredoc). Authority = `Credence.MetaTestSupport.fixtures/1` + `fixture_ok?/1`
  (`test/support/meta_test_support.ex:277-371`) + the `@allow` list in the meta-test.
- That meta-test runs in Credence's default `mix test`.
- Tunex's **Gate** (`lib/tunex/evolve/gate.ex` check (a)) runs the full `mix test` (free, 0 tokens) → a
  plain-string fixture → meta-test RED → suite RED → genuine rule rejected → `escalated/`.
- The plain→heredoc rewrite is **mechanical/deterministic**. The fix belongs **in Credence** (user
  direction): a Tunex pre-Gate step is insufficient because the agentic rule-writer (`:pi`/`:cc` driver)
  runs `mix test` mid-loop, hits the meta-test, and loops forever fighting it. Credence must self-heal so
  *any* `mix test` (agent loop, implementer `focused_test`, Gate full suite) fixes the fixtures itself.

Decision: **keep the meta-test; add a deterministic self-heal that runs before the suite compiles.** Genuine
rules stop getting rejected; the un-convertible residue still fails the meta-test → escalates ("only the
non-fixable ones raise errors").

## A. Credence (`/home/car/projects/credence`) — the core fix  *(ORIGINAL DRAFT — superseded by STATUS above; see Credence `docs/10` for what shipped: 3-form convention + `confirm_fix/2`)*
1. **`lib/test_fixtures.ex`** (new, `Credence.TestFixtures`): move the pure predicates out of
   `MetaTestSupport` — `fixtures/1`, `fixture_ok?/1`, `stringish?`, `verb_call?`, `verb_fixtures`,
   `multiline_interp?`, `@verbs`, `@fvars` — **and the `@allow` allow-list**. Add:
   - `heal_source(src) -> {healed_src, residue_count}` — pure: `Sourceror.parse_string!` → for each node in
     `fixtures(ast)` that is `not fixture_ok?` **and convertible**, rewrite to a `"""` heredoc. Convertible
     = plain double-quoted string and `<>`-of-string-literals (fold → one heredoc). Leave (→ residue):
     content containing `"""` (can't nest), `<>` with a non-literal leaf, sigils. Render via the established
     `lib/pattern/*` idiom — `Sourceror.get_range` + `Sourceror.patch_string` with a built heredoc string
     (indented to the node's column), or flip the node's `:delimiter` meta to `"""` and re-render; **verify
     the chosen rendering yields a valid heredoc on Sourceror 1.11**. Fix-test `input`/`expected` convert in
     the same pass (paired trailing `\n` → value-preserving).
   - `heal_file(path)` / `heal_dirs()` over `test/{pattern,semantic,syntax}` — **honor `@allow`** (never
     touch the 2 allow-listed files' fixtures; converting them breaks them, which is why they're listed).
   - `MetaTestSupport` + `fixture_string_escaping_test.exs` `defdelegate`/import from this module (single
     source of truth preserved; meta-test behaviour unchanged — now it only fails on the residue).
   *Why `lib/`:* `elixirc_paths(:test)=["lib","test/support"]`, so test-only support can't be reached from a
   pre-suite hook reliably; these predicates describe the convention and belong with `RuleName`/`RuleScaffold`.

2. **Self-heal hook before the suite compiles** — add `Credence.TestFixtures.heal_dirs()` to
   `test/test_helper.exs` (runs first on every `mix test`, before test `.exs` files are required, so the
   rule tests compile against the healed fixtures → fully consistent; idempotent; no-op when already
   heredoc). *(Alternative: a `test` alias `["credence.fixtures.heal", "test"]` + a thin
   `mix credence.fixtures.heal` task — same effect, larger footprint. Recommend test_helper.exs.)*
   Footprint note: every `mix test` now parses the rule test files first (~hundreds ms; mutates only when a
   non-heredoc fixture exists). Optional cheap pre-filter to skip obviously-clean files.

3. **Keep `fixture_string_escaping_test.exs`** as the residue arbiter (heals run first → it fails only on
   genuinely non-convertible fixtures → the correct escalation signal).

4. **Tests:** converter unit tests (plain string → heredoc; `input`/`expected` pair both convert;
   `<>`-with-var left; `"""`-containing left; allow-listed file untouched); a test that plants a plain-string
   fixture in a temp rule test, runs `mix test` (or `heal_dirs`), and asserts it self-heals + the meta-test
   passes; full suite stays green.

Net for the heredoc bug: **no Tunex change** — once the clone self-heals, the implementer's `focused_test`,
the agent's own `mix test`, and the Gate's full suite all heal before they run; the Gate's `git add -A`
stages the already-heredoc files, so the committed rule is clean. Worst case of a value-changing heal (a
newline-sensitive rule) → that rule's own test goes red in the same run → Gate rejects (never commits red).

## B. Tunex (`/home/car/projects/opc-sft-stage2-elixir`) — prompt nudge (OPTIONAL, quality only)
The Credence self-heal makes this unnecessary for correctness; it's worth doing only so the prompt stops
contradicting the new gates and to improve generated-`fix` quality. In `lib/tunex/implement/seed.ex`:
- **Fix the two stale `conventions_block` lines** (`seed.ex:197,200`):
  - `:197` "Fix tests compare the WHOLE output with `==`" → "Fix tests use
    `confirm_fix(fix(R, input), expected)` (newline-insensitive)" — keep the bans on `=~`/`String.contains?`/
    `match?`/`starts_with?`/split-slice.
  - `:200` "Heredocs only for code/expected (no `\n` escapes)" → the **3-form convention** above: single-line
    value → plain `"foo"` (or `~S'foo "x"'` if it contains `"`); multi-line value → `"""…"""` heredoc. Never
    a single-content-line heredoc.
- Add a phase-conditional `syntax_fix_block` injected when `phase: :syntax`, slotted into the `build/1`
  section list (`seed.ex:47-59`, e.g. after `invariants_block()`): for syntax rules, locate the fault with
  the parser's error structure (`Code.string_to_quoted/2` → `{:error, {meta, msg, token}}` line/column, or
  Sourceror's fault-tolerant parse) rather than `String.split("\n")` line/text heuristics.
Prompt-only; no logic change. The healer remains the safety net if the model ignores it.

## Verification
- Credence: `mix test` green (meta-test + new converter unit tests). Manual: plant a plain-string fixture in
  a `test/pattern/*_test.exs`, run `mix test <file>` → assert it's now a `"""` heredoc and the meta-test
  passes; a `<>`-with-var fixture stays and the meta-test still flags it; an `@allow` file is untouched.
- Tunex: `mix test`. End-to-end smoke: a Credence clone with a rule whose fixtures are plain strings →
  `mix test` in the clone self-heals + passes (proves no agent loop + Gate would accept).

## Open question
1. Self-heal hook via `test/test_helper.exs` (recommended) or a `test` alias + `mix credence.fixtures.heal`
   task? (Same effect; test_helper.exs is smaller-footprint.)
