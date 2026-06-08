defmodule Tunex.EquivTest do
  use ExUnit.Case, async: true

  alias Tunex.Equiv

  describe "extract/1" do
    test "pulls vars + body from a single-clause def" do
      src = """
      defmodule Bad do
        def run(s), do: String.to_charlist(s) == Enum.reverse(String.to_charlist(s))
      end
      """

      assert {:ok, ["s"], expr} = Equiv.extract(src)
      assert expr =~ "String.to_charlist(s)"
    end

    test "handles a guarded multi-arg def" do
      src = """
      defmodule Bad do
        def run(a, b) when is_list(a), do: a ++ b
      end
      """

      assert {:ok, ["a", "b"], "a ++ b"} = Equiv.extract(src)
    end

    test "returns :error for pattern-destructured params (T2 — not extractable)" do
      src = """
      defmodule Bad do
        def run(%{k: v}), do: v
      end
      """

      assert Equiv.extract(src) == :error
    end

    test "returns :error for non-module / unparseable input" do
      assert Equiv.extract("def x(") == :error
      assert Equiv.extract(nil) == :error
    end
  end

  describe "check/2 (real clone — integration)" do
    @describetag :integration

    test "DIVERGES on a charlist-int vs grapheme-string rewrite" do
      spec = %Tunex.Classify.Spec{
        decision: :potential_new_rule,
        before: "defmodule B do\n  def run(s), do: Enum.at(String.to_charlist(s), 0)\nend",
        after: "defmodule A do\n  def run(s), do: String.at(s, 0)\nend",
        assumptions: []
      }

      assert {:diverges, _} = Equiv.check(spec)
    end

    test "REPAIR on Keyword.get with an integer key" do
      spec = %Tunex.Classify.Spec{
        decision: :potential_new_rule,
        before: "defmodule B do\n  def run(list), do: Keyword.get(list, 0)\nend",
        after: "defmodule A do\n  def run(list), do: List.first(list)\nend",
        assumptions: []
      }

      assert {:repair, _} = Equiv.check(spec)
    end

    test "EQUIVALENT with a minimal switch set on a codepoint palindrome" do
      spec = %Tunex.Classify.Spec{
        decision: :potential_new_rule,
        before:
          "defmodule B do\n  def run(s), do: String.to_charlist(s) == Enum.reverse(String.to_charlist(s))\nend",
        after: "defmodule A do\n  def run(s), do: s == String.reverse(s)\nend",
        assumptions: []
      }

      assert {:equivalent, [:single_codepoint_graphemes]} = Equiv.check(spec)
    end

    test "skips a T2 (pattern-param) rewrite" do
      spec = %Tunex.Classify.Spec{
        decision: :potential_new_rule,
        before: "defmodule B do\n  def run(%{a: a}), do: a\nend",
        after: "defmodule A do\n  def run(m), do: m.a\nend",
        assumptions: []
      }

      assert Equiv.check(spec) == :skipped
    end
  end
end
