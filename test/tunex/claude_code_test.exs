defmodule Tunex.ClaudeCodeTest do
  use ExUnit.Case, async: true
  alias Tunex.ClaudeCode

  describe "parse_decision/3" do
    test "no_opportunity" do
      text = "I looked around.\nDECISION: no_opportunity"
      assert ClaudeCode.parse_decision(text, "success", false) == :no_opportunity
    end

    test "gave_up with detail" do
      text = "DECISION: gave_up: sort then reverse — Enum.sort(x) |> Enum.reverse()"
      assert {:gave_up, detail} = ClaudeCode.parse_decision(text, "success", false)
      assert detail =~ "sort then reverse"
    end

    test "rule proposal" do
      text = "Added a rule.\nDECISION: add NoSortThenReverse pattern rule"
      assert {:rule_proposal, line} = ClaudeCode.parse_decision(text, "success", false)
      assert line =~ "NoSortThenReverse"
    end

    test "max-turns subtype overrides to gave_up" do
      text = "DECISION: add a rule"
      assert {:gave_up, "max turns reached"} =
               ClaudeCode.parse_decision(text, "error_max_turns", false)
    end

    test "num_turns >= max overrides to gave_up" do
      assert {:gave_up, "max turns reached"} =
               ClaudeCode.parse_decision("DECISION: no_opportunity", "success", true)
    end

    test "missing DECISION line is gave_up" do
      assert {:gave_up, _} = ClaudeCode.parse_decision("no decision here", "success", false)
    end
  end
end
