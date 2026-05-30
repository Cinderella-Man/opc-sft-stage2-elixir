defmodule Tunex.Pipeline.SolveTest do
  use ExUnit.Case, async: true
  alias Tunex.Pipeline.Solve

  # M6 item 2 / T3.4 guard: the Solve stage is Python-blind. The assembled
  # initial + retry + system prompts must never contain a ```python fence, the
  # word "python", or the row's Python source.
  @python_source ~S"""
  def is_palindrome(s):
      return s == s[::-1]
  """

  @instruction "Implement palindrome?/1 which returns true for palindromes."
  @test "defmodule SolutionTest do\n  use ExUnit.Case\n  test \"x\", do: assert Solution.palindrome?(\"aba\")\nend"

  test "initial prompt is Python-free" do
    prompt = Solve.build_initial(@instruction, @test, "palindrome?")
    assert_python_free(prompt)
    assert prompt =~ "palindrome?"
    assert prompt =~ "Solution"
  end

  test "retry prompt is Python-free" do
    failures = [{:compile, "boom"}, {:credence, "[warning] foo: bar"}]
    prompt = Solve.build_retry("previous elixir output", failures, "palindrome?")
    assert_python_free(prompt)
  end

  test "system prompt is Python-free" do
    assert_python_free(Solve.system_prompt())
  end

  defp assert_python_free(text) do
    down = String.downcase(text)
    refute String.contains?(down, "```python")
    refute String.contains?(down, "python")
    refute String.contains?(text, @python_source)
    refute String.contains?(text, "is_palindrome")
  end
end
