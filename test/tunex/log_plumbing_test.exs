defmodule Tunex.LogPlumbingTest do
  use ExUnit.Case, async: true

  alias Tunex.{AppliedRules, Distill, RulePaths}

  describe "Distill.distill/1" do
    test "drops everything above the SOLVE_BOUNDARY sentinel" do
      log = """
      python source here
      translate output
      reference solution
      ===SOLVE_BOUNDARY===
      [Solve attempt 1] generating
      APPLIED_RULES: [{Credence.Pattern.Foo, 1}]
      """

      out = Distill.distill(log)
      refute out =~ "reference solution"
      refute out =~ "python source"
      assert out =~ "[Solve attempt 1]"
      assert out =~ "APPLIED_RULES"
    end

    test "returns the whole log when the sentinel is absent (graceful)" do
      log = "no boundary here\njust text"
      assert Distill.distill(log) == log
    end
  end

  describe "AppliedRules.parse/1" do
    test "parses counts and :reverted across multiple attempts, un-deduped" do
      log = """
      [Solve attempt 1]
      APPLIED_RULES: [{Credence.Semantic.UnusedVariable, 1}, {Credence.Pattern.NoSortThenAt, 2}]
      [Solve attempt 2]
      APPLIED_RULES: [{Credence.Pattern.NoSortThenAt, :reverted}]
      """

      entries = AppliedRules.parse(log)

      assert {:"Elixir.Credence.Semantic.UnusedVariable", 1} in entries
      assert {:"Elixir.Credence.Pattern.NoSortThenAt", 2} in entries
      assert {:"Elixir.Credence.Pattern.NoSortThenAt", :reverted} in entries
      assert length(entries) == 3
    end

    test "empty APPLIED_RULES yields no entries" do
      assert AppliedRules.parse("APPLIED_RULES: []") == []
    end

    test "reverted/1 extracts only :reverted culprits" do
      entries = AppliedRules.parse("APPLIED_RULES: [{Credence.Pattern.A, 1}, {Credence.Pattern.B, :reverted}]")
      assert AppliedRules.reverted(entries) == [:"Elixir.Credence.Pattern.B"]
    end

    test "modules/1 is the unique closed set" do
      entries = AppliedRules.parse("""
      APPLIED_RULES: [{Credence.Pattern.A, 1}]
      APPLIED_RULES: [{Credence.Pattern.A, 2}, {Credence.Pattern.C, 1}]
      """)

      assert Enum.sort(AppliedRules.modules(entries)) ==
               Enum.sort([:"Elixir.Credence.Pattern.A", :"Elixir.Credence.Pattern.C"])
    end
  end

  describe "RulePaths.resolve/2" do
    setup do
      # A tiny fake clone tree with one rule + its split tests.
      clone = Path.join(System.tmp_dir!(), "tunex_rulepaths_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(clone, "lib/pattern"))
      File.mkdir_p!(Path.join(clone, "test/pattern"))
      File.write!(Path.join(clone, "lib/pattern/no_foo.ex"), "defmodule Credence.Pattern.NoFoo do\nend\n")
      File.write!(Path.join(clone, "test/pattern/no_foo_check_test.exs"), "x")
      File.write!(Path.join(clone, "test/pattern/no_foo_fix_test.exs"), "x")
      on_exit(fn -> File.rm_rf!(clone) end)
      %{clone: clone}
    end

    test "resolves a module to its source + test glob", %{clone: clone} do
      assert {:ok, r} = RulePaths.resolve(:"Elixir.Credence.Pattern.NoFoo", clone)
      assert r.phase == "pattern"
      assert r.rule_path == "lib/pattern/no_foo.ex"
      assert "test/pattern/no_foo_check_test.exs" in r.test_paths
      assert "test/pattern/no_foo_fix_test.exs" in r.test_paths
    end

    test "errors on a module with no source file", %{clone: clone} do
      assert {:error, {:not_found, _}} = RulePaths.resolve(:"Elixir.Credence.Pattern.Ghost", clone)
    end
  end
end
