#!/usr/bin/env elixir

# Preview with full validation pipeline and verbose logging.
# Runs 3 hardcoded examples so you can check quality before the full run.
#
# Usage:
#   elixir preview_conversion.exs
#   elixir preview_conversion.exs --think

Mix.install([
  {:req, "~> 0.5"},
  {:jason, "~> 1.4"}
])

defmodule Pipeline do
  @llama_url "http://127.0.0.1:8080/v1/chat/completions"
  @workspace "elixir_sft_workspace"
  @max_retries 3

  @examples [
    %{
      instruction: "Write a python function to find the missing number in a given list of integers that contains n distinct numbers taken from 0, 1, 2, ..., n. The function should have a time complexity of O(n) and space complexity of O(1).",
      code: "def missing_number(nums):\n    n = len(nums)\n    total = n * (n + 1) // 2\n    sum_nums = sum(nums)\n    return total - sum_nums",
      entry_point: "missing_number",
      tests: [
        "assert missing_number([9,6,4,2,3,5,7,0,1]) == 8",
        "assert missing_number([0, 1]) == 2",
        "assert missing_number([3, 0, 1]) == 2"
      ]
    },
    %{
      instruction: "Write a python function to check if a given string is a palindrome, considering only alphanumeric characters and ignoring cases.",
      code: "def is_palindrome(s: str) -> bool:\n    s = ''.join([c.lower() for c in s if c.isalnum()])\n    return s == s[::-1]",
      entry_point: "is_palindrome",
      tests: [
        ~s|assert is_palindrome("A man, a plan, a canal: Panama") == True|,
        ~s|assert is_palindrome("race a car") == False|,
        ~s|assert is_palindrome(" ") == True|
      ]
    },
    %{
      instruction: "Write a function to find the length of the longest substring without repeating characters in a given string.",
      code: "def length_of_longest_substring(s):\n    char_map = {}\n    left = 0\n    max_length = 0\n    for right in range(len(s)):\n        if s[right] in char_map:\n            left = max(left, char_map[s[right]] + 1)\n        char_map[s[right]] = right\n        max_length = max(max_length, right - left + 1)\n    return max_length",
      entry_point: "length_of_longest_substring",
      tests: [
        ~s|assert length_of_longest_substring("abcabcbb") == 3|,
        ~s|assert length_of_longest_substring("bbbbb") == 1|,
        ~s|assert length_of_longest_substring("pwwkew") == 3|
      ]
    }
  ]

  @system_prompt """
  You convert Python coding exercises into Elixir coding exercises.

  You receive a Python problem (instruction + solution + tests) and produce an
  equivalent Elixir version. You rewrite BOTH the instruction and the code.

  INSTRUCTION rewriting rules:
  - Remove ALL Python references. Do not mention Python anywhere.
  - Replace types: dict→map, list→list, tuple→tuple, set→MapSet
  - Adapt complexity claims for Elixir (linked lists, immutable data, no in-place mutation)
  - Keep the core algorithmic problem identical

  CODE rules:
  - Idiomatic Elixir: pattern matching, pipes, guards, Enum/Stream, recursion
  - Module with @doc and @spec
  - Code MUST compile. Elixir syntax reminders:
    • div/2 and rem/2 are functions: div(a, b), NOT a div b
    • String.graphemes/1 or String.codepoints/1 for character iteration
    • Enum.at/2 for list access, hd/1 and tl/1 for head/tail
    • No mutable variables — use accumulators, Enum.reduce, recursion
  - Do NOT include tests in the module section

  TEST rules:
  - Separate module with `use ExUnit.Case`
  - Mirror the original Python assertions
  - Do NOT call ExUnit.start()

  OUTPUT FORMAT — these exact delimiters, each on its own line:

  ---INSTRUCTION---
  (rewritten instruction, no code)
  ---MODULE---
  (defmodule with solution only)
  ---TEST---
  (defmodule ...Test with ExUnit tests only)
  ---END---

  Nothing else. No markdown fences. No explanations. No preamble.
  """

  # ── Logging ──────────────────────────────────────────────────────────

  defp log(indent, msg), do: IO.puts(String.duplicate("  ", indent) <> msg)

  # ── Workspace Setup ────────────────────────────────────────────────

  def setup_workspace do
    if File.exists?(Path.join(@workspace, "mix.exs")) do
      log(0, "Workspace #{@workspace}/ already exists, checking deps...")
      ensure_deps()
    else
      log(0, "Creating Mix project with `mix new #{@workspace}`...")
      {output, code} = System.cmd("mix", ["new", @workspace], stderr_to_stdout: true)
      if code != 0, do: raise("mix new failed: #{output}")
      log(1, "Mix project scaffolded (mix.exs, lib/, test/, .formatter.exs)")

      log(1, "Injecting {:credo, \"~> 1.7\"} into mix.exs deps...")
      mix_exs = Path.join(@workspace, "mix.exs")
      mix_content = File.read!(mix_exs)
      fixed = Regex.replace(
        ~r/defp deps do\n\s+\[.*?\]/s,
        mix_content,
        "defp deps do\n      [\n        {:credo, \"~> 1.7\", only: [:dev, :test], runtime: false}\n      ]"
      )
      File.write!(mix_exs, fixed)

      log(1, "Writing .credo.exs (disabling ModuleDoc and TagTODO checks)...")
      File.write!(Path.join(@workspace, ".credo.exs"), """
      %{
        configs: [
          %{
            name: "default",
            checks: %{
              enabled: [
                {Credo.Check.Readability.ModuleDoc, false},
                {Credo.Check.Design.TagTODO, false}
              ]
            }
          }
        ]
      }
      """)

      log(1, "Removing default generated lib/*.ex and test/*_test.exs...")
      for f <- Path.wildcard(Path.join(@workspace, "lib/*.ex")), do: File.rm(f)
      for f <- Path.wildcard(Path.join(@workspace, "test/*_test.exs")), do: File.rm(f)

      ensure_deps()
      log(0, "✓ Workspace ready")
    end
  end

  defp ensure_deps do
    unless File.exists?(Path.join(@workspace, "deps/credo")) do
      log(1, "Running `mix deps.get` to fetch credo...")
      System.cmd("mix", ["deps.get"], cd: @workspace, stderr_to_stdout: true)
      log(1, "Running `mix deps.compile` to compile credo...")
      System.cmd("mix", ["deps.compile"], cd: @workspace, stderr_to_stdout: true)
      log(1, "✓ Deps ready")
    else
      log(1, "✓ Credo already installed")
    end
  end

  # ── Validation Pipeline ────────────────────────────────────────────

  def validate(module_code, test_code) do
    mod_path = Path.join(@workspace, "lib/solution.ex")
    test_path = Path.join(@workspace, "test/solution_test.exs")

    log(2, "Cleaning old lib/*.ex and test/*_test.exs...")
    for f <- Path.wildcard(Path.join(@workspace, "lib/*.ex")), do: File.rm(f)
    for f <- Path.wildcard(Path.join(@workspace, "test/*_test.exs")), do: File.rm(f)

    log(2, "Writing #{String.length(module_code)} chars → lib/solution.ex")
    File.write!(mod_path, module_code)
    log(2, "Writing #{String.length(test_code)} chars → test/solution_test.exs")
    File.write!(test_path, test_code)

    errors = []

    # Compile
    log(2, "[1/4] Running `mix compile --warnings-as-errors --force`...")
    {output, code} = System.cmd("mix", ["compile", "--warnings-as-errors", "--force"],
      cd: @workspace, stderr_to_stdout: true, env: [{"MIX_ENV", "test"}])
    compile_ok = code == 0
    errors = if compile_ok do
      log(3, "✓ Compilation passed")
      errors
    else
      log(3, "✗ Compilation failed:")
      clean_mix_output(output) |> String.split("\n") |> Enum.each(&log(4, &1))
      errors ++ [{:compile, clean_mix_output(output)}]
    end

    # Format
    errors = if compile_ok do
      log(2, "[2/4] Running `mix format --check-formatted`...")
      {_output, code} = System.cmd("mix", ["format", "--check-formatted",
        "lib/solution.ex", "test/solution_test.exs"],
        cd: @workspace, stderr_to_stdout: true)
      if code == 0 do
        log(3, "✓ Already properly formatted")
        errors
      else
        log(3, "~ Not formatted, running `mix format` to auto-fix...")
        System.cmd("mix", ["format", "lib/solution.ex", "test/solution_test.exs"],
          cd: @workspace, stderr_to_stdout: true)
        log(3, "✓ Auto-formatted")
        errors ++ [{:format, "Code was not formatted. mix format has been applied."}]
      end
    else
      log(2, "[2/4] Skipping format check (compilation failed)")
      errors
    end

    # Credo
    errors = if compile_ok do
      log(2, "[3/4] Running `mix credo --strict` on lib/solution.ex...")
      {output, _code} = System.cmd("mix", ["credo", "list", "--strict",
        "--format", "oneline", "lib/solution.ex"],
        cd: @workspace, stderr_to_stdout: true, env: [{"MIX_ENV", "test"}])
      credo_issues = output
      |> String.split("\n")
      |> Enum.filter(&String.contains?(&1, "lib/solution.ex"))
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

      if credo_issues == [] do
        log(3, "✓ No credo issues")
        errors
      else
        log(3, "~ #{length(credo_issues)} credo issue(s):")
        Enum.each(credo_issues, &log(4, &1))
        errors ++ [{:credo, Enum.join(credo_issues, "\n")}]
      end
    else
      log(2, "[3/4] Skipping credo (compilation failed)")
      errors
    end

    # Tests
    {test_result, errors} = if compile_ok do
      log(2, "[4/4] Running `mix test test/solution_test.exs`...")
      {output, code} = System.cmd("mix", ["test", "test/solution_test.exs", "--no-deps-check"],
        cd: @workspace, stderr_to_stdout: true, env: [{"MIX_ENV", "test"}])
      if code == 0 do
        log(3, "✓ All tests passed")
        {:pass, errors}
      else
        log(3, "✗ Tests failed:")
        clean_mix_output(output) |> String.split("\n") |> Enum.take(10) |> Enum.each(&log(4, &1))
        {:fail, errors ++ [{:test, clean_mix_output(output)}]}
      end
    else
      log(2, "[4/4] Skipping tests (compilation failed)")
      {:skip, errors}
    end

    final_mod = File.read!(mod_path)
    final_test = File.read!(test_path)

    total_issues = length(errors)
    if total_issues == 0 do
      log(2, "✓ All 4 checks passed")
    else
      log(2, "✗ #{total_issues} check(s) failed: #{errors |> Enum.map(&elem(&1, 0)) |> Enum.join(", ")}")
    end

    %{
      errors: errors,
      compiled: compile_ok,
      tests: test_result,
      module_code: final_mod,
      test_code: final_test
    }
  end

  defp clean_mix_output(output) do
    output
    |> String.replace(~r/Compiling \d+ file.*\n/, "")
    |> String.replace(~r/Generated elixir_sft.* app\n/, "")
    |> String.replace(~r/\e\[[0-9;]*m/, "")
    |> String.trim()
  end

  # ── LLM + Retry Loop ──────────────────────────────────────────────

  def convert_with_retries(example, thinking?, max_tokens) do
    log(1, "Building initial prompt from Python instruction...")
    initial_prompt = build_initial_prompt(example, thinking?)
    log(1, "Prompt built (#{String.length(initial_prompt)} chars)")
    do_attempt(example, initial_prompt, thinking?, max_tokens, 1, nil)
  end

  defp do_attempt(_example, _prompt, _thinking?, _max_tokens, attempt, _) when attempt > @max_retries do
    log(1, "✗ Giving up after #{@max_retries} attempts")
    {:failed, nil}
  end

  defp do_attempt(example, prompt, thinking?, max_tokens, attempt, _last) do
    log(1, "── Attempt #{attempt}/#{@max_retries} ──")
    log(1, "Sending prompt to LLM (#{String.length(prompt)} chars, max_tokens=#{max_tokens})...")
    t0 = System.monotonic_time(:millisecond)

    case call_llm(prompt, max_tokens) do
      {:ok, content} ->
        elapsed = System.monotonic_time(:millisecond) - t0
        log(1, "LLM responded in #{Float.round(elapsed / 1000, 1)}s (#{String.length(content)} chars)")
        log(1, "Parsing structured output (looking for delimiters)...")

        case parse_output(content) do
          {:ok, instruction, module_code, test_code} ->
            log(1, "✓ Parsed: instruction=#{String.length(instruction)} module=#{String.length(module_code)} test=#{String.length(test_code)} chars")
            log(1, "Running validation pipeline...")

            result = validate(module_code, test_code)

            if result.errors == [] do
              log(1, "✓ Conversion succeeded on attempt #{attempt}")
              {:ok, %{
                instruction: instruction,
                module_code: result.module_code,
                test_code: result.test_code,
                attempts: attempt
              }}
            else
              error_types = result.errors |> Enum.map(&elem(&1, 0)) |> Enum.join(", ")
              log(1, "✗ Validation failed (#{error_types}). Building retry prompt with error feedback...")
              retry_prompt = build_retry_prompt(example, content, result.errors, thinking?)
              log(1, "Retry prompt built (#{String.length(retry_prompt)} chars)")
              do_attempt(example, retry_prompt, thinking?, max_tokens, attempt + 1, result)
            end

          :error ->
            log(1, "✗ Could not find delimiters in LLM output. First 200 chars:")
            log(2, String.slice(content, 0, 200))
            log(1, "Building parse-retry prompt...")
            retry_prompt = build_parse_retry_prompt(example, content, thinking?)
            do_attempt(example, retry_prompt, thinking?, max_tokens, attempt + 1, nil)
        end

      {:empty, reason} ->
        elapsed = System.monotonic_time(:millisecond) - t0
        log(1, "✗ LLM returned empty after #{Float.round(elapsed / 1000, 1)}s: #{reason}")
        if attempt < @max_retries do
          log(1, "Retrying with shorter prompt and /no_think reinforcement...")
          retry = build_empty_retry_prompt(example)
          do_attempt(example, retry, thinking?, max_tokens, attempt + 1, nil)
        else
          log(1, "✗ No retries left")
          {:failed, nil}
        end

      {:error, reason} ->
        elapsed = System.monotonic_time(:millisecond) - t0
        log(1, "✗ LLM request error after #{Float.round(elapsed / 1000, 1)}s: #{reason}")
        if attempt < @max_retries do
          log(1, "Retrying in case it was a transient error...")
          do_attempt(example, prompt, thinking?, max_tokens, attempt + 1, nil)
        else
          log(1, "✗ No retries left")
          {:failed, nil}
        end
    end
  end

  defp call_llm(user_prompt, max_tokens) do
    body = %{
      messages: [
        %{role: "system", content: @system_prompt},
        %{role: "user", content: user_prompt}
      ],
      temperature: 0.3,
      max_tokens: max_tokens,
      stream: false
    }

    case Req.post(@llama_url, json: body, receive_timeout: 600_000) do
      {:ok, %{status: 200, body: resp}} ->
        choice = resp["choices"] |> List.first()
        msg = choice["message"]
        content = (msg["content"] || "") |> String.trim()
        reasoning = (msg["reasoning_content"] || "") |> String.trim()
        finish = choice["finish_reason"]
        usage = resp["usage"]

        if usage do
          log(2, "Tokens: prompt=#{usage["prompt_tokens"]} completion=#{usage["completion_tokens"]} finish=#{finish}")
        end

        if String.length(reasoning) > 0 do
          log(2, "Thinking output: #{String.length(reasoning)} chars (not used)")
        end

        cond do
          String.length(content) > 0 -> {:ok, content}
          finish == "length" -> {:empty, "thinking exhausted all #{usage["completion_tokens"]} tokens"}
          true -> {:empty, "empty content, finish=#{finish}"}
        end

      {:ok, %{status: s}} -> {:error, "HTTP #{s}"}
      {:error, err} -> {:error, inspect(err)}
    end
  end

  # ── Prompt Builders ────────────────────────────────────────────────

  defp build_initial_prompt(example, thinking?) do
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

    The main function should be named `#{example.entry_point}`.
    Use the exact output format: ---INSTRUCTION--- / ---MODULE--- / ---TEST--- / ---END---
    """
  end

  defp build_empty_retry_prompt(example) do
    """
    /no_think
    Convert this Python to Elixir. Be concise. Go straight to the output.

    Python: #{example.instruction}

    ```python
    #{example.code}
    ```

    Tests: #{Enum.join(example.tests, "\n")}

    Function name: `#{example.entry_point}`

    Output ONLY:
    ---INSTRUCTION---
    (elixir instruction)
    ---MODULE---
    (elixir module)
    ---TEST---
    (ExUnit tests)
    ---END---
    """
  end

  defp build_retry_prompt(example, previous_output, errors, thinking?) do
    prefix = unless thinking?, do: "/no_think\n", else: ""

    error_text = Enum.map_join(errors, "\n\n", fn {stage, msg} ->
      "### #{stage} error:\n#{msg}"
    end)

    """
    #{prefix}Your previous conversion had errors. Fix them.

    ## Original Python
    #{example.instruction}

    ```python
    #{example.code}
    ```

    ## Your Previous Output (HAS ERRORS)
    #{previous_output}

    ## Errors
    #{error_text}

    Fix ALL errors. Code must compile, pass mix format, pass credo, and pass tests.
    Output using: ---INSTRUCTION--- / ---MODULE--- / ---TEST--- / ---END---
    Nothing else.
    """
  end

  defp build_parse_retry_prompt(example, previous_output, thinking?) do
    prefix = unless thinking?, do: "/no_think\n", else: ""

    """
    #{prefix}Your output could not be parsed. Use the EXACT delimiters below.

    ## Python
    #{example.instruction}

    ```python
    #{example.code}
    ```

    ## Python Tests
    #{Enum.join(example.tests, "\n")}

    ## Your Previous Output (COULD NOT BE PARSED)
    #{previous_output}

    Function name: `#{example.entry_point}`

    Your output MUST be exactly:

    ---INSTRUCTION---
    (rewritten instruction)
    ---MODULE---
    defmodule SomeName do
      def #{example.entry_point}(...) do
        ...
      end
    end
    ---TEST---
    defmodule SomeNameTest do
      use ExUnit.Case

      test "..." do
        assert ...
      end
    end
    ---END---

    NOTHING else.
    """
  end

  # ── Output Parsing ─────────────────────────────────────────────────

  def parse_output(content) do
    content =
      content
      |> String.replace(~r/^```\w*\n?/, "")
      |> String.replace(~r/\n?```$/, "")
      |> String.trim()

    with [_, rest] <- String.split(content, "---INSTRUCTION---", parts: 2),
         [instruction, rest] <- String.split(rest, "---MODULE---", parts: 2),
         [module_code, rest] <- String.split(rest, "---TEST---", parts: 2) do

      test_code = rest
      |> String.split("---END---", parts: 2)
      |> List.first()
      |> strip_fences()

      instruction = String.trim(instruction)
      module_code = strip_fences(module_code)

      if instruction != "" and module_code != "" and test_code != "" do
        {:ok, instruction, module_code, test_code}
      else
        :error
      end
    else
      _ -> :error
    end
  end

  defp strip_fences(s) do
    s
    |> String.replace(~r/^```\w*\n?/m, "")
    |> String.replace(~r/\n?```\s*$/m, "")
    |> String.trim()
  end

  # ── Main ───────────────────────────────────────────────────────────

  def run(thinking?) do
    IO.puts(String.duplicate("═", 70))
    IO.puts("  PREVIEW — Full Validation Pipeline")
    IO.puts("  compile → format → credo → test → retry on failure")
    IO.puts(String.duplicate("═", 70))

    log(0, "\nStep 1: Check llama.cpp server")
    case Req.get("http://127.0.0.1:8080/health") do
      {:ok, %{status: 200}} -> log(1, "✓ llama.cpp is running")
      _ -> log(1, "✗ Cannot reach llama.cpp at #{@llama_url}"); System.halt(1)
    end

    case Req.get("http://127.0.0.1:8080/v1/models") do
      {:ok, %{status: 200, body: %{"data" => [%{"id" => id} | _]}}} ->
        log(1, "✓ Model loaded: #{id}")
      _ -> log(1, "~ Could not determine model name (non-fatal)")
    end

    log(0, "\nStep 2: Set up Mix workspace for validation")
    setup_workspace()

    max_tokens = if thinking?, do: 16_384, else: 4_096
    log(0, "\nStep 3: Convert #{length(@examples)} examples (thinking=#{thinking?}, max_tokens=#{max_tokens})")

    results = for {example, i} <- Enum.with_index(@examples, 1) do
      IO.puts("\n" <> String.duplicate("─", 70))
      log(0, "Example #{i}/#{length(@examples)}: #{example.entry_point}")
      IO.puts(String.duplicate("─", 70))
      log(0, "Original Python instruction:")
      log(1, example.instruction)

      result = convert_with_retries(example, thinking?, max_tokens)

      case result do
        {:ok, data} ->
          IO.puts("")
          log(0, "╔══ FINAL RESULT (attempt #{data.attempts}) ══╗")
          log(0, "")
          log(0, "Rewritten Elixir instruction:")
          log(1, data.instruction)
          log(0, "")
          log(0, "Module code (#{String.length(data.module_code)} chars):")
          IO.puts(data.module_code)
          log(0, "")
          log(0, "Test code (#{String.length(data.test_code)} chars):")
          IO.puts(data.test_code)
          :ok

        {:failed, _} ->
          :failed
      end
    end

    ok = Enum.count(results, &(&1 == :ok))
    fail = Enum.count(results, &(&1 == :failed))

    IO.puts("\n" <> String.duplicate("═", 70))
    log(0, "SUMMARY: #{ok} passed, #{fail} failed out of #{length(results)}")
    IO.puts(String.duplicate("═", 70))
  end
end

thinking? = "--think" in System.argv()
Pipeline.run(thinking?)
