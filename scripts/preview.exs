# mix run scripts/preview.exs [--think]

alias Tunex.{LLM, Parser, Workspace, Validator, Report}

thinking? = "--think" in System.argv()
max_tokens = if thinking?, do: 16_384, else: 12_288

examples = [
  %{instruction: "Write a python function to find the missing number in a given list of integers that contains n distinct numbers taken from 0, 1, 2, ..., n.",
    code: "def missing_number(nums):\n    n = len(nums)\n    total = n * (n + 1) // 2\n    return total - sum(nums)",
    entry_point: "missing_number",
    tests: ["assert missing_number([9,6,4,2,3,5,7,0,1]) == 8", "assert missing_number([0, 1]) == 2"]},
  %{instruction: "Write a python function to check if a given string is a palindrome, considering only alphanumeric characters and ignoring cases.",
    code: "def is_palindrome(s: str) -> bool:\n    s = ''.join([c.lower() for c in s if c.isalnum()])\n    return s == s[::-1]",
    entry_point: "is_palindrome",
    tests: [~s|assert is_palindrome("A man, a plan, a canal: Panama") == True|, ~s|assert is_palindrome("race a car") == False|]},
  %{instruction: "Write a function to find the length of the longest substring without repeating characters.",
    code: "def length_of_longest_substring(s):\n    char_map = {}\n    left = max_length = 0\n    for right in range(len(s)):\n        if s[right] in char_map:\n            left = max(left, char_map[s[right]] + 1)\n        char_map[s[right]] = right\n        max_length = max(max_length, right - left + 1)\n    return max_length",
    entry_point: "length_of_longest_substring",
    tests: [~s|assert length_of_longest_substring("abcabcbb") == 3|, ~s|assert length_of_longest_substring("bbbbb") == 1|]}
]

system_prompt = ~S"""
You convert Python coding exercises into Elixir coding exercises.
Rewrite BOTH the instruction and the code. Instruction = problem description only.
Never mention Elixir functions/data structures in instruction.
Use descriptive param names. Prefix unused params with _ per clause.
Output: ---INSTRUCTION--- / ---MODULE--- / ---TEST--- / ---END---
"""

IO.puts("Tunex Preview | #{length(examples)} examples, thinking=#{thinking?}\n")
Workspace.setup("tunex_preview_workspace")
ws = "tunex_preview_workspace"
opts = [max_tokens: max_tokens]

prefix = unless thinking?, do: "/no_think\n", else: ""

for {example, i} <- Enum.with_index(examples, 1) do
  IO.puts("\n" <> String.duplicate("─", 60))
  IO.puts("Example #{i}/#{length(examples)}: #{example.entry_point}")
  IO.puts(String.duplicate("─", 60))

  tests = Enum.join(example.tests, "\n")
  prompt = """
  #{prefix}Convert this Python exercise to Elixir.
  ## Python Instruction\n#{example.instruction}
  ## Python Solution\n```python\n#{example.code}\n```
  ## Python Tests\n#{tests}
  Function: `#{example.entry_point}`
  Output: ---INSTRUCTION--- / ---MODULE--- / ---TEST--- / ---END---
  """

  case LLM.call(prompt, system_prompt, opts) do
    {:ok, content} ->
      case Parser.parse_full(content) do
        {:ok, instruction, module_code, test_code} ->
          {failures, final_mod, final_test} = Validator.run(module_code, test_code, ws)
          if failures == [] do
            IO.puts("\n✓ PASSED\n\nInstruction:\n  #{instruction}\n\nModule:\n#{final_mod}\n\nTests:\n#{final_test}")
          else
            IO.puts("\n✗ FAILED #{Report.failure_summary(failures)}")
          end
        :error ->
          IO.puts("\n✗ Could not parse output")
      end
    {:error, reason} -> IO.puts("\n✗ LLM error: #{reason}")
    {:empty, reason} -> IO.puts("\n✗ Empty: #{reason}")
  end
end

IO.puts("\n✓ Preview complete")
