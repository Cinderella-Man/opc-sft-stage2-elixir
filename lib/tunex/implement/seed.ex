defmodule Tunex.Implement.Seed do
  @moduledoc """
  Build the implementer seed prompt (07 §5.0/§5.3/§5.6; 08 T5.1).

  The seed supplies everything the old agent used to *explore* for, so the loop
  is non-agentic:

    * the **generated scaffold files** (verbatim — the exact gate-passing template
      to FILL, §5.0 step ★1b),
    * before+after **AST dumps** (pattern/semantic) — the Sourceror shape,
    * for semantic, the **real captured diagnostic** (T1.3b) so `match?` keys on
      a genuine compiler message,
    * for bugfix, the **offending rule's source + its tests**,
    * both verbatim §3.10 canonical blocks + the §5.6 test conventions,
    * the **repair** instruction (repair sub-mode) and the §3.12 Tier-1
      assumptions/property-test instruction (switch-gated).
  """

  alias Tunex.Classify.Prompt

  @system "You implement ONE Credence rule by FILLING generated stub files. Write `check`/`fix` " <>
            "(or analyze/fix, or match?/to_issue/fix), replace placeholder fixtures with the real " <>
            "before/after, and make the red assertions green WITHOUT weakening any test. Emit the WHOLE " <>
            "content of each file via the role/path markers — nothing else. Preserve the stub's structure."

  def system, do: @system

  # Each output block holds the RAW file body. A leading/trailing ``` fence makes
  # the file fail to compile (docs/10 Fix 2) — the output strip is the safety net,
  # this line cuts the cause (the model otherwise mirrors the seed's fenced examples).
  @no_fence "Emit each block's RAW file content — do NOT wrap it in ``` code fences."

  @doc """
  Build the user prompt from a context map (see moduledoc / T5.1).

  `opts[:driver]` selects the closing instruction (the rich context above it is
  identical either way — docs/10):
    * `:llm` (default) — the marker output-contract (single-shot: emit whole files).
    * `:pi` — an AGENT task: the stub files already exist on disk; edit them in
      place, run `mix test`, and loop until green (pi runs the loop itself).
  """
  def build(ctx, opts \\ []) do
    driver = Keyword.get(opts, :driver, :llm)

    closing = if driver == :pi, do: agent_task(ctx), else: output_contract(ctx)

    [
      header(ctx, driver),
      spec_block(ctx),
      scaffold_block(ctx),
      ast_block(ctx),
      diagnostic_block(ctx),
      bugfix_block(ctx),
      invariants_block(),
      conventions_block(),
      assumptions_block(ctx),
      repair_block(ctx),
      closing
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n\n")
  end

  # ── Sections ─────────────────────────────────────────────────────────────

  defp header(%{mode: :new, phase: phase}, :pi),
    do: "## Task: implement a NEW #{phase} Credence rule — agentic. Fill the generated stub files IN PLACE, run the focused tests, and loop until green."

  defp header(%{mode: :bugfix, bugfix: %{sub_shape: shape}}, :pi),
    do: "## Task: FIX an existing Credence rule (#{shape}) — agentic. Edit it + its tests in place, run the focused tests, and loop until green."

  defp header(%{mode: :new, phase: phase}, _llm),
    do: "## Task: implement a NEW #{phase} rule by filling the generated stubs."

  defp header(%{mode: :bugfix, bugfix: %{sub_shape: shape}}, _llm),
    do: "## Task: FIX an existing rule (#{shape}). Edit it + its tests in place."

  # The agentic closing instruction (replaces the marker output-contract for pi).
  # The scaffold/bugfix files are already on disk in the agent's cwd (the clone),
  # so it edits them directly and drives its own edit→test→fix loop.
  defp agent_task(%{mode: :new, scaffold: sc}),
    do: agent_task_text("test/#{sc.phase}/#{sc.snake}*_test.exs")

  defp agent_task(%{mode: :bugfix, bugfix: bf}),
    do: agent_task_text(Enum.join(Map.keys(bf.test_files), " "))

  defp agent_task(_), do: agent_task_text("test/")

  defp agent_task_text(test_target) do
    """
    ## Your task — AGENTIC (fill the stubs, then make the tests pass)
    The files shown above ALREADY EXIST on disk in your working directory. EDIT them
    in place to implement the real `check`/`fix` (and replace placeholder fixtures
    with the real before/after) — preserve the module names and file shape. Then run
    the focused tests and LOOP until every one passes:

        mix test #{test_target}

    Iterate as many times as you need: edit → run → read the failures → fix → re-run.
    YOU decide when you are done — finish only once `mix test` above is fully green.
    Rules:
    - Do NOT weaken, skip, or delete assertions to make them pass. Fix the rule, not the test.
    - Do NOT create new files beyond the generated stubs (bugfix: modify in place only).
    - Run ONLY the focused tests above — do NOT run the full `mix test`. A separate
      deterministic Gate runs the whole suite (including the real-world over-firing
      corpus) for you; running it yourself only burns budget re-sending its output.
    - Do NOT run git.
    """
  end

  defp spec_block(%{spec: s}) do
    """
    ## Spec
    rationale: #{s.rationale}

    BEFORE (the offending / non-idiomatic snippet):
    #{fence(s.before)}

    AFTER (the INTENDED idiomatic result — your fix should realize this):
    #{fence(s.after)}

    NOTE: before/after are a ONE-SHOT proposal and may be incomplete or fail to
    compile on their own (e.g. a helper they call isn't shown, a stray ``` fence,
    a typo). They convey the INTENDED idiom — they are NOT gospel. Your rule,
    tests, and fixtures must actually COMPILE and pass `mix test`: fix that kind of
    MECHANICAL breakage yourself instead of faithfully reproducing a broken
    snippet. Do NOT change WHAT the rule detects or the behaviour it must preserve.
    """
  end

  defp scaffold_block(%{mode: :new, scaffold_files: files}) when is_map(files) and map_size(files) > 0 do
    blocks =
      Enum.map_join(files, "\n\n", fn {path, content} ->
        "### #{path}\n#{fence(content)}"
      end)

    "## Generated scaffold (FILL these — preserve module names, file shape, the test scaffolding)\n#{blocks}"
  end

  defp scaffold_block(_), do: nil

  defp ast_block(%{phase: :syntax}), do: nil

  defp ast_block(%{ast_before: b, ast_after: a}) when is_binary(b) do
    "## AST dumps (the Sourceror tuple shape check/2 matches)\n### BEFORE\n#{fence(b)}\n### AFTER\n#{fence(a)}"
  end

  defp ast_block(_), do: nil

  defp diagnostic_block(%{phase: :semantic, real_diagnostic: d}) when is_binary(d) and d != "" do
    """
    ## REAL captured diagnostic (use VERBATIM in the test diag + key match? on it)
    #{fence(d)}
    A fabricated diagnostic passes the gate but ships a DEAD rule (the live
    pipeline feeds Code.with_diagnostics output). Copy this %{message,position,severity}.
    """
  end

  defp diagnostic_block(_), do: nil

  defp bugfix_block(%{mode: :bugfix, bugfix: bf}) do
    tests =
      Enum.map_join(bf.test_files, "\n\n", fn {path, content} ->
        "### #{path}\n#{fence(content)}"
      end)

    """
    ## Offending rule source (edit to narrow/repair)
    #{fence(bf.rule_src)}

    ## Its tests (edit IN PLACE — add the must-not-fire / regression case; no new/renamed files)
    #{tests}
    """
  end

  defp bugfix_block(_), do: nil

  defp invariants_block do
    """
    ## Behaviour preservation (HARD — §3.10)
    fix/2 must be output-identical to before for EVERY admitted input. Do NOT broaden
    the match onto a behaviour-diverging input. NO check-only escape — write a real
    fix_patches/2; if you cannot keep it safe even on a narrow core, stop (gave_up),
    do not ship a `-> []` stub.

    ### Type-change ban (verbatim)
    #{Prompt.type_change_block()}

    ### Adversarial-input checklist (self-run before emitting fix)
    #{Prompt.adversarial_block()}
    """
  end

  defp conventions_block do
    """
    ## Test conventions (§5.6 — emit reviewer-ready)
    - Fix tests compare the WHOLE output with `==` (BAN =~, String.contains?,
      match?/Regex.match?, starts_with?/ends_with?, split+Enum.at — even for negatives).
    - `expected` is the rule's REAL output (run it, copy the string), never hand-written.
    - Heredocs only for code/expected (no \\n escapes).
    - `_check` includes the deliberately-dropped unsafe cases asserted as "no issue".
    - check and fix must agree.
    - Pattern: the `_equivalence_test` calls assert_equivalent(before, rule: Rule,
      vars: [<free vars of before>], inputs: <Credence.EquivalenceInputs dimension>) —
      read the free vars off the BEFORE AST dump; it must fire + rewrite + use ≥3
      discriminating inputs and pass strict `===`.
    """
  end

  defp assumptions_block(%{minimal_set: set}) when is_list(set) and set != [] do
    """
    ## Switch-gated (§3.12 Tier 1)
    This rule is behaviour-preserving only under: #{Enum.join(set, ", ")}.
    Emit `def assumptions, do: #{inspect(set)}` AND a `<Rule>PropertyTest` from the
    shared generator for the switch (single_codepoint_string/0 or proper_list/0).
    Author NO new generator and propose NO new switch.
    """
  end

  defp assumptions_block(_), do: nil

  defp repair_block(%{repair?: true, repair_evidence: ev}) do
    """
    ## REPAIR rule (§3.10 — before is broken on every input)
    The before has NO valid output on any input (#{ev}). In the `_equivalence_test`,
    use `mark_equivalence_repair("...")` instead of assert_equivalent, with a reason
    that states the broken precondition (#{ev}).
    """
  end

  defp repair_block(_), do: nil

  defp output_contract(%{mode: :new, phase: :pattern}) do
    contract(["RULE", "CHECK_TEST", "FIX_TEST", "EQUIVALENCE_TEST", "(PROPERTY_TEST iff switch-gated)"])
  end

  defp output_contract(%{mode: :new}) do
    contract(["RULE", "CHECK_TEST (=analyze for syntax)", "FIX_TEST"])
  end

  defp output_contract(%{mode: :bugfix, bugfix: bf}) do
    paths = Map.keys(bf.test_files) |> Enum.map(&"===TEST:#{&1}===") |> Enum.join("\n")
    "## Output contract (whole files)\n#{@no_fence}\n===RULE===\n<rule.ex>\n#{paths}\n<each test file>\n===END==="
  end

  defp contract(roles) do
    body = Enum.map_join(roles, "\n", &"===#{&1}===\n<whole file>")
    "## Output contract (whole files — emit each block in full)\n#{@no_fence}\n#{body}\n===END==="
  end

  defp fence(content), do: "```\n#{String.trim_trailing(content || "")}\n```"
end
