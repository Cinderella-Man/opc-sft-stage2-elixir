#!/usr/bin/env elixir

# Convert OpenCoder SFT dataset to Elixir with full validation pipeline.
#
# For each row:
#   1. LLM rewrites instruction + code for Elixir
#   2. Module written to lib/, tests to test/
#   3. Pipeline: mix compile → mix format → mix credo → credence → mix test
#   4. If anything fails, errors sent back to LLM (up to 3 retries)
#   5. Final result saved to JSONL
#
# Usage:
#   elixir convert_to_elixir.exs [subset] [start_index] [--workers N]
#
# First run creates Mix projects in ./elixir_sft_workspace_0/ .. _N/
# Requires: Elixir 1.15+, llama.cpp on http://127.0.0.1:8020

Mix.install([
  {:req, "~> 0.5"},
  {:explorer, "~> 0.10"},
  {:jason, "~> 1.4"}
])

defmodule ElixirSFTConverter do
  @llama_url "http://127.0.0.1:8020/v1/chat/completions"
  @workspace_base "elixir_sft_workspace"
  @dataset_base "https://huggingface.co/datasets/OpenCoder-LLM/opc-sft-stage2/resolve/refs%2Fconvert%2Fparquet"
  @max_retries 5

  @system_prompt """
  You convert Python coding exercises into Elixir coding exercises.

  You receive a Python problem (instruction + solution + tests) and produce an
  equivalent Elixir version. You rewrite BOTH the instruction and the code.

  INSTRUCTION rewriting rules:
  - Remove ALL Python references. Do not mention Python anywhere.
  - Replace types: dict→map, list→list, tuple→tuple, set→MapSet, string→string
  - Keep the core algorithmic problem identical
  - Describe the PROBLEM, not the SOLUTION. The instruction should say WHAT
    to compute and what edge cases to handle, never HOW to implement it.
  - NEVER mention specific Elixir functions, modules, or data structures in
    the instruction (no Enum.reduce, MapSet, String.graphemes, Enum.scan, etc.)
  - NEVER dictate recursion style (tail-recursive, accumulator, etc.)
  - NEVER prescribe internal helper functions, default arguments, or code structure
  - DO mention expected time/space complexity if the original instruction does
  - DO mention edge case behavior (empty input, negative numbers, unicode, etc.)
  - DO mention the expected function name and its input/output contract
  - Think of the instruction as what you'd give to a human developer in a
    coding interview — describe the problem and constraints, not the answer

  PYTHON → ELIXIR translation patterns (apply these, don't transliterate):
  - for loop with accumulator → Enum.reduce/3 or recursive function with accumulator
  - for loop building a list → Enum.map/2, Enum.filter/2, or for comprehension
  - while loop → recursion with pattern-matched base case
  - list[i] index access in a loop → NEVER use Enum.at in a loop (O(n²));
    use recursion, Enum.reduce, or Enum.with_index instead
  - list.append(x) → prepend [x | acc], then Enum.reverse at the end
  - list + list → avoid ++ in a loop (O(n) each time); prepend + reverse
  - dict[key] / dict.get(key) → pattern match on %{key => value} or Map.get/2
  - if/elif/else chains → cond/do, multi-clause functions, or pattern matching
  - try/except → {:ok, val}/{:error, reason} tuples + case or with
  - class with methods → module with functions, struct if state is needed
  - len(list) == 0 → pattern match on [] in function head
  - sorting with key function → Enum.sort_by/2
  - string iteration (for c in s) → String.graphemes/1 |> Enum.map/filter/reduce
  - string slicing s[1:] → binary pattern matching or String.slice/2
  - integer division // → div(a, b); modulo % → rem(a, b) — both are functions
  - multiple return values → return a tuple
  - None → nil
  - True/False → true/false (lowercase)
  - default args → Elixir supports \\\\ for defaults in function heads

  Idiomatic Elixir patterns to USE:
  - Pattern matching in function heads for dispatch (instead of case/cond inside)
  - Multi-clause functions for different input shapes
  - Pipe operator |> for data transformation chains
  - Guards (when is_list/is_integer/is_binary, when x > 0, etc.)
  - @doc with examples and @spec for type documentation
  - with for chaining multiple {:ok, _} results

  Anti-patterns to AVOID:
  - Enum.at/2 inside Enum.reduce or recursion (O(n) per access on linked lists)
  - Building lists with list ++ [element] (O(n) per append)
  - ++ inside recursive functions (same O(n²) cost as in loops)
  - length(list) == 0 or length(list) > 0 (traverses entire list; match on []/[_|_])
  - length(list) in guard clauses (O(n) on every call attempt)
  - Deeply nested case/if/cond — flatten with multi-clause functions or with
  - Single-clause def with a case/cond on the argument — use multi-clause instead
  - Assigning intermediate variables that are only used once — use pipes
  - String.graphemes |> Enum.reverse |> Enum.join — use String.reverse/1
  - Enum.sort(list) |> Enum.reverse — use Enum.sort(list, :desc)
  - Enum.sort(list) |> Enum.at(index) — use Enum.min/max or pattern matching
  - Enum.join("") — the empty string is the default, just use Enum.join()
  - when var == literal in guards — pattern match the literal in the function head
  - Decomposing a string into graphemes/charlist only to compare with Enum.reverse
    — compare strings directly with String.reverse/1
  - def/defp functions prefixed with is_ (e.g. is_valid, is_palindrome) — use ? suffix
    instead (valid?, palindrome?). is_ prefix is reserved for guard-safe functions.
  - Enum.count/1 without a predicate — use length/1 for lists
  - List.foldl/3 or List.foldr/3 — use Enum.reduce/3 instead
  - Enum.map(f) |> Enum.max/min/sum — fuse into a single Enum.reduce pass
  - Map.keys(m) |> Enum.map(fn k -> ... m[k] ... end) — iterate the map directly
  - Catch-all clauses that only raise (def foo(_), do: raise(...)) — let
    FunctionClauseError handle it; it includes the actual failing arguments
  - if a > b, do: a, else: b — use max(a, b); same for min

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

  @credence_script """
  code = File.read!("lib/solution.ex")
  result = Credence.analyze(code)

  if result.valid do
    IO.puts("OK: No credence issues found")
  else
    IO.puts("ISSUES: \#{length(result.issues)} credence issue(s) found")
    for issue <- result.issues do
      line = if issue.meta[:line], do: "line \#{issue.meta[:line]}", else: "unknown line"
      IO.puts("  [\#{issue.severity}] \#{issue.rule}: \#{issue.message} (\#{line})")
    end
    System.halt(1)
  end
  """

  # ── Logging ──────────────────────────────────────────────────────────

  defp log(indent, msg), do: IO.puts(String.duplicate("  ", indent) <> msg)

  # ── Workspace Pool ─────────────────────────────────────────────────

  defp workspace_dir(id), do: "#{@workspace_base}_#{id}"

  def start_pool(concurrency) do
    Agent.start_link(fn -> Enum.to_list(0..(concurrency - 1)) end, name: :workspace_pool)
  end

  defp checkout_workspace do
    Agent.get_and_update(:workspace_pool, fn
      [id | rest] -> {id, rest}
      [] -> {:wait, []}
    end)
  end

  defp checkin_workspace(id) do
    Agent.update(:workspace_pool, fn ids -> [id | ids] end)
  end

  # ── Workspace Setup ────────────────────────────────────────────────

  def setup_workspaces(concurrency) do
    Enum.each(0..(concurrency - 1), fn id ->
      setup_workspace(workspace_dir(id))
    end)
  end

  def setup_workspace(workspace) do
    if File.exists?(Path.join(workspace, "mix.exs")) do
      log(0, "Workspace #{workspace}/ already exists, checking deps...")
      ensure_credence_in_mix_exs(workspace)
      ensure_credence_script(workspace)
      ensure_deps(workspace)
    else
      log(0, "Creating Mix project with `mix new #{workspace}`...")
      {output, code} = System.cmd("mix", ["new", workspace], stderr_to_stdout: true)
      if code != 0, do: raise("mix new failed: #{output}")
      log(1, "Mix project scaffolded (mix.exs, lib/, test/, .formatter.exs)")

      log(1, "Injecting {:credo} and {:credence} into mix.exs deps...")
      mix_exs = Path.join(workspace, "mix.exs")
      mix_content = File.read!(mix_exs)
      fixed = Regex.replace(
        ~r/defp deps do\n\s+\[.*?\]/s,
        mix_content,
        "defp deps do\n      [\n        {:credo, \"~> 1.7\", only: [:dev, :test], runtime: false},\n        {:credence, github: \"Cinderella-Man/credence\", only: [:dev, :test], runtime: false}\n      ]"
      )
      File.write!(mix_exs, fixed)

      log(1, "Writing .credo.exs (disabling ModuleDoc and TagTODO checks)...")
      File.write!(Path.join(workspace, ".credo.exs"), """
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

      ensure_credence_script(workspace)

      log(1, "Removing default generated lib/*.ex and test/*_test.exs...")
      # The default file name depends on the workspace dir name; just glob everything
      for f <- Path.wildcard(Path.join(workspace, "lib/*.ex")), do: File.rm(f)
      for f <- Path.wildcard(Path.join(workspace, "test/*_test.exs")), do: File.rm(f)

      ensure_deps(workspace)
      log(0, "✓ Workspace #{workspace} ready")
    end
  end

  defp ensure_credence_in_mix_exs(workspace) do
    mix_exs = Path.join(workspace, "mix.exs")
    mix_content = File.read!(mix_exs)

    unless String.contains?(mix_content, "credence") do
      log(1, "Adding {:credence} to existing mix.exs deps...")
      fixed = String.replace(
        mix_content,
        "{:credo, \"~> 1.7\", only: [:dev, :test], runtime: false}",
        "{:credo, \"~> 1.7\", only: [:dev, :test], runtime: false},\n        {:credence, github: \"Cinderella-Man/credence\", only: [:dev, :test], runtime: false}"
      )
      File.write!(mix_exs, fixed)
    end
  end

  defp ensure_credence_script(workspace) do
    script_path = Path.join(workspace, "run_credence.exs")

    unless File.exists?(script_path) do
      log(1, "Writing run_credence.exs (semantic lint check script)...")
      File.write!(script_path, @credence_script)
    end
  end

  defp ensure_deps(workspace) do
    credo_ok = File.exists?(Path.join(workspace, "deps/credo"))
    credence_ok = File.exists?(Path.join(workspace, "deps/credence"))

    unless credo_ok and credence_ok do
      log(1, "Running `mix deps.get` to fetch deps...")
      System.cmd("mix", ["deps.get"], cd: workspace, stderr_to_stdout: true)
      log(1, "Running `mix deps.compile` to compile deps...")
      System.cmd("mix", ["deps.compile"], cd: workspace, stderr_to_stdout: true)
      log(1, "✓ Deps ready")
    else
      log(1, "✓ Credo and Credence already installed")
    end
  end

  # ── Validation Pipeline ────────────────────────────────────────────

  def validate(module_code, test_code, workspace) do
    mod_path = Path.join(workspace, "lib/solution.ex")
    test_path = Path.join(workspace, "test/solution_test.exs")

    log(2, "Cleaning old lib/*.ex and test/*_test.exs...")
    for f <- Path.wildcard(Path.join(workspace, "lib/*.ex")), do: File.rm(f)
    for f <- Path.wildcard(Path.join(workspace, "test/*_test.exs")), do: File.rm(f)

    log(2, "Writing #{String.length(module_code)} chars → lib/solution.ex")
    File.write!(mod_path, module_code)
    log(2, "Writing #{String.length(test_code)} chars → test/solution_test.exs")
    File.write!(test_path, test_code)

    errors = []

    # Step 1: Compile
    log(2, "[1/5] Running `mix compile --warnings-as-errors --force`...")
    {output, code} = System.cmd("mix", ["compile", "--warnings-as-errors", "--force"],
      cd: workspace, stderr_to_stdout: true, env: [{"MIX_ENV", "test"}])
    compiled = code == 0
    errors = if compiled do
      log(3, "✓ Compilation passed")
      errors
    else
      log(3, "✗ Compilation failed:")
      clean(output) |> String.split("\n") |> Enum.each(&log(4, &1))
      errors ++ [{:compile, clean(output)}]
    end

    # Step 2: Format
    formatted_clean = if compiled do
      log(2, "[2/5] Running `mix format --check-formatted`...")
      {_, code} = System.cmd("mix", ["format", "--check-formatted", "lib/solution.ex", "test/solution_test.exs"],
        cd: workspace, stderr_to_stdout: true)
      if code != 0 do
        log(3, "~ Code was not formatted, running `mix format` to auto-fix...")
        System.cmd("mix", ["format", "lib/solution.ex", "test/solution_test.exs"],
          cd: workspace, stderr_to_stdout: true)
        log(3, "✓ Auto-formatted (will use formatted version)")
        false
      else
        log(3, "✓ Already properly formatted")
        true
      end
    else
      log(2, "[2/5] Skipping format check (compilation failed)")
      nil
    end

    # Step 3: Credo
    credo_issues = if compiled do
      log(2, "[3/5] Running `mix credo --strict` on lib/solution.ex...")
      {output, _} = System.cmd("mix", ["credo", "list", "--strict", "--format", "oneline", "lib/solution.ex"],
        cd: workspace, stderr_to_stdout: true, env: [{"MIX_ENV", "test"}])
      issues = output
      |> String.split("\n")
      |> Enum.filter(&String.contains?(&1, "lib/solution.ex"))
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

      if issues == [] do
        log(3, "✓ No credo issues")
      else
        log(3, "~ #{length(issues)} credo issue(s):")
        Enum.each(issues, &log(4, &1))
      end
      issues
    else
      log(2, "[3/5] Skipping credo (compilation failed)")
      []
    end
    errors = if credo_issues != [], do: errors ++ [{:credo, Enum.join(credo_issues, "\n")}], else: errors

    # Step 4: Credence (semantic lint)
    errors = if compiled do
      log(2, "[4/5] Running Credence semantic analysis on lib/solution.ex...")
      {output, code} = System.cmd("mix", ["run", "--no-start", "run_credence.exs"],
        cd: workspace, stderr_to_stdout: true, env: [{"MIX_ENV", "test"}])
      if code == 0 do
        log(3, "✓ No credence issues")
        errors
      else
        credence_issues = output
        |> String.split("\n")
        |> Enum.filter(&String.contains?(&1, "]"))
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

        log(3, "✗ #{length(credence_issues)} credence issue(s):")
        Enum.each(credence_issues, &log(4, &1))
        errors ++ [{:credence, String.trim(output)}]
      end
    else
      log(2, "[4/5] Skipping credence (compilation failed)")
      errors
    end

    # Step 5: Tests
    {test_result, errors} = if compiled do
      log(2, "[5/5] Running `mix test test/solution_test.exs`...")
      {output, code} = System.cmd("mix", ["test", "test/solution_test.exs", "--no-deps-check"],
        cd: workspace, stderr_to_stdout: true, env: [{"MIX_ENV", "test"}])
      if code == 0 do
        log(3, "✓ All tests passed")
        {:pass, errors}
      else
        log(3, "✗ Tests failed:")
        clean(output) |> String.split("\n") |> Enum.take(10) |> Enum.each(&log(4, &1))
        {:fail, errors ++ [{:test, clean(output)}]}
      end
    else
      log(2, "[5/5] Skipping tests (compilation failed)")
      {:skip, errors}
    end

    # Re-read (may have been auto-formatted)
    final_mod = File.read!(mod_path)
    final_test = File.read!(test_path)

    total_issues = length(errors)
    if total_issues == 0 do
      log(2, "✓ All 5 checks passed")
    else
      log(2, "✗ #{total_issues} check(s) failed: #{errors |> Enum.map(&elem(&1, 0)) |> Enum.join(", ")}")
    end

    %{
      errors: errors,
      compiled: compiled,
      formatted_clean: formatted_clean,
      tests: test_result,
      module_code: final_mod,
      test_code: final_test
    }
  end

  defp clean(output) do
    output
    |> String.replace(~r/Compiling \d+ file.*\n/, "")
    |> String.replace(~r/Generated elixir_sft.* app\n/, "")
    |> String.replace(~r/\e\[[0-9;]*m/, "")
    |> String.trim()
  end

  # ── LLM + Retry Loop ──────────────────────────────────────────────

  def convert_row(row, max_tokens, workspace) do
    entry = row["entry_point"] || "?"
    log(1, "Building initial prompt from Python: #{String.slice(row["instruction"], 0, 80)}...")

    example = %{
      instruction: row["instruction"],
      code: row["code"],
      entry_point: row["entry_point"],
      tests: row["testcase"] || []
    }

    prompt = build_initial_prompt(example)
    log(1, "Prompt built (#{String.length(prompt)} chars). Starting conversion attempts...")

    case do_attempt(example, prompt, max_tokens, 1, workspace) do
      {:ok, result} ->
        log(1, "")
        log(1, "═══ Refinement Phase ═══")
        refine_solution(example, result, max_tokens, workspace)

      {:failed, reason} ->
        {:failed, reason}
    end
  end

  defp do_attempt(_example, _prompt, _max_tokens, attempt, _workspace) when attempt > @max_retries do
    log(1, "✗ Giving up after #{@max_retries} attempts")
    {:failed, "exceeded #{@max_retries} retries"}
  end

  defp do_attempt(example, prompt, max_tokens, attempt, workspace) do
    log(1, "── Attempt #{attempt}/#{@max_retries} ──")
    log(1, "Sending prompt to LLM (#{String.length(prompt)} chars, max_tokens=#{max_tokens})...")

    t0 = System.monotonic_time(:millisecond)

    case call_llm(prompt, max_tokens) do
      {:ok, content} ->
        elapsed = System.monotonic_time(:millisecond) - t0
        log(1, "LLM responded in #{Float.round(elapsed / 1000, 1)}s (#{String.length(content)} chars)")
        log(1, "Parsing structured output (looking for ---INSTRUCTION---/---MODULE---/---TEST---/---END---)...")

        case parse_output(content) do
          {:ok, instruction, module_code, test_code} ->
            log(1, "✓ Parsed: instruction=#{String.length(instruction)} module=#{String.length(module_code)} test=#{String.length(test_code)} chars")
            log(1, "Running validation pipeline...")

            result = validate(module_code, test_code, workspace)

            if result.errors == [] do
              log(1, "✓ Conversion succeeded on attempt #{attempt}")
              {:ok, %{
                instruction: instruction,
                elixir_code: result.module_code,
                elixir_test: result.test_code,
                original_instruction: example.instruction,
                python_code: example.code,
                entry_point: snake_name(example.entry_point),
                original_entry_point: example.entry_point,
                attempts: attempt,
                formatted_clean: result.formatted_clean
              }}
            else
              error_types = result.errors |> Enum.map(&elem(&1, 0)) |> Enum.join(", ")
              log(1, "✗ Validation failed (#{error_types}). Building retry prompt with error feedback...")
              retry = build_retry_prompt(example, content, result.errors)
              log(1, "Retry prompt built (#{String.length(retry)} chars)")
              do_attempt(example, retry, max_tokens, attempt + 1, workspace)
            end

          :error ->
            log(1, "✗ Could not find delimiters in LLM output. First 150 chars:")
            log(2, String.slice(content, 0, 150))
            log(1, "Building parse-retry prompt (includes previous output so LLM can see what went wrong)...")
            retry = build_parse_retry_prompt(example, content)
            do_attempt(example, retry, max_tokens, attempt + 1, workspace)
        end

      {:empty, reason} ->
        elapsed = System.monotonic_time(:millisecond) - t0
        log(1, "✗ LLM returned empty response after #{Float.round(elapsed / 1000, 1)}s: #{reason}")
        if attempt < @max_retries do
          log(1, "Retrying with a shorter prompt...")
          retry = build_empty_retry_prompt(example)
          do_attempt(example, retry, max_tokens, attempt + 1, workspace)
        else
          log(1, "✗ No retries left")
          {:failed, reason}
        end

      {:error, reason} ->
        elapsed = System.monotonic_time(:millisecond) - t0
        log(1, "✗ LLM request error after #{Float.round(elapsed / 1000, 1)}s: #{reason}")
        if attempt < @max_retries do
          log(1, "Retrying in case it was a transient error...")
          do_attempt(example, prompt, max_tokens, attempt + 1, workspace)
        else
          log(1, "✗ No retries left")
          {:failed, reason}
        end
    end
  end

  # ── Self-Refine: Review → Improve → Validate ──────────────────────

  @review_prompt """
  You are an expert Elixir code reviewer. Review the Elixir code below and provide
  actionable feedback. Focus on:

  1. EDGE CASES: What inputs would break this? Empty list, nil, single element,
     negative numbers, unicode strings, very large inputs, duplicate values, etc.
  2. IDIOMATIC ELIXIR: Is it truly idiomatic? Could it use better pattern matching
     in function heads? Guards? The pipe operator more naturally? with blocks?
  3. CORRECTNESS: Does it actually handle all cases from the instruction?
  4. PERFORMANCE: Any obvious inefficiency for Elixir's data structures?
     (e.g. repeated length/1 calls, Enum.at on lists, building lists in wrong order)
  5. ADDITIONAL TESTS: What test cases are missing?

  Be specific and actionable. For each issue, say what to change and why.
  If the code is already excellent, say "NO_ISSUES_FOUND" and nothing else.

  IMPORTANT: Do NOT suggest adding catch-all clauses that raise errors — Elixir's
  FunctionClauseError is the idiomatic way to handle unmatched inputs. Do NOT
  suggest adding is_list/is_integer guards unless the function genuinely needs
  to accept mixed types. Focus on real improvements, not defensive boilerplate.
  """

  @refine_prompt """
  You are an expert Elixir programmer. You will receive:
  - An instruction for an Elixir exercise
  - The current working Elixir module
  - The current tests
  - A code review with specific feedback

  Apply ALL the reviewer's suggestions. Produce an improved version.
  The improved code MUST still pass all existing tests plus any new ones.

  IMPORTANT: The instruction describes the PROBLEM, not the solution. If you add
  new edge case handling (e.g., empty input, invalid types), update the instruction
  to mention the expected BEHAVIOR for those cases — but do NOT describe HOW the
  code handles them internally. Never mention specific functions, data structures,
  recursion styles, or implementation techniques in the instruction.

  Good instruction update: "Returns nil for empty lists or lists with fewer than
  two unique elements."
  Bad instruction update: "Uses Enum.uniq/1 and pattern matching on [_, _ | _]
  to handle deduplication and enforce minimum list length."

  Rules:
  - Keep the same module name and function name
  - Add edge case handling (guards, pattern matching on empty input, etc.)
  - Add any new test cases the reviewer suggested
  - Code must compile and pass mix format

  OUTPUT FORMAT:

  ---INSTRUCTION---
  (updated instruction that accurately describes the implementation)
  ---MODULE---
  (improved defmodule)
  ---TEST---
  (improved tests with additional edge cases)
  ---END---

  Nothing else. No markdown. No explanations.
  """

  defp refine_solution(example, result, max_tokens, workspace) do
    # Step 1: Ask LLM to review the working code
    log(2, "[Step 1/3] Asking LLM to review the working code for issues and edge cases...")

    review_user = build_review_prompt(example, result)
    log(2, "Review prompt: #{String.length(review_user)} chars")

    t0 = System.monotonic_time(:millisecond)

    case call_llm_with_system(review_user, @review_prompt, max_tokens) do
      {:ok, review_feedback} ->
        elapsed = System.monotonic_time(:millisecond) - t0
        log(2, "Review received in #{Float.round(elapsed / 1000, 1)}s (#{String.length(review_feedback)} chars)")

        # Check if reviewer found no issues
        if String.contains?(review_feedback, "NO_ISSUES_FOUND") do
          log(2, "✓ Reviewer found no issues — code is already good")
          {:ok, Map.put(result, :refined, false)}
        else
          # Show summary of feedback
          feedback_lines = review_feedback |> String.split("\n") |> Enum.reject(&(&1 == ""))
          log(2, "Reviewer found #{length(feedback_lines)} lines of feedback:")
          feedback_lines |> Enum.take(5) |> Enum.each(&log(3, String.slice(&1, 0, 120)))
          if length(feedback_lines) > 5, do: log(3, "... (#{length(feedback_lines) - 5} more lines)")

          # Step 2: Ask LLM to apply the review feedback
          apply_review(example, result, review_feedback, max_tokens, workspace)
        end

      {:empty, reason} ->
        log(2, "✗ Review call returned empty: #{reason}. Keeping original.")
        {:ok, Map.put(result, :refined, false)}

      {:error, reason} ->
        log(2, "✗ Review call failed: #{reason}. Keeping original.")
        {:ok, Map.put(result, :refined, false)}
    end
  end

  @max_refine_retries 5

  defp apply_review(example, original_result, review_feedback, max_tokens, workspace) do
    do_refine_attempt(example, original_result, review_feedback, nil, max_tokens, 1, workspace)
  end

  defp do_refine_attempt(_, original_result, _, _, _, attempt, _workspace) when attempt > @max_refine_retries do
    log(2, "✗ Refinement failed after #{@max_refine_retries} attempts. Keeping original.")
    {:ok, Map.merge(original_result, %{refined: false, refinement_failed: "exceeded #{@max_refine_retries} retries"})}
  end

  defp do_refine_attempt(example, original_result, review_feedback, prev_errors, max_tokens, attempt, workspace) do
    log(2, "[Step 2/3] Refine attempt #{attempt}/#{@max_refine_retries}...")

    refine_user = if prev_errors do
      build_refine_fix_prompt(original_result, prev_errors)
    else
      build_refine_prompt(example, original_result, review_feedback)
    end

    log(2, "Refine prompt: #{String.length(refine_user)} chars")

    t0 = System.monotonic_time(:millisecond)

    case call_llm_with_system(refine_user, @refine_prompt, max_tokens) do
      {:ok, content} ->
        elapsed = System.monotonic_time(:millisecond) - t0
        log(2, "Refinement received in #{Float.round(elapsed / 1000, 1)}s (#{String.length(content)} chars)")
        log(2, "Parsing refined output...")

        case parse_refine_output(content) do
          {:ok, refined_instruction, refined_module, refined_test} ->
            log(2, "✓ Parsed: instruction=#{if refined_instruction, do: String.length(refined_instruction), else: "nil"} module=#{String.length(refined_module)} test=#{String.length(refined_test)} chars")

            log(2, "[Step 3/3] Validating refined code...")
            refined_result = validate(refined_module, refined_test, workspace)

            if refined_result.errors == [] do
              log(2, "✓ Refined version passed all checks on attempt #{attempt}!")

              orig_tests = count_tests(original_result.elixir_test)
              new_tests = count_tests(refined_result.test_code)
              log(2, "Tests: #{orig_tests} original → #{new_tests} after refinement")

              # Use updated instruction if provided, otherwise keep original
              final_instruction = if refined_instruction && refined_instruction != "" do
                log(2, "Instruction updated by refinement")
                refined_instruction
              else
                original_result.instruction
              end

              {:ok, Map.merge(original_result, %{
                instruction: final_instruction,
                elixir_code: refined_result.module_code,
                elixir_test: refined_result.test_code,
                refined: true,
                review_feedback: review_feedback,
                tests_before: orig_tests,
                tests_after: new_tests,
                refine_attempts: attempt
              })}
            else
              error_types = refined_result.errors |> Enum.map(&elem(&1, 0)) |> Enum.join(", ")
              log(2, "✗ Refined version failed validation (#{error_types}).")
              refined_result.errors |> Enum.each(fn {stage, msg} ->
                log(3, "[#{stage}] #{String.slice(msg, 0, 150)}")
              end)
              log(2, "Building retry prompt with error feedback...")
              do_refine_attempt(example, original_result, review_feedback, {content, refined_result.errors}, max_tokens, attempt + 1, workspace)
            end

          :error ->
            log(2, "✗ Could not parse refined output on attempt #{attempt}.")
            if attempt < @max_refine_retries do
              do_refine_attempt(example, original_result, review_feedback, nil, max_tokens, attempt + 1, workspace)
            else
              log(2, "Keeping original.")
              {:ok, Map.put(original_result, :refined, false)}
            end
        end

      {:empty, reason} ->
        log(2, "✗ Refine call returned empty: #{reason}.")
        if attempt < @max_refine_retries do
          do_refine_attempt(example, original_result, review_feedback, nil, max_tokens, attempt + 1, workspace)
        else
          log(2, "Keeping original.")
          {:ok, Map.put(original_result, :refined, false)}
        end

      {:error, reason} ->
        log(2, "✗ Refine call failed: #{reason}. Keeping original.")
        {:ok, Map.put(original_result, :refined, false)}
    end
  end

  defp build_review_prompt(example, result) do
    """
    Review this Elixir code. Identify edge cases, idiom issues, and missing tests.

    ## Instruction
    #{result.instruction}

    ## Module Code
    ```elixir
    #{result.elixir_code}
    ```

    ## Current Tests
    ```elixir
    #{result.elixir_test}
    ```

    ## Original Python (for reference — what edge cases did it handle?)
    ```python
    #{example.code}
    ```

    Provide specific, actionable feedback. If the code is excellent as-is, respond with only: NO_ISSUES_FOUND
    """
  end

  defp build_refine_prompt(_example, result, review_feedback) do
    """
    Apply the review feedback below to improve this Elixir code.

    ## Instruction
    #{result.instruction}

    ## Current Module (working, passes all tests)
    ```elixir
    #{result.elixir_code}
    ```

    ## Current Tests (all passing)
    ```elixir
    #{result.elixir_test}
    ```

    ## Review Feedback (apply ALL of these)
    #{review_feedback}

    Produce the improved version. Keep the same module and function names.
    All existing tests must still pass. Add new edge case tests.
    If you add new edge case handling, update the instruction to describe the
    expected BEHAVIOR — but never describe implementation details, specific
    functions, or data structures in the instruction.
    Output: ---INSTRUCTION--- / ---MODULE--- / ---TEST--- / ---END---
    """
  end

  defp build_refine_fix_prompt(result, {previous_output, errors}) do
    error_text = Enum.map_join(errors, "\n\n", fn {stage, msg} ->
      "### #{stage} error:\n#{msg}"
    end)

    """
    Your previous refinement had errors. Fix them.

    ## Current Instruction
    #{result.instruction}

    ## Original Working Module (do NOT break this)
    ```elixir
    #{result.elixir_code}
    ```

    ## Original Working Tests (these MUST still pass)
    ```elixir
    #{result.elixir_test}
    ```

    ## Your Previous Refinement (HAS ERRORS)
    #{previous_output}

    ## Errors Found
    #{error_text}

    Fix ALL errors. The code must compile, pass mix format, and pass all tests.
    Keep the same module and function names.
    If you update the instruction, describe BEHAVIOR only — never mention
    implementation details like specific functions or data structures.

    Output: ---INSTRUCTION--- / ---MODULE--- / ---TEST--- / ---END---
    Nothing else.
    """
  end

  defp parse_refine_output(content) do
    content =
      content
      |> String.replace(~r/^```\w*\n?/, "")
      |> String.replace(~r/\n?```$/, "")
      |> String.trim()

    # Try with instruction first
    if String.contains?(content, "---INSTRUCTION---") do
      with [_, rest] <- String.split(content, "---INSTRUCTION---", parts: 2),
           [instruction, rest] <- String.split(rest, "---MODULE---", parts: 2),
           [module_code, rest] <- String.split(rest, "---TEST---", parts: 2) do
        test_code = rest |> String.split("---END---", parts: 2) |> List.first() |> strip_fences()
        module_code = strip_fences(module_code)
        instruction = String.trim(instruction)

        if module_code != "" and test_code != "" do
          {:ok, instruction, module_code, test_code}
        else
          :error
        end
      else
        _ -> :error
      end
    else
      # Fallback: no instruction section
      with [_, rest] <- String.split(content, "---MODULE---", parts: 2),
           [module_code, rest] <- String.split(rest, "---TEST---", parts: 2) do
        test_code = rest |> String.split("---END---", parts: 2) |> List.first() |> strip_fences()
        module_code = strip_fences(module_code)

        if module_code != "" and test_code != "" do
          {:ok, nil, module_code, test_code}
        else
          :error
        end
      else
        _ -> :error
      end
    end
  end

  defp count_tests(test_code) do
    test_code
    |> String.split("\n")
    |> Enum.count(&String.contains?(&1, "test \""))
  end

  defp call_llm_with_system(user_prompt, system_prompt, max_tokens) do
    log(1, "Calling LLM with the following user prompt: #{user_prompt} and system prompt: #{system_prompt}")

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
        msg = choice["message"]
        content = (msg["content"] || "") |> String.trim()
        reasoning = (msg["reasoning_content"] || "") |> String.trim()
        finish = choice["finish_reason"]
        usage = resp["usage"]

        if usage do
          log(3, "Tokens: prompt=#{usage["prompt_tokens"]} completion=#{usage["completion_tokens"]} finish=#{finish}")
        end

        if String.length(reasoning) > 0 do
          log(3, "Thinking: #{String.length(reasoning)} chars (not used)")
        end

        cond do
          String.length(content) > 0 ->
            log(1, "Response from LLM: #{content}")
            {:ok, content}
          finish == "length" -> {:empty, "thinking exhausted tokens"}
          true -> {:empty, "empty content, finish=#{finish}"}
        end

      {:ok, %{status: s}} -> {:error, "HTTP #{s}"}
      {:error, err} -> {:error, inspect(err, limit: 100)}
    end
  end

  defp call_llm(user_prompt, max_tokens) do
    log(1, "Calling LLM with the following prompt: #{user_prompt}")

    body = %{
      messages: [
        %{role: "system", content: @system_prompt},
        %{role: "user", content: user_prompt}
      ],
      model: "qwen3.6-27b-autoround",
      max_tokens: max_tokens
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
          String.length(content) > 0 ->
            log(1, "Response from LLM: #{content}")
            {:ok, content}
          finish == "length" -> {:empty, "thinking exhausted all #{usage["completion_tokens"]} tokens (reasoning=#{String.length(reasoning)} chars)"}
          true -> {:empty, "empty content, finish=#{finish}"}
        end

      {:ok, %{status: s}} -> {:error, "HTTP #{s}"}
      {:error, err} -> {:error, inspect(err, limit: 100)}
    end
  end

  # ── Prompt Builders ────────────────────────────────────────────────

  defp build_initial_prompt(example) do
    tests = if is_list(example.tests), do: Enum.join(example.tests, "\n"), else: to_string(example.tests)

    """
    Convert this Python exercise to Elixir. Rewrite both the instruction and the code.

    ## Python Instruction
    #{example.instruction}

    ## Python Solution
    ```python
    #{example.code}
    ```

    ## Python Tests
    #{tests}

    The main function should be named `#{snake_name(example.entry_point)}`.
    Use the exact output format: ---INSTRUCTION--- / ---MODULE--- / ---TEST--- / ---END---
    """
  end

  defp build_empty_retry_prompt(example) do
    tests = if is_list(example.tests), do: Enum.join(example.tests, "\n"), else: to_string(example.tests)

    """
    Convert this Python to Elixir. Be concise. Go straight to the output.

    Python: #{example.instruction}

    ```python
    #{example.code}
    ```

    Tests: #{tests}

    Function name: `#{snake_name(example.entry_point)}`

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

  defp build_retry_prompt(example, previous_output, errors) do
    error_text = Enum.map_join(errors, "\n\n", fn {stage, msg} ->
      "### #{stage} error:\n#{msg}"
    end)

    """
    Your previous conversion had errors. Fix them.

    ## Original Python
    #{example.instruction}

    ```python
    #{example.code}
    ```

    ## Your Previous Output (HAS ERRORS)
    #{previous_output}

    ## Errors
    #{error_text}

    Fix ALL errors. Code must compile, pass mix format, pass credo, pass credence (semantic lint), and pass tests.
    Output using: ---INSTRUCTION--- / ---MODULE--- / ---TEST--- / ---END---
    Nothing else.
    """
  end

  defp build_parse_retry_prompt(example, previous_output) do
    tests = if is_list(example.tests), do: Enum.join(example.tests, "\n"), else: to_string(example.tests)

    """
    Your output could not be parsed. Use the EXACT delimiters below.

    ## Python
    #{example.instruction}

    ```python
    #{example.code}
    ```

    ## Python Tests
    #{tests}

    ## Your Previous Output (COULD NOT BE PARSED)
    #{previous_output}

    Function name: `#{snake_name(example.entry_point)}`

    Your output MUST be exactly:

    ---INSTRUCTION---
    (rewritten instruction)
    ---MODULE---
    defmodule SomeName do
      def #{snake_name(example.entry_point)}(...) do
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

  defp parse_output(content) do
    content =
      content
      |> String.replace(~r/^```\w*\n?/, "")
      |> String.replace(~r/\n?```$/, "")
      |> String.trim()

    with [_, rest] <- String.split(content, "---INSTRUCTION---", parts: 2),
         [instruction, rest] <- String.split(rest, "---MODULE---", parts: 2),
         [module_code, rest] <- String.split(rest, "---TEST---", parts: 2) do
      test_code = rest |> String.split("---END---", parts: 2) |> List.first() |> strip_fences()
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

  defp snake_name(name), do: name |> String.downcase() |> String.replace(~r/[^a-z0-9_]/, "_")

  # ── Download ───────────────────────────────────────────────────────

  defp ensure_downloaded(subset) do
    filename = "#{subset}_train.parquet"

    if File.exists?(filename) do
      size = File.stat!(filename).size
      log(0, "Dataset file #{filename} exists (#{Float.round(size / 1_048_576, 1)} MB)")
    else
      url = "#{@dataset_base}/#{subset}/train/0000.parquet"
      log(0, "Downloading #{subset} parquet from HuggingFace...")
      log(1, "URL: #{url}")

      case Req.get(url, into: File.stream!(filename), receive_timeout: 300_000) do
        {:ok, %{status: 200}} ->
          size = File.stat!(filename).size
          log(1, "✓ Downloaded #{Float.round(size / 1_048_576, 1)} MB → #{filename}")

        {:ok, %{status: s}} ->
          File.rm(filename)
          raise "Download failed: HTTP #{s}"

        {:error, e} ->
          File.rm(filename)
          raise "Download failed: #{inspect(e)}"
      end
    end

    filename
  end

  # ── Auto-Resume ──────────────────────────────────────────────────

  def detect_resume_index(output_path) do
    errors_path = String.replace(output_path, ".jsonl", "_errors.jsonl")

    max_output = last_index_in_file(output_path)
    max_errors = last_index_in_file(errors_path)

    case {max_output, max_errors} do
      {nil, nil} -> :start_fresh
      {a, nil} -> {:resume, a}
      {nil, b} -> {:resume, b}
      {a, b} -> {:resume, max(a, b)}
    end
  end

  defp last_index_in_file(path) do
    if File.exists?(path) do
      path
      |> File.stream!()
      |> Stream.map(&String.trim/1)
      |> Stream.reject(&(&1 == ""))
      |> Stream.map(fn line ->
        case Jason.decode(line) do
          {:ok, %{"index" => idx}} when is_integer(idx) -> idx
          _ -> nil
        end
      end)
      |> Stream.reject(&is_nil/1)
      |> Enum.max(fn -> nil end)
    else
      nil
    end
  end

  # ── Main ───────────────────────────────────────────────────────────

  def run(subset, start_index, concurrency) do
    log(0, "Step 1: Ensure dataset is downloaded")
    parquet_path = ensure_downloaded(subset)

    output_path = "elixir_sft_#{subset}.jsonl"
    errors_path = "elixir_sft_#{subset}_errors.jsonl"
    log_path = "convert_log_#{subset}.txt"
    max_tokens = 16_384

    log(0, "\nStep 2: Set up #{concurrency} Mix workspace(s) for validation")
    setup_workspaces(concurrency)
    start_pool(concurrency)

    log(0, "\nStep 3: Load dataset from #{parquet_path}")
    df = Explorer.DataFrame.from_parquet!(parquet_path)
    total = Explorer.DataFrame.n_rows(df)
    log(1, "Loaded #{total} rows total")
    log(1, "Will process rows #{start_index}..#{total - 1} (#{total - start_index} rows)")
    log(1, "LLM: #{@llama_url}, max_tokens=#{max_tokens}, workers=#{concurrency}")
    log(1, "Output  → #{output_path}")
    log(1, "Errors  → #{errors_path}")
    log(1, "Log     → #{log_path}")

    log(0, "\nStep 4: Begin conversion loop (#{concurrency} workers)")
    file = File.open!(output_path, [:append, :utf8])
    errors_file = File.open!(errors_path, [:append, :utf8])
    log_file = File.open!(log_path, [:append, :utf8])

    stats = %{ok: 0, failed: 0, total_attempts: 0, refined: 0}

    stats =
      df
      |> Explorer.DataFrame.slice(start_index, total - start_index)
      |> Explorer.DataFrame.to_rows()
      |> Enum.with_index(start_index)
      |> Task.async_stream(
        fn {row, idx} ->
          workspace_id = checkout_workspace()
          workspace = workspace_dir(workspace_id)
          entry = row["entry_point"] || "?"
          t0 = System.monotonic_time(:millisecond)

          IO.puts("\n" <> String.duplicate("─", 60))
          log(0, "[#{idx + 1}/#{total}] Converting: #{entry} (worker #{workspace_id})")
          IO.puts(String.duplicate("─", 60))

          result = convert_row(row, max_tokens, workspace)
          elapsed = Float.round((System.monotonic_time(:millisecond) - t0) / 1000, 1)

          checkin_workspace(workspace_id)
          {row, idx, entry, result, elapsed}
        end,
        max_concurrency: concurrency,
        timeout: :infinity,
        ordered: false
      )
      |> Enum.reduce(stats, fn {:ok, {row, idx, entry, result, elapsed}}, stats ->
        case result do
          {:ok, result} ->
            refined_tag = if result[:refined], do: " | refined ✨", else: " | kept original"
            tests_tag = if result[:tests_after], do: " | tests: #{result[:tests_before]}→#{result[:tests_after]}", else: ""
            log(0, "✓ SUCCESS: #{entry} | #{result.attempts} attempt(s) | #{elapsed}s | #{String.length(result.elixir_code)} chars#{refined_tag}#{tests_tag}")
            log(1, "Appending result to #{output_path}")
            IO.write(file, Jason.encode!(Map.put(result, :index, idx)) <> "\n")
            IO.write(log_file, "[#{idx}] ✓ #{entry} attempts=#{result.attempts} refined=#{result[:refined]} time=#{elapsed}s\n")
            refined_count = if result[:refined], do: 1, else: 0
            %{stats | ok: stats.ok + 1, total_attempts: stats.total_attempts + result.attempts, refined: stats.refined + refined_count}

          {:failed, reason} ->
            log(0, "✗ FAILED: #{entry} | #{reason} | #{elapsed}s")
            log(1, "Saving to errors file for later retry")
            error_record = %{
              index: idx,
              entry_point: entry,
              instruction: row["instruction"],
              code: row["code"],
              testcase: row["testcase"],
              failure_reason: reason,
              elapsed_s: elapsed
            }
            IO.write(errors_file, Jason.encode!(error_record) <> "\n")
            IO.write(log_file, "[#{idx}] ✗ #{entry}: #{reason} time=#{elapsed}s\n")
            %{stats | failed: stats.failed + 1, total_attempts: stats.total_attempts + @max_retries}
        end
      end)

    File.close(file)
    File.close(errors_file)
    File.close(log_file)

    processed = stats.ok + stats.failed
    avg_attempts = if processed > 0, do: Float.round(stats.total_attempts / processed, 1), else: 0

    IO.puts("""

    ══════════════════════════════════
      FINISHED
    ══════════════════════════════════
      ✓ Converted:      #{stats.ok}
      ✨ Refined:         #{stats.refined}/#{stats.ok}
      ✗ Failed:          #{stats.failed}
      Workers:           #{concurrency}
      Avg attempts/row:  #{avg_attempts}

      Output:  #{output_path}
      Errors:  #{errors_path}
      Log:     #{log_path}
    """)
  end
end

# ── CLI ──────────────────────────────────────────────────────────────

argv = System.argv()
args = argv

# Parse --workers N
{concurrency, args} =
  case Enum.find_index(args, &(&1 == "--workers")) do
    nil ->
      {1, args}
    i ->
      n = args |> Enum.at(i + 1) |> String.to_integer()
      remaining = args |> List.delete_at(i) |> List.delete_at(i)  # remove flag and value
      {n, remaining}
  end

{subset, explicit_start} =
  case args do
    [s, n] -> {s, String.to_integer(n)}
    [s] -> {s, :auto}
    [] -> {"educational_instruct", :auto}
  end

start =
  case explicit_start do
    :auto ->
      output_path = "elixir_sft_#{subset}.jsonl"
      case ElixirSFTConverter.detect_resume_index(output_path) do
        {:resume, idx} ->
          IO.puts("Found existing #{output_path}, last index=#{idx}. Resuming from #{idx + 1}.")
          idx + 1
        :start_fresh ->
          IO.puts("No existing output file found. Starting from 0.")
          0
      end
    n when is_integer(n) ->
      IO.puts("Explicit start index: #{n}")
      n
  end

IO.puts("""
╔═══════════════════════════════════════════════════════╗
║  Elixir SFT Converter (v4 — validated + credence)     ║
║  compile → format → credo → credence → test → retry   ║
╚═══════════════════════════════════════════════════════╝
  Subset:   #{subset}
  Start:    #{start}
  Workers:  #{concurrency}
  Retries:  up to 5 per row
  Output:   elixir_sft_#{subset}.jsonl
  Errors:   elixir_sft_#{subset}_errors.jsonl
""")

ElixirSFTConverter.run(subset, start, concurrency)
