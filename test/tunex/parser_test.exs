defmodule Tunex.ParserTest do
  use ExUnit.Case, async: true
  alias Tunex.Parser

  doctest Tunex.Parser

  describe "parse_translate/1" do
    test "parses instruction + test + reference" do
      content = """
      ---INSTRUCTION---
      Implement palindrome?/1.
      ---TEST---
      defmodule SolutionTest do
        use ExUnit.Case
        test "x", do: assert Solution.palindrome?("aba")
      end
      ---REFERENCE---
      defmodule Solution do
        def palindrome?(s), do: s == String.reverse(s)
      end
      ---END---
      """

      assert {:ok, instruction, test, reference} = Parser.parse_translate(content)
      assert instruction =~ "palindrome?"
      assert test =~ "Solution.palindrome?"
      assert reference =~ "def palindrome?"
    end

    test "rejects missing reference" do
      content = """
      ---INSTRUCTION---
      x
      ---TEST---
      y
      ---END---
      """

      assert :error = Parser.parse_translate(content)
    end
  end

  describe "parse_module_test/1" do
    test "parses marker form" do
      content = "---MODULE---\ndefmodule Solution do\n  def f, do: 1\nend\n---TEST---\ndefmodule SolutionTest do\n  use ExUnit.Case\nend\n---END---"
      assert {:ok, mod, test} = Parser.parse_module_test(content)
      assert mod =~ "def f"
      assert test =~ "use ExUnit.Case"
    end

    # Regression: on retries the model drops the ---MODULE---/---TEST--- markers
    # and emits two bare defmodules. Must still parse (else valid fixes are lost).
    test "falls back to bare two-module output (no markers)" do
      content = """
      defmodule Solution do
        def convert(str, num_rows) when num_rows >= byte_size(str), do: str
        def convert(str, _num_rows), do: str
      end

      defmodule SolutionTest do
        use ExUnit.Case, async: false

        test "convert with one row" do
          assert Solution.convert("A", 1) == "A"
        end
      end
      """

      assert {:ok, mod, test} = Parser.parse_module_test(content)
      assert mod =~ "def convert"
      assert mod =~ "byte_size"
      refute mod =~ "defmodule SolutionTest"
      assert test =~ "use ExUnit.Case"
      assert test =~ "Solution.convert"
    end

    test "returns :error when only a module is present" do
      assert :error = Parser.parse_module_test("defmodule Solution do\n  def f, do: 1\nend")
    end
  end

  describe "strip_outer_fences/1 (docs/10 Fix 2)" do
    test "removes a single outer ```lang fence" do
      assert Parser.strip_outer_fences("```elixir\ndefmodule A do\nend\n```") == "defmodule A do\nend"
    end

    test "removes a bare ``` fence" do
      assert Parser.strip_outer_fences("```\nx\n```") == "x"
    end

    test "no-op when there is no fence" do
      assert Parser.strip_outer_fences("defmodule A do\nend") == "defmodule A do\nend"
    end

    test "preserves a mid-content fence (only the FIRST/LAST are stripped)" do
      s = "defmodule A do\n  @moduledoc \"x\\n```\\ny\"\nend"
      assert Parser.strip_outer_fences(s) == s
    end
  end

  describe "fix_is_prefix/3" do
    test "renames is_foo to foo? in module and test when canonical is a predicate" do
      mod = "defmodule Solution do\n  def is_palindrome(s), do: s == String.reverse(s)\nend"
      test = "assert Solution.is_palindrome(\"aba\")"

      {fixed_mod, fixed_test, renamed?} = Parser.fix_is_prefix(mod, test, "is_palindrome")

      assert renamed?
      assert fixed_mod =~ "def palindrome?("
      refute fixed_mod =~ "def is_palindrome"
      assert fixed_test =~ "Solution.palindrome?("
    end

    test "no-op when entry point is not a predicate" do
      mod = "defmodule Solution do\n  def missing_number(l), do: l\nend"
      {m, t, renamed?} = Parser.fix_is_prefix(mod, "t", "missing_number")
      refute renamed?
      assert m == mod
      assert t == "t"
    end
  end
end
