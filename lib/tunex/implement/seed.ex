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

  @doc "Build the user prompt from a context map (see moduledoc / T5.1)."
  def build(ctx) do
    [
      header(ctx),
      spec_block(ctx),
      scaffold_block(ctx),
      ast_block(ctx),
      diagnostic_block(ctx),
      bugfix_block(ctx),
      invariants_block(),
      conventions_block(),
      assumptions_block(ctx),
      repair_block(ctx),
      output_contract(ctx)
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n\n")
  end

  # ── Sections ─────────────────────────────────────────────────────────────

  defp header(%{mode: :new, phase: phase}),
    do: "## Task: implement a NEW #{phase} rule by filling the generated stubs."

  defp header(%{mode: :bugfix, bugfix: %{sub_shape: shape}}),
    do: "## Task: FIX an existing rule (#{shape}). Edit it + its tests in place."

  defp spec_block(%{spec: s}) do
    """
    ## Spec
    rationale: #{s.rationale}

    BEFORE (the offending / non-idiomatic snippet):
    #{fence(s.before)}

    AFTER (the idiomatic rewrite — fix/2 must produce this):
    #{fence(s.after)}
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
    "## Output contract (whole files)\n===RULE===\n<rule.ex>\n#{paths}\n<each test file>\n===END==="
  end

  defp contract(roles) do
    body = Enum.map_join(roles, "\n", &"===#{&1}===\n<whole file>")
    "## Output contract (whole files — emit each block in full)\n#{body}\n===END==="
  end

  defp fence(content), do: "```\n#{String.trim_trailing(content || "")}\n```"
end
