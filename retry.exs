#!/usr/bin/env elixir

# Retry script: revalidate + fix existing JSONL entries against latest Credence.
#
# Two modes per entry:
#   1. Code PASSES all checks → regenerate instruction only (problem-not-solution)
#   2. Code FAILS any check → regenerate both code + instruction using existing
#      code/tests as context, with the same retry + refine loop as the converter
#
# On success: replaces the entry in the output file with the updated version.
# On failure: removes the entry from output and appends to error file.
#
# Usage:
#   elixir retry.exs elixir_sft_educational_instruct.jsonl
#   elixir retry.exs elixir_sft_educational_instruct.jsonl --start 200
#   elixir retry.exs elixir_sft_educational_instruct.jsonl --indices 201,218,222
#
# After running, use the converter with smart resume to pick up any entries
# that moved to the error file.

Mix.install([
  {:req, "~> 0.5"},
  {:jason, "~> 1.4"}
])

defmodule Retrier do
  @llama_url "http://127.0.0.1:8020/v1/chat/completions"
  @workspace "retry_workspace"
  @max_retries 5
  @max_refine_retries 5

  @instruction_rewrite_prompt """
  You are an expert Elixir programmer. You will receive an Elixir exercise: the
  current instruction, the working module code, and the tests. Your ONLY job is
  to rewrite the instruction.

  Rules for the instruction:
  - Describe the PROBLEM, not the SOLUTION
  - Say WHAT to compute and what edge cases to handle
  - NEVER mention specific Elixir functions, modules, or data structures
    (no Enum.reduce, MapSet, String.graphemes, Enum.scan, etc.)
  - NEVER dictate recursion style, accumulator patterns, or code structure
  - DO mention expected time/space complexity if relevant
  - DO mention edge case behavior (empty input, negative numbers, unicode, etc.)
  - DO mention the expected function name and its input/output contract
  - Think of it as a coding interview question — describe the problem, not the answer

  Good: "Write a function that finds the second largest distinct integer in a list.
  Return nil if there are fewer than two distinct values."

  Bad: "Use Enum.uniq/1 to deduplicate, then pattern match on [_, _ | _] to
  enforce minimum length, and use Enum.sort(:desc) to find the second element."

  OUTPUT FORMAT:

  ---INSTRUCTION---
  (rewritten instruction only — no code, no explanation, no markdown)
  ---END---

  Nothing else.
  """

  @fix_code_prompt """
  You are an expert Elixir programmer. You will receive:
  - The original instruction
  - A previous Elixir module that now FAILS validation
  - The previous tests
  - The specific errors

  Fix the code so it passes ALL checks: compile (with --warnings-as-errors),
  mix format, mix credo --strict, credence (semantic lint), and all tests.

  Also rewrite the instruction to describe the PROBLEM, not the solution.
  Never mention specific functions, data structures, or implementation techniques
  in the instruction.

  Idiomatic Elixir patterns to USE:
  - Descriptive parameter names — NEVER use single-letter names like s, n, k, m.
  - In multi-clause functions, prefix unused parameters with _ in EACH clause
    independently. Each clause is compiled separately.
  - Pattern matching in function heads for dispatch
  - Pipe operator |> for data transformation chains

  Anti-patterns to AVOID:
  - Single-letter parameter names (s, n, k, m, i)
  - def/defp functions prefixed with is_ — use ? suffix instead (valid?, palindrome?)
  - Enum.count/1 without predicate — use length/1
  - Enum.map(f) |> Enum.join — use Enum.map_join/3
  - Enum.map(f) |> Enum.max/min/sum — fuse into single Enum.reduce
  - Catch-all clauses that only raise — let FunctionClauseError handle it
  - if a > b, do: a, else: b — use max(a, b); same for min

  Common Elixir pitfalls when fixing errors:
  - "unused variable" warnings: prefix with _ in THAT clause only (each clause is independent)
  - "undefined variable": you probably renamed a param to _name but still reference it in the body
  - "descriptive_names" credence error: replace single-letter params with descriptive names in ALL clauses

  OUTPUT FORMAT:

  ---INSTRUCTION---
  (rewritten instruction — problem description only, no implementation details)
  ---MODULE---
  (fixed defmodule)
  ---TEST---
  (tests — keep all existing, add new if needed)
  ---END---

  Nothing else. No markdown fences. No explanations.
  """

  @review_prompt """
  You are an expert Elixir code reviewer. Review the Elixir code below and provide
  actionable feedback. Focus on:

  1. EDGE CASES: What inputs would break this?
  2. IDIOMATIC ELIXIR: Pattern matching, guards, pipes, naming conventions?
  3. CORRECTNESS: Does it handle all cases from the instruction?
  4. PERFORMANCE: Any inefficiency for Elixir's data structures?
  5. ADDITIONAL TESTS: What test cases are missing?

  Be specific and actionable. If the code is already excellent, say "NO_ISSUES_FOUND".

  IMPORTANT: Do NOT suggest catch-all clauses that raise errors, and do NOT suggest
  unnecessary is_list/is_integer guards. Focus on real improvements.
  """

  @refine_prompt """
  You are an expert Elixir programmer. Apply ALL the reviewer's suggestions.
  The improved code MUST still pass all existing tests plus any new ones.

  The instruction describes the PROBLEM, not the solution. If you add new edge
  case handling, update the instruction to mention the expected BEHAVIOR only.
  Never mention specific functions, data structures, or implementation techniques.

  Rules:
  - Keep the same module name and function name
  - Code must compile and pass mix format

  OUTPUT FORMAT:

  ---INSTRUCTION---
  (updated instruction — behavior only)
  ---MODULE---
  (improved defmodule)
  ---TEST---
  (improved tests)
  ---END---

  Nothing else. No markdown. No explanations.
  """

  # ── Logging ──────────────────────────────────────────────────────────

  defp log(indent, msg), do: IO.puts(String.duplicate("  ", indent) <> msg)

  # ── Workspace Setup ────────────────────────────────────────────────

  @credence_script """
  code = File.read!("lib/solution.ex")
  result = Credence.analyze(code)

  if result.valid do
    IO.puts("OK")
  else
    IO.puts("ISSUES: \#{length(result.issues)} credence issue(s) found")
    for issue <- result.issues do
      line = if issue.meta[:line], do: "line \#{issue.meta[:line]}", else: "unknown line"
      IO.puts("  [\#{issue.severity}] \#{issue.rule}: \#{issue.message} (\#{line})")
    end
    System.halt(1)
  end
  """

  def setup_workspace do
    if File.exists?(Path.join(@workspace, "mix.exs")) do
      log(0, "Workspace #{@workspace}/ exists")
      ensure_credence_in_mix_exs()
      ensure_credence_script()
      ensure_deps()
    else
      log(0, "Creating Mix project: #{@workspace}/")
      {output, code} = System.cmd("mix", ["new", @workspace], stderr_to_stdout: true)
      if code != 0, do: raise("mix new failed: #{output}")

      mix_exs = Path.join(@workspace, "mix.exs")
      mix_content = File.read!(mix_exs)
      fixed = Regex.replace(
        ~r/defp deps do\n\s+\[.*?\]/s,
        mix_content,
        "defp deps do\n      [\n        {:credo, \"~> 1.7\", only: [:dev, :test], runtime: false},\n        {:credence, github: \"Cinderella-Man/credence\", only: [:dev, :test], runtime: false}\n      ]"
      )
      File.write!(mix_exs, fixed)

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

      ensure_credence_script()
      for f <- Path.wildcard(Path.join(@workspace, "lib/*.ex")), do: File.rm(f)
      for f <- Path.wildcard(Path.join(@workspace, "test/*_test.exs")), do: File.rm(f)
      ensure_deps()
      log(0, "✓ Workspace ready")
    end
  end

  defp ensure_credence_in_mix_exs do
    mix_exs = Path.join(@workspace, "mix.exs")
    content = File.read!(mix_exs)
    unless String.contains?(content, "credence") do
      fixed = String.replace(content,
        "{:credo, \"~> 1.7\", only: [:dev, :test], runtime: false}",
        "{:credo, \"~> 1.7\", only: [:dev, :test], runtime: false},\n        {:credence, github: \"Cinderella-Man/credence\", only: [:dev, :test], runtime: false}")
      File.write!(mix_exs, fixed)
    end
  end

  defp ensure_credence_script do
    path = Path.join(@workspace, "run_credence.exs")
    unless File.exists?(path), do: File.write!(path, @credence_script)
  end

  defp ensure_deps do
    unless File.exists?(Path.join(@workspace, "deps/credence")) do
      System.cmd("mix", ["deps.get"], cd: @workspace, stderr_to_stdout: true)
      System.cmd("mix", ["deps.compile"], cd: @workspace, stderr_to_stdout: true)
    end
  end

  def update_credence do
    log(0, "Updating credence to latest...")
    System.cmd("mix", ["deps.update", "credence"], cd: @workspace, stderr_to_stdout: true)
    System.cmd("mix", ["deps.compile", "credence", "--force"], cd: @workspace, stderr_to_stdout: true)
    log(0, "✓ Credence updated")
  end

  # ── Validation ─────────────────────────────────────────────────────

  def validate(module_code, test_code) do
    mod_path = Path.join(@workspace, "lib/solution.ex")
    test_path = Path.join(@workspace, "test/solution_test.exs")

    for f <- Path.wildcard(Path.join(@workspace, "lib/*.ex")), do: File.rm(f)
    for f <- Path.wildcard(Path.join(@workspace, "test/*_test.exs")), do: File.rm(f)
    File.write!(mod_path, module_code)
    File.write!(test_path, test_code)

    failures = []

    {output, code} = System.cmd("mix", ["compile", "--warnings-as-errors", "--force"],
      cd: @workspace, stderr_to_stdout: true, env: [{"MIX_ENV", "test"}])
    compiled = code == 0
    failures = if compiled, do: failures, else: failures ++ [{:compile, clean(output)}]

    failures = if compiled do
      {_, code} = System.cmd("mix", ["format", "--check-formatted", "lib/solution.ex", "test/solution_test.exs"],
        cd: @workspace, stderr_to_stdout: true)
      if code == 0 do
        failures
      else
        System.cmd("mix", ["format", "lib/solution.ex", "test/solution_test.exs"],
          cd: @workspace, stderr_to_stdout: true)
        failures
      end
    else
      failures
    end

    failures = if compiled do
      {output, _} = System.cmd("mix", ["credo", "list", "--strict", "--format", "oneline", "lib/solution.ex"],
        cd: @workspace, stderr_to_stdout: true, env: [{"MIX_ENV", "test"}])
      issues = output |> String.split("\n") |> Enum.filter(&String.contains?(&1, "lib/solution.ex")) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
      if issues == [], do: failures, else: failures ++ [{:credo, Enum.join(issues, "\n")}]
    else
      failures
    end

    failures = if compiled do
      {output, code} = System.cmd("mix", ["run", "--no-start", "run_credence.exs"],
        cd: @workspace, stderr_to_stdout: true, env: [{"MIX_ENV", "test"}])
      if code == 0, do: failures, else: failures ++ [{:credence, String.trim(output)}]
    else
      failures
    end

    failures = if compiled do
      {output, code} = System.cmd("mix", ["test", "test/solution_test.exs", "--no-deps-check"],
        cd: @workspace, stderr_to_stdout: true, env: [{"MIX_ENV", "test"}])
      if code == 0, do: failures, else: failures ++ [{:test, clean(output)}]
    else
      failures
    end

    failures
  end

  defp clean(output) do
    output
    |> String.replace(~r/Compiling \d+ file.*\n/, "")
    |> String.replace(~r/Generated .* app\n/, "")
    |> String.replace(~r/\e\[[0-9;]*m/, "")
    |> String.trim()
  end

  # ── LLM Calls ──────────────────────────────────────────────────────

  defp call_llm(user_prompt, system_prompt, max_tokens \\ 12_288) do
    body = %{
      messages: [
        %{role: "system", content: system_prompt},
        %{role: "user", content: user_prompt}
      ],
      model: "qwen3.6-27b-autoround",
      max_tokens: max_tokens
    }

    case Req.post(@llama_url, json: body, receive_timeout: 600_000) do
      {:ok, %{status: 200, body: resp}} ->
        choice = resp["choices"] |> List.first()
        content = (choice["message"]["content"] || "") |> String.trim()
        if String.length(content) > 0, do: {:ok, content}, else: {:empty, "no content"}

      {:ok, %{status: s}} -> {:error, "HTTP #{s}"}
      {:error, err} -> {:error, inspect(err, limit: 100)}
    end
  end

  # ── Parsing ────────────────────────────────────────────────────────

  defp parse_instruction_only(content) do
    content = content |> String.replace(~r/^```\w*\n?/, "") |> String.replace(~r/\n?```$/, "") |> String.trim()

    with [_, rest] <- String.split(content, "---INSTRUCTION---", parts: 2) do
      instruction = rest |> String.split("---END---", parts: 2) |> List.first() |> String.trim()
      if instruction != "", do: {:ok, instruction}, else: :error
    else
      _ -> :error
    end
  end

  defp parse_full_output(content) do
    content = content |> String.replace(~r/^```\w*\n?/, "") |> String.replace(~r/\n?```$/, "") |> String.trim()

    with [_, rest] <- String.split(content, "---INSTRUCTION---", parts: 2),
         [instruction, rest] <- String.split(rest, "---MODULE---", parts: 2),
         [module_code, rest] <- String.split(rest, "---TEST---", parts: 2) do
      test_code = rest |> String.split("---END---", parts: 2) |> List.first() |> strip_fences()
      module_code = strip_fences(module_code)
      instruction = String.trim(instruction)

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
    s |> String.replace(~r/^```\w*\n?/m, "") |> String.replace(~r/\n?```\s*$/m, "") |> String.trim()
  end

  # ── Path A: Instruction-Only Rewrite ───────────────────────────────

  defp rewrite_instruction(entry) do
    log(2, "Rewriting instruction only (code already passes)...")

    prompt = """
    Rewrite the instruction for this Elixir exercise. The code and tests are
    already working — do NOT change them. Only rewrite the instruction.

    ## Current Instruction
    #{entry["instruction"]}

    ## Working Module
    ```elixir
    #{entry["elixir_code"]}
    ```

    ## Working Tests
    ```elixir
    #{entry["elixir_test"]}
    ```

    Output: ---INSTRUCTION--- / ---END---
    """

    case call_llm(prompt, @instruction_rewrite_prompt, 4096) do
      {:ok, content} ->
        case parse_instruction_only(content) do
          {:ok, new_instruction} ->
            log(2, "✓ Instruction rewritten (#{String.length(new_instruction)} chars)")
            {:ok, Map.put(entry, "instruction", new_instruction)}

          :error ->
            log(2, "✗ Could not parse instruction rewrite, keeping original")
            {:ok, entry}
        end

      _ ->
        log(2, "✗ LLM call failed, keeping original")
        {:ok, entry}
    end
  end

  # ── Path B: Full Code + Instruction Fix ────────────────────────────

  defp fix_code_and_instruction(entry, failures) do
    log(2, "Fixing code + instruction (current code fails validation)...")

    error_text = Enum.map_join(failures, "\n\n", fn {stage, msg} ->
      "### #{stage} error:\n#{msg}"
    end)

    do_fix_attempt(entry, error_text, 1)
  end

  defp do_fix_attempt(_entry, _error_text, attempt) when attempt > @max_retries do
    log(2, "✗ Fix failed after #{@max_retries} attempts")
    {:failed, "exceeded #{@max_retries} retries"}
  end

  defp do_fix_attempt(entry, error_text, attempt) do
    log(2, "── Fix attempt #{attempt}/#{@max_retries} ──")

    prompt = """
    Fix this Elixir code that now fails validation. Use the existing code and
    tests as your starting point — fix the issues, don't rewrite from scratch.

    ## Original Instruction
    #{entry["instruction"] || entry["original_instruction"]}

    ## Previous Module (HAS ERRORS)
    ```elixir
    #{entry["elixir_code"]}
    ```

    ## Previous Tests
    ```elixir
    #{entry["elixir_test"]}
    ```

    ## Errors Found
    #{error_text}

    Fix ALL errors. Keep the same module and function names.
    Output: ---INSTRUCTION--- / ---MODULE--- / ---TEST--- / ---END---
    """

    case call_llm(prompt, @fix_code_prompt) do
      {:ok, content} ->
        case parse_full_output(content) do
          {:ok, instruction, module_code, test_code} ->
            log(2, "Parsed. Validating...")
            new_failures = validate(module_code, test_code)

            if new_failures == [] do
              log(2, "✓ Fix succeeded on attempt #{attempt}")
              updated = entry
              |> Map.put("instruction", instruction)
              |> Map.put("elixir_code", module_code)
              |> Map.put("elixir_test", test_code)
              |> Map.put("retry_attempts", attempt)

              log(2, "Starting refinement...")
              refine_solution(updated)
            else
              failed_stages = new_failures |> Enum.map(&elem(&1, 0)) |> Enum.join(", ")
              log(2, "✗ Still failing (#{failed_stages})")
              retry_error_text = Enum.map_join(new_failures, "\n\n", fn {stage, msg} ->
                "### #{stage} error:\n#{msg}"
              end)
              do_fix_attempt(entry, retry_error_text, attempt + 1)
            end

          :error ->
            log(2, "✗ Could not parse LLM output, retrying...")
            do_fix_attempt(entry, error_text, attempt + 1)
        end

      {:empty, _} ->
        log(2, "✗ Empty response, retrying...")
        do_fix_attempt(entry, error_text, attempt + 1)

      {:error, reason} ->
        log(2, "✗ LLM error: #{reason}")
        {:failed, reason}
    end
  end

  # ── Refinement (same as converter) ─────────────────────────────────

  defp refine_solution(entry) do
    log(2, "[Refine 1/3] Asking for code review...")

    review_user = """
    Review this Elixir code. Identify edge cases, idiom issues, and missing tests.

    ## Instruction
    #{entry["instruction"]}

    ## Module Code
    ```elixir
    #{entry["elixir_code"]}
    ```

    ## Tests
    ```elixir
    #{entry["elixir_test"]}
    ```

    If excellent as-is, respond with only: NO_ISSUES_FOUND
    """

    case call_llm(review_user, @review_prompt) do
      {:ok, feedback} ->
        if String.contains?(feedback, "NO_ISSUES_FOUND") do
          log(2, "✓ Reviewer found no issues")
          {:ok, entry}
        else
          log(2, "Reviewer has feedback, applying...")
          do_refine(entry, feedback, nil, 1)
        end

      _ ->
        log(2, "✗ Review failed, keeping current version")
        {:ok, entry}
    end
  end

  defp do_refine(entry, _feedback, _prev_errors, attempt) when attempt > @max_refine_retries do
    log(2, "✗ Refinement failed after #{@max_refine_retries} attempts, keeping current")
    {:ok, entry}
  end

  defp do_refine(entry, feedback, prev_errors, attempt) do
    log(2, "[Refine 2/3] Attempt #{attempt}/#{@max_refine_retries}...")

    prompt = if prev_errors do
      {prev_output, errors} = prev_errors
      error_text = Enum.map_join(errors, "\n\n", fn {stage, msg} -> "### #{stage} error:\n#{msg}" end)

      """
      Your previous refinement had errors. Fix them.

      ## Original Working Module (do NOT break this)
      ```elixir
      #{entry["elixir_code"]}
      ```

      ## Original Working Tests (these MUST still pass)
      ```elixir
      #{entry["elixir_test"]}
      ```

      ## Your Previous Refinement (HAS ERRORS)
      #{prev_output}

      ## Errors
      #{error_text}

      Fix ALL errors. The code must compile, pass mix format, and pass all tests.

      Common Elixir pitfalls when fixing errors:
      - "unused variable" warnings: prefix with _ in THAT clause only
      - "undefined variable": you renamed a param to _name but still reference it
      - "descriptive_names": replace single-letter params in ALL clauses

      Output: ---INSTRUCTION--- / ---MODULE--- / ---TEST--- / ---END---
      Nothing else.
      """
    else
      """
      Apply the review feedback to improve this Elixir code.

      ## Instruction
      #{entry["instruction"]}

      ## Current Module (working)
      ```elixir
      #{entry["elixir_code"]}
      ```

      ## Current Tests (passing)
      ```elixir
      #{entry["elixir_test"]}
      ```

      ## Review Feedback
      #{feedback}

      Keep same module/function names. All existing tests must pass.
      Update instruction to describe BEHAVIOR only, never implementation.
      Output: ---INSTRUCTION--- / ---MODULE--- / ---TEST--- / ---END---
      """
    end

    case call_llm(prompt, @refine_prompt) do
      {:ok, content} ->
        case parse_full_output(content) do
          {:ok, instruction, module_code, test_code} ->
            log(2, "[Refine 3/3] Validating refined code...")
            new_failures = validate(module_code, test_code)

            if new_failures == [] do
              log(2, "✓ Refinement passed!")
              orig_tests = count_tests(entry["elixir_test"])
              new_tests = count_tests(test_code)
              log(2, "Tests: #{orig_tests} → #{new_tests}")

              refined = entry
              |> Map.put("instruction", instruction)
              |> Map.put("elixir_code", module_code)
              |> Map.put("elixir_test", test_code)
              |> Map.put("refined", true)

              {:ok, refined}
            else
              log(2, "✗ Refined version failed validation")
              do_refine(entry, feedback, {content, new_failures}, attempt + 1)
            end

          :error ->
            log(2, "✗ Could not parse refined output")
            do_refine(entry, feedback, nil, attempt + 1)
        end

      _ ->
        log(2, "✗ Refine LLM call failed, keeping current")
        {:ok, entry}
    end
  end

  defp count_tests(test_code) when is_binary(test_code) do
    test_code |> String.split("\n") |> Enum.count(&String.contains?(&1, "test \""))
  end
  defp count_tests(_), do: 0

  # ── Main ───────────────────────────────────────────────────────────

  def run(jsonl_path, filter_indices) do
    unless File.exists?(jsonl_path) do
      IO.puts("Error: #{jsonl_path} not found")
      System.halt(1)
    end

    tmp_path = jsonl_path <> ".tmp"
    errors_path = String.replace(jsonl_path, ".jsonl", "_errors.jsonl")

    log(0, "Step 1: Set up workspace")
    setup_workspace()
    update_credence()

    # Convert filter_indices to a MapSet for O(1) lookup
    index_set = if is_list(filter_indices), do: MapSet.new(filter_indices), else: nil

    log(0, "\nStep 2: Processing entries line-by-line...")

    # Open all file handles
    output_file = File.open!(tmp_path, [:write, :utf8])
    errors_file = File.open!(errors_path, [:append, :utf8])

    stats = %{passed_as_is: 0, instruction_rewritten: 0, code_fixed: 0, failed: 0, skipped: 0}

    # Stream the input file to keep memory usage low and allow immediate writes
    final_stats =
      jsonl_path
      |> File.stream!()
      |> Stream.map(&String.trim/1)
      |> Stream.reject(&(&1 == ""))
      |> Enum.reduce(stats, fn line, acc ->
        case Jason.decode(line) do
          {:ok, entry} ->
            idx = entry["index"]

            # Determine if this row needs processing
            should_process = is_nil(index_set) or MapSet.member?(index_set, idx)

            if should_process do
              process_entry(entry, errors_file, output_file, acc)
            else
              # Write original entry directly back to output
              IO.write(output_file, line <> "\n")
              %{acc | skipped: acc.skipped + 1}
            end

          {:error, _} ->
            log(0, "Skipping malformed JSON line")
            acc
        end
      end)

    File.close(output_file)
    File.close(errors_file)

    # Swap the original file with the updated one
    File.rename!(tmp_path, jsonl_path)

    IO.puts("""

    ══════════════════════════════════
      RETRY REPORT (Incremental)
    ══════════════════════════════════
      📝 Instruction rewritten:  #{final_stats.instruction_rewritten}
      🔧 Code + instruction fixed: #{final_stats.code_fixed}
      ✗ Failed (→ errors file):  #{final_stats.failed}
      ⏭ Unchanged/Skipped:        #{final_stats.skipped}
      Total entries in file:     #{final_stats.skipped + final_stats.instruction_rewritten + final_stats.code_fixed}

      Output:  #{jsonl_path}
      Errors:  #{errors_path}
    """)
  end

  defp process_entry(entry, errors_file, output_file, stats) do
    idx = entry["index"]
    ep = entry["entry_point"] || entry["original_entry_point"] || "?"
    t0 = System.monotonic_time(:millisecond)

    IO.puts("\n" <> String.duplicate("─", 60))
    log(0, "Processing idx=#{idx} #{ep}")
    IO.puts(String.duplicate("─", 60))

    module_code = entry["elixir_code"]
    test_code = entry["elixir_test"]

    if is_nil(module_code) or is_nil(test_code) do
      log(1, "SKIP — missing code or tests")
      IO.write(output_file, Jason.encode!(entry) <> "\n")
      %{stats | skipped: stats.skipped + 1}
    else
      log(1, "Validating existing code...")
      failures = validate(module_code, test_code)

      result = if failures == [] do
        log(1, "✓ Code passes all checks — rewriting instruction only")
        rewrite_instruction(entry)
      else
        failed_detail = format_failure_summary(failures)
        log(1, "✗ Code fails #{failed_detail} — fixing code + instruction")
        fix_code_and_instruction(entry, failures)
      end

      elapsed = Float.round((System.monotonic_time(:millisecond) - t0) / 1000, 1)

      case result do
        {:ok, updated_entry} ->
          was_code_fix = failures != []
          tag = if was_code_fix, do: "code+instruction fixed", else: "instruction rewritten"
          log(0, "✓ #{ep} — #{tag} (#{elapsed}s)")

          # WRITE IMMEDIATELY TO DISK
          IO.write(output_file, Jason.encode!(updated_entry) <> "\n")

          if was_code_fix do
            %{stats | code_fixed: stats.code_fixed + 1}
          else
            %{stats | instruction_rewritten: stats.instruction_rewritten + 1}
          end

        {:failed, reason} ->
          log(0, "✗ #{ep} — FAILED: #{reason} (#{elapsed}s)")
          # Per your original logic: failing rows go to errors and are REMOVED from output
          error_record = Map.put(entry, "retry_failure_reason", reason)
          IO.write(errors_file, Jason.encode!(error_record) <> "\n")

          # We don't write to output_file here, effectively "removing" it from the main file
          %{stats | failed: stats.failed + 1}
      end
    end
  end

  defp format_failure_summary(failures) do
    failures
    |> Enum.map(fn {stage, msg} ->
      case stage do
        :credence ->
          rules = Regex.scan(~r/\[(?:warning|info|high)\] ([a-z_]+):/, msg)
          |> Enum.map(fn [_, r] -> r end) |> Enum.uniq()
          if rules != [], do: "credence: #{Enum.join(rules, ", ")}", else: "credence"
        other -> to_string(other)
      end
    end)
    |> Enum.join(", ")
    |> then(&"(#{&1})")
  end
end

# ── CLI ──────────────────────────────────────────────────────────────

args = System.argv()

# Parse --indices 201,218,222
{filter_indices, args} =
  case Enum.find_index(args, &(&1 == "--indices")) do
    nil -> {nil, args}
    i ->
      indices = args |> Enum.at(i + 1) |> String.split(",") |> Enum.map(&String.to_integer(String.trim(&1)))
      remaining = args |> List.delete_at(i) |> List.delete_at(i)
      {indices, remaining}
  end

# Parse --start N (sugar: process all indices >= N)
{filter_indices, args} =
  case Enum.find_index(args, &(&1 == "--start")) do
    nil -> {filter_indices, args}
    i ->
      start = args |> Enum.at(i + 1) |> String.to_integer()
      remaining = args |> List.delete_at(i) |> List.delete_at(i)
      # --start overrides --indices: will be applied after loading entries
      {{:start_from, start}, remaining}
  end

jsonl_path =
  case args do
    [path] -> path
    [] -> "elixir_sft_educational_instruct.jsonl"
    _ ->
      IO.puts("Usage: elixir retry.exs [file.jsonl] [--indices 1,2,3] [--start N]")
      System.halt(1)
  end

# If --start was used, load file to discover indices >= N
filter_indices =
  case filter_indices do
    {:start_from, start_n} ->
      if File.exists?(jsonl_path) do
        jsonl_path
        |> File.stream!()
        |> Stream.map(&String.trim/1)
        |> Stream.reject(&(&1 == ""))
        |> Stream.map(fn line ->
          case Jason.decode(line) do
            {:ok, %{"index" => idx}} when is_integer(idx) and idx >= start_n -> idx
            _ -> nil
          end
        end)
        |> Stream.reject(&is_nil/1)
        |> Enum.to_list()
      else
        []
      end
    other -> other
  end

scope = cond do
  is_nil(filter_indices) -> "ALL entries"
  is_list(filter_indices) and length(filter_indices) > 10 -> "#{length(filter_indices)} entries (from --start)"
  is_list(filter_indices) -> "indices: #{Enum.join(filter_indices, ", ")}"
end

IO.puts("""
╔═══════════════════════════════════════════════════════╗
║  Credence Retry — fix + rewrite existing entries       ║
║  validate → rewrite instruction OR fix code → refine   ║
╚═══════════════════════════════════════════════════════╝
  File:   #{jsonl_path}
  Scope:  #{scope}
""")

Retrier.run(jsonl_path, filter_indices)
