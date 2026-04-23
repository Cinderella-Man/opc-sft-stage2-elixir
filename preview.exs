#!/usr/bin/env elixir

# Debug preview: rewrites BOTH instruction and code for Elixir
#
# Usage:
#   elixir preview.exs
#   elixir preview.exs --think

Mix.install([
  {:req, "~> 0.5"},
  {:jason, "~> 1.4"}
])

defmodule Preview do
  @llama_url "http://127.0.0.1:8080/v1/chat/completions"

  @examples [
    %{
      instruction: "Write a python function to find the missing number in a given list of integers that contains n distinct numbers taken from 0, 1, 2, ..., n. The function should have a time complexity of O(n) and space complexity of O(1).",
      code: """
      def missing_number(nums):
          n = len(nums)
          total = n * (n + 1) // 2
          sum_nums = sum(nums)
          return total - sum_nums
      """,
      entry_point: "missing_number",
      tests: [
        ~s|assert missing_number([9,6,4,2,3,5,7,0,1]) == 8|,
        ~s|assert missing_number([0, 1]) == 2|,
        ~s|assert missing_number([3, 0, 1]) == 2|
      ]
    },
    %{
      instruction: "Write a python function to find the maximum product of two integers in a given list of positive integers.",
      code: """
      def max_product(nums):
          nums.sort()
          return max(nums[0] * nums[1], nums[-1] * nums[-2])
      """,
      entry_point: "max_product",
      tests: [
        ~s|assert max_product([1, 7, 3, 4, 9, 5]) == 63|,
        ~s|assert max_product([-1, -2, -3, 1]) == 6|
      ]
    },
    %{
      instruction: "Write a function to find the length of the longest substring without repeating characters in a given string.",
      code: """
      def length_of_longest_substring(s):
          char_map = {}
          left = 0
          max_length = 0
          for right in range(len(s)):
              if s[right] in char_map:
                  left = max(left, char_map[s[right]] + 1)
              char_map[s[right]] = right
              max_length = max(max_length, right - left + 1)
          return max_length
      """,
      entry_point: "length_of_longest_substring",
      tests: [
        ~s|assert length_of_longest_substring("abcabcbb") == 3|,
        ~s|assert length_of_longest_substring("bbbbb") == 1|
      ]
    }
  ]

  @system_prompt """
  You convert Python coding exercises into Elixir coding exercises.

  You receive a Python problem (instruction + solution + tests) and you produce
  an equivalent Elixir version where BOTH the instruction and the code are
  rewritten for Elixir.

  When rewriting the INSTRUCTION:
  - Replace all Python references with Elixir equivalents
  - Replace Python types with Elixir types: dict→map, list→list, tuple→tuple, set→MapSet, string→string
  - Replace Python concepts with Elixir ones: class→module, decorator→behaviour/macro, list comprehension→Enum/for comprehension
  - Adapt complexity requirements to make sense for Elixir's data structures (e.g. linked lists are O(n) access, not O(1); "in-place" doesn't apply to immutable data)
  - If the original says "Write a python function", say "Write an Elixir function"
  - Keep the core algorithmic problem the same
  - Do NOT mention Python at all in the rewritten instruction

  When writing the CODE:
  - Write idiomatic Elixir: pattern matching, pipe operator, guards, Enum/Stream, recursion
  - Do NOT transliterate Python line-by-line
  - Put the solution in a module
  - Include ExUnit tests matching the original assertions

  OUTPUT FORMAT — you must use exactly this structure with these exact delimiters:

  ---INSTRUCTION---
  (the rewritten Elixir instruction here)
  ---CODE---
  (the Elixir module + ExUnit tests here)
  ---END---

  Output NOTHING else. No explanations, no markdown fences, no preamble.
  """

  def run(thinking?) do
    IO.puts(bar())
    IO.puts("PREVIEW — Instruction + Code Rewrite")
    IO.puts("Thinking: #{if thinking?, do: "ON", else: "OFF"}")
    IO.puts(bar())

    case Req.get("http://127.0.0.1:8080/health") do
      {:ok, %{status: 200}} -> IO.puts("✓ llama.cpp running")
      _ -> IO.puts("✗ Cannot reach llama.cpp"); System.halt(1)
    end

    case Req.get("http://127.0.0.1:8080/v1/models") do
      {:ok, %{status: 200, body: %{"data" => [%{"id" => id} | _]}}} ->
        IO.puts("✓ Model: #{id}")
      _ -> :ok
    end

    max_tokens = if thinking?, do: 16_384, else: 4_096

    for {example, i} <- Enum.with_index(@examples, 1) do
      IO.puts("\n" <> bar())
      IO.puts("EXAMPLE #{i}/#{length(@examples)}: #{example.entry_point}")
      IO.puts(bar())

      IO.puts("\n[ORIGINAL INSTRUCTION]")
      IO.puts(example.instruction)

      user_content = build_prompt(example, thinking?)

      IO.puts("\n[SENDING] max_tokens=#{max_tokens}...")
      t0 = System.monotonic_time(:millisecond)

      body = %{
        messages: [
          %{role: "system", content: @system_prompt},
          %{role: "user", content: user_content}
        ],
        temperature: 0.3,
        max_tokens: max_tokens,
        stream: false
      }

      result = Req.post(@llama_url, json: body, receive_timeout: 600_000)
      elapsed = System.monotonic_time(:millisecond) - t0
      IO.puts("[TIMING] #{Float.round(elapsed / 1000, 1)}s")

      case result do
        {:ok, %{status: 200, body: resp}} ->
          choice = resp["choices"] |> List.first()
          msg = choice["message"]
          finish = choice["finish_reason"]
          content = (msg["content"] || "") |> String.trim()
          reasoning = (msg["reasoning_content"] || "") |> String.trim()
          usage = resp["usage"]

          IO.puts("[FINISH] #{finish}")
          if usage, do: IO.puts("[USAGE] prompt=#{usage["prompt_tokens"]} completion=#{usage["completion_tokens"]}")
          IO.puts("[CONTENT] #{String.length(content)} chars  [REASONING] #{String.length(reasoning)} chars")

          if String.length(content) > 0 do
            # Try to parse the structured output
            case parse_output(content) do
              {:ok, instruction, code} ->
                IO.puts("\n[✓ PARSED SUCCESSFULLY]")
                IO.puts("\n--- REWRITTEN INSTRUCTION ---")
                IO.puts(instruction)
                IO.puts("\n--- ELIXIR CODE ---")
                IO.puts(code)
                IO.puts("--- END ---")

              :error ->
                IO.puts("\n[⚠ COULD NOT PARSE — showing raw output]")
                IO.puts("\n--- RAW CONTENT ---")
                IO.puts(content)
                IO.puts("--- END RAW ---")
                IO.puts("\nCheck: does it contain ---INSTRUCTION--- and ---CODE--- delimiters?")
                IO.puts("  Has ---INSTRUCTION---: #{String.contains?(content, "---INSTRUCTION---")}")
                IO.puts("  Has ---CODE---: #{String.contains?(content, "---CODE---")}")
                IO.puts("  Has ---END---: #{String.contains?(content, "---END---")}")
            end
          else
            IO.puts("\n⚠️  Empty content! finish=#{finish}, reasoning=#{String.length(reasoning)} chars")
            if finish == "length" do
              IO.puts("   Model ran out of tokens (probably on thinking). Try without --think or increase budget.")
            end
          end

        {:ok, %{status: s, body: b}} ->
          IO.puts("[ERROR] HTTP #{s}: #{inspect(b, limit: 300)}")

        {:error, err} ->
          IO.puts("[ERROR] #{inspect(err)}")
      end
    end

    IO.puts("\n" <> bar())
    IO.puts("DONE")
  end

  def parse_output(content) do
    # Strip markdown fences if model wrapped the whole thing
    content = content
    |> String.replace(~r/^```\w*\n?/, "")
    |> String.replace(~r/\n?```$/, "")
    |> String.trim()

    with [_, after_instr] <- String.split(content, "---INSTRUCTION---", parts: 2),
         [instruction, after_code] <- String.split(after_instr, "---CODE---", parts: 2) do
      code = after_code
      |> String.split("---END---", parts: 2)
      |> List.first()
      |> String.trim()

      instruction = String.trim(instruction)

      if String.length(instruction) > 0 and String.length(code) > 0 do
        {:ok, instruction, code}
      else
        :error
      end
    else
      _ -> :error
    end
  end

  defp build_prompt(example, thinking?) do
    prefix = unless thinking?, do: "/no_think\n", else: ""

    """
    #{prefix}Convert this Python exercise to Elixir. Rewrite both the instruction and the code.

    ## Python Instruction
    #{example.instruction}

    ## Python Solution
    ```python
    #{example.code}
    ```

    ## Python Tests
    #{Enum.join(example.tests, "\n")}

    Remember: output ONLY the ---INSTRUCTION--- / ---CODE--- / ---END--- structure. No other text.
    """
  end

  defp bar, do: String.duplicate("=", 70)
end

thinking? = "--think" in System.argv()
Preview.run(thinking?)
