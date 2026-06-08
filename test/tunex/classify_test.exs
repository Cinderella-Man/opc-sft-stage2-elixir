defmodule Tunex.ClassifyTest do
  use ExUnit.Case, async: true

  alias Tunex.{Classify, Markers}
  alias Tunex.Classify.{Parser, Prompt, Spec}

  describe "Markers.split/1" do
    test "splits keyed sections, drops END, keeps path keys" do
      text = """
      ===RULE===
      defmodule Foo do
      end
      ===TEST:test/pattern/foo_test.exs===
      assert true
      ===END===
      """

      sections = Markers.split(text)
      assert {"RULE", "defmodule Foo do\nend"} in sections
      assert {"TEST:test/pattern/foo_test.exs", "assert true"} in sections
      refute Enum.any?(sections, fn {k, _} -> k == "END" end)
    end
  end

  describe "Parser.parse/1" do
    test "parses a POTENTIAL_NEW_RULE spec with assumptions" do
      text = """
      ===DECISION===
      POTENTIAL_NEW_RULE
      ===PROPOSED_NAME===
      prefer_map_put_new
      ===PHASE===
      pattern
      ===BEFORE===
      defmodule Bad do
        def run(s), do: String.to_charlist(s) == Enum.reverse(String.to_charlist(s))
      end
      ===AFTER===
      defmodule Good do
        def run(s), do: s == String.reverse(s)
      end
      ===ASSUMPTIONS===
      single_codepoint_graphemes
      ===RATIONALE===
      codepoint palindrome is grapheme-safe under the promise
      ===END===
      """

      assert {:ok, %Spec{} = s} = Parser.parse(text)
      assert s.decision == :potential_new_rule
      assert s.proposed_name == "prefer_map_put_new"
      assert s.phase == :pattern
      assert s.assumptions == [:single_codepoint_graphemes]
      assert s.before =~ "String.to_charlist"
      assert s.after =~ "String.reverse"
    end

    test "BUGFIX rule_name becomes a module atom" do
      text = """
      ===DECISION===
      BUGFIX_RULE
      ===RULE_NAME===
      Credence.Pattern.NoSortThenAt
      ===PHASE===
      pattern
      ===BEFORE===
      defmodule B do
      end
      ===AFTER===
      defmodule B2 do
      end
      ===RATIONALE===
      over-fires
      ===END===
      """

      assert {:ok, s} = Parser.parse(text)
      assert s.decision == :bugfix_rule
      assert s.rule_name == :"Elixir.Credence.Pattern.NoSortThenAt"
    end

    test "rejects an unknown decision" do
      assert {:error, {:bad_decision, "MAYBE"}} = Parser.parse("===DECISION===\nMAYBE\n===END===")
    end
  end

  describe "Prompt" do
    test "system prompt is compact; canonical blocks injected verbatim" do
      reg = [%{name: :single_codepoint_graphemes, default: true, summary: "single-codepoint chars"}]

      user =
        Prompt.build(
          distilled_log: "[Solve attempt 1] ...",
          closed_set: [:"Elixir.Credence.Pattern.Foo"],
          ledger: "",
          assumptions: reg,
          solve_outcome: :solved
        )

      assert user =~ Prompt.type_change_block()
      assert user =~ Prompt.adversarial_block()
      assert user =~ "single_codepoint_graphemes (default true)"
      assert user =~ "BUGFIX_RULE"
      assert user =~ "succeeded" or user =~ "SUCCEEDED"
    end

    test "option-shaping: empty closed set drops BUGFIX" do
      assert "BUGFIX_RULE" not in Prompt.offered_decisions([])
      assert "BUGFIX_RULE" in Prompt.offered_decisions([:"Elixir.Foo"])
    end

    test "failed lens differs from solved lens" do
      base = [distilled_log: "x", closed_set: [], ledger: "", assumptions: []]
      solved = Prompt.build([{:solve_outcome, :solved} | base])
      failed = Prompt.build([{:solve_outcome, :failed} | base])
      assert solved =~ "SUCCEEDED"
      assert failed =~ "FAILED"
    end
  end

  describe "Classify.run/3 validation gates (injected LLM)" do
    defp llm_returning(text), do: fn _u, _s -> {:ok, text, %{}} end

    setup do
      # avoid shelling for the registry
      Tunex.Credence.put_assumptions([%{name: :single_codepoint_graphemes, default: true, summary: "x"}])
      :ok
    end

    test "valid NO_ACTION passes" do
      out = "===DECISION===\nNO_ACTION\n===RATIONALE===\nidiomatic\n===END==="
      assert {:ok, %Spec{decision: :no_action}} = Classify.run("log", :solved, llm: llm_returning(out), closed_set: [], ledger: "")
    end

    test "POTENTIAL_NEW_RULE with a missing after is rejected then errors after re-ask" do
      out = """
      ===DECISION===
      POTENTIAL_NEW_RULE
      ===PROPOSED_NAME===
      no_foo
      ===PHASE===
      pattern
      ===BEFORE===
      defmodule Bad do
      end
      ===RATIONALE===
      x
      ===END===
      """

      assert {:error, {:classifier_errors, :missing_after, _}} =
               Classify.run("log", :solved, llm: llm_returning(out), closed_set: [], ledger: "")
    end

    test "unknown assumption is rejected" do
      out = """
      ===DECISION===
      POTENTIAL_NEW_RULE
      ===PROPOSED_NAME===
      no_foo
      ===PHASE===
      pattern
      ===BEFORE===
      defmodule Bad do
        def f(x), do: x
      end
      ===AFTER===
      defmodule Good do
        def f(x), do: x + 0
      end
      ===ASSUMPTIONS===
      made_up_switch
      ===RATIONALE===
      x
      ===END===
      """

      assert {:error, {:classifier_errors, {:unknown_assumptions, [:made_up_switch]}, _}} =
               Classify.run("log", :solved, llm: llm_returning(out), closed_set: [], ledger: "")
    end

    test "a decision not in the offered set is rejected (BUGFIX with empty closed set)" do
      out = "===DECISION===\nBUGFIX_RULE\n===RULE_NAME===\nCredence.Pattern.Foo\n===END==="

      assert {:error, {:classifier_errors, {:decision_not_offered, :bugfix_rule}, _}} =
               Classify.run("log", :solved, llm: llm_returning(out), closed_set: [], ledger: "")
    end
  end
end
