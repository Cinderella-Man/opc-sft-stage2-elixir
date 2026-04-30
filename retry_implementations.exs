#!/usr/bin/env elixir

# Fix implementations that fail latest Credence rules.
#
# Run this AFTER retry_instructions.exs has updated the instructions.
# For each entry:
#   - Validate existing code against all 5 checks
#   - If passes → skip (already good)
#   - If fails → send existing code + tests + instruction + errors to LLM to fix
#   - Same retry + refine loop as the converter
#   - On failure → remove from output, append to errors file
#
# Resumable: writes completed indices to a .progress file.
#
# Usage:
#   elixir retry_implementations.exs elixir_sft_educational_instruct.jsonl
#   elixir retry_implementations.exs elixir_sft_educational_instruct.jsonl --start 200
#   elixir retry_implementations.exs elixir_sft_educational_instruct.jsonl --indices 201,218

Mix.install([
  {:req, "~> 0.5"},
  {:jason, "~> 1.4"}
])

defmodule ImplementationRetrier do
  @llama_url "http://127.0.0.1:8020/v1/chat/completions"
  @workspace "retry_impl_workspace"
  @max_retries 5
  @max_refine_retries 5

  @fix_prompt """
  You are an expert Elixir programmer. Fix the code below so it passes ALL checks:
  compile (--warnings-as-errors), mix format, mix credo --strict, credence
  (semantic lint), and all tests.

  You are given the instruction, the existing code (which has errors), and the tests.
  Fix the issues — don't rewrite from scratch. Keep as much of the original as possible.

  Idiomatic Elixir patterns to USE:
  - Descriptive parameter names — NEVER use single-letter names like s, n, k, m.
  - In multi-clause functions, prefix unused parameters with _ in EACH clause
    independently. Each clause is compiled separately.
  - Pattern matching in function heads for dispatch
  - Pipe operator |> for data transformation chains
  - Use ? suffix for boolean functions (not is_ prefix)

  Anti-patterns to AVOID:
  - Single-letter parameter names
  - is_ prefix on def/defp (use ? suffix: valid?, palindrome?)
  - Enum.count/1 without predicate — use length/1
  - Enum.map(f) |> Enum.join — use Enum.map_join/3
  - Enum.map(f) |> Enum.max/min/sum — fuse into Enum.reduce
  - Catch-all clauses that only raise — let FunctionClauseError do it
  - if a > b, do: a, else: b — use max(a, b)
  - List.foldl/3 — use Enum.reduce/3

  Common pitfalls when fixing errors:
  - "unused variable": prefix with _ in THAT clause only
  - "undefined variable": you renamed to _name but still reference it in body
  - "descriptive_names" credence: rename in ALL clauses of the function

  Keep the same module name, function name, and instruction.

  OUTPUT FORMAT:

  ---MODULE---
  (fixed defmodule)
  ---TEST---
  (tests — keep all existing, fix if broken)
  ---END---

  Nothing else. No markdown. No instruction section. No explanations.
  """

  @review_prompt """
  You are an expert Elixir code reviewer. Review the code and provide actionable
  feedback on edge cases, idiom, correctness, performance, and missing tests.
  If the code is excellent, say "NO_ISSUES_FOUND" and nothing else.

  Do NOT suggest catch-all raise clauses or unnecessary type guards.
  """

  @refine_prompt """
  You are an expert Elixir programmer. Apply ALL the reviewer's suggestions.
  The improved code MUST still pass all existing tests.
  Keep the same module name and function name.
  Do NOT change the instruction.

  OUTPUT FORMAT:

  ---MODULE---
  (improved defmodule)
  ---TEST---
  (improved tests)
  ---END---

  Nothing else. No markdown. No explanations.
  """

  defp log(indent, msg), do: IO.puts(String.duplicate("  ", indent) <> msg)

  # ── Credence Script ────────────────────────────────────────────────

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

  # ── Workspace Setup ────────────────────────────────────────────────

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
      content = File.read!(mix_exs)
      fixed = Regex.replace(~r/defp deps do\n\s+\[.*?\]/s, content,
        "defp deps do\n      [\n        {:credo, \"~> 1.7\", only: [:dev, :test], runtime: false},\n        {:credence, github: \"Cinderella-Man/credence\", only: [:dev, :test], runtime: false}\n      ]")
      File.write!(mix_exs, fixed)

      File.write!(Path.join(@workspace, ".credo.exs"), """
      %{configs: [%{name: "default", checks: %{enabled: [{Credo.Check.Readability.ModuleDoc, false}, {Credo.Check.Design.TagTODO, false}]}}]}
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
      if code != 0 do
        System.cmd("mix", ["format", "lib/solution.ex", "test/solution_test.exs"], cd: @workspace, stderr_to_stdout: true)
      end
      failures
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

    # Re-read in case format was applied
    final_mod = if compiled, do: File.read!(mod_path), else: module_code
    final_test = if compiled, do: File.read!(test_path), else: test_code

    {failures, final_mod, final_test}
  end

  defp clean(output) do
    output
    |> String.replace(~r/Compiling \d+ file.*\n/, "")
    |> String.replace(~r/Generated .* app\n/, "")
    |> String.replace(~r/\e\[[0-9;]*m/, "")
    |> String.trim()
  end

  # ── LLM ────────────────────────────────────────────────────────────

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
        content = resp["choices"] |> List.first() |> get_in(["message", "content"]) |> to_string() |> String.trim()
        if content != "", do: {:ok, content}, else: {:empty, "no content"}

      {:ok, %{status: s}} -> {:error, "HTTP #{s}"}
      {:error, err} -> {:error, inspect(err, limit: 100)}
    end
  end

  defp parse_module_test(content) do
    content = content |> String.replace(~r/^```\w*\n?/, "") |> String.replace(~r/\n?```$/, "") |> String.trim()

    with [_, rest] <- String.split(content, "---MODULE---", parts: 2),
         [module_code, rest] <- String.split(rest, "---TEST---", parts: 2) do
      test_code = rest |> String.split("---END---", parts: 2) |> List.first() |> strip_fences()
      module_code = strip_fences(module_code)
      if module_code != "" and test_code != "", do: {:ok, module_code, test_code}, else: :error
    else
      _ -> :error
    end
  end

  defp strip_fences(s) do
    s |> String.replace(~r/^```\w*\n?/m, "") |> String.replace(~r/\n?```\s*$/m, "") |> String.trim()
  end

  # ── Fix Loop ───────────────────────────────────────────────────────

  defp fix_entry(entry, initial_failures) do
    error_text = format_errors(initial_failures)
    do_fix(entry, error_text, 1)
  end

  defp do_fix(_entry, _error_text, attempt) when attempt > @max_retries do
    {:failed, "exceeded #{@max_retries} fix attempts"}
  end

  defp do_fix(entry, error_text, attempt) do
    log(2, "Fix attempt #{attempt}/#{@max_retries}")

    prompt = """
    Fix this Elixir code. Keep as much of the original as possible.

    ## Instruction
    #{entry["instruction"]}

    ## Current Module (HAS ERRORS)
    ```elixir
    #{entry["elixir_code"]}
    ```

    ## Current Tests
    ```elixir
    #{entry["elixir_test"]}
    ```

    ## Errors
    #{error_text}

    Fix ALL errors. Keep the same module and function names.
    Output: ---MODULE--- / ---TEST--- / ---END---
    """

    case call_llm(prompt, @fix_prompt) do
      {:ok, content} ->
        case parse_module_test(content) do
          {:ok, module_code, test_code} ->
            {new_failures, final_mod, final_test} = validate(module_code, test_code)

            if new_failures == [] do
              log(2, "✓ Fix passed on attempt #{attempt}")
              updated = entry
              |> Map.put("elixir_code", final_mod)
              |> Map.put("elixir_test", final_test)
              |> Map.put("fix_attempts", attempt)

              refine_entry(updated)
            else
              detail = format_failure_summary(new_failures)
              log(2, "✗ Still failing #{detail}")
              do_fix(entry, format_errors(new_failures), attempt + 1)
            end

          :error ->
            log(2, "✗ Could not parse output")
            do_fix(entry, error_text, attempt + 1)
        end

      {:empty, _} ->
        log(2, "✗ Empty response")
        do_fix(entry, error_text, attempt + 1)

      {:error, reason} ->
        log(2, "✗ LLM error: #{reason}")
        {:failed, reason}
    end
  end

  # ── Refine Loop ────────────────────────────────────────────────────

  defp refine_entry(entry) do
    log(2, "Requesting code review...")

    review_prompt = """
    Review this Elixir code. Identify edge cases, idiom issues, and missing tests.

    ## Instruction
    #{entry["instruction"]}

    ## Module
    ```elixir
    #{entry["elixir_code"]}
    ```

    ## Tests
    ```elixir
    #{entry["elixir_test"]}
    ```

    If excellent, respond only: NO_ISSUES_FOUND
    """

    case call_llm(review_prompt, @review_prompt) do
      {:ok, feedback} ->
        if String.contains?(feedback, "NO_ISSUES_FOUND") do
          log(2, "✓ No issues found")
          {:ok, entry}
        else
          log(2, "Applying feedback...")
          do_refine(entry, feedback, nil, 1)
        end

      _ ->
        log(2, "Review failed, keeping current")
        {:ok, entry}
    end
  end

  defp do_refine(entry, _feedback, _prev, attempt) when attempt > @max_refine_retries do
    log(2, "Refinement exhausted, keeping current")
    {:ok, entry}
  end

  defp do_refine(entry, feedback, prev_errors, attempt) do
    log(2, "Refine attempt #{attempt}/#{@max_refine_retries}")

    prompt = if prev_errors do
      {prev_output, errors} = prev_errors
      error_text = format_errors(errors)

      """
      Your previous refinement had errors. Fix them.

      ## Working Module (do NOT break)
      ```elixir
      #{entry["elixir_code"]}
      ```

      ## Working Tests (MUST still pass)
      ```elixir
      #{entry["elixir_test"]}
      ```

      ## Your Previous Attempt (HAS ERRORS)
      #{prev_output}

      ## Errors
      #{error_text}

      Common pitfalls:
      - "unused variable": prefix with _ in THAT clause only
      - "undefined variable": renamed to _name but still reference it
      - "descriptive_names": rename in ALL clauses

      Output: ---MODULE--- / ---TEST--- / ---END---
      Nothing else.
      """
    else
      """
      Apply the review feedback to improve this Elixir code.

      ## Module (working)
      ```elixir
      #{entry["elixir_code"]}
      ```

      ## Tests (passing)
      ```elixir
      #{entry["elixir_test"]}
      ```

      ## Review Feedback
      #{feedback}

      Keep same module/function names. All existing tests must pass.
      Output: ---MODULE--- / ---TEST--- / ---END---
      """
    end

    case call_llm(prompt, @refine_prompt) do
      {:ok, content} ->
        case parse_module_test(content) do
          {:ok, module_code, test_code} ->
            {new_failures, final_mod, final_test} = validate(module_code, test_code)

            if new_failures == [] do
              log(2, "✓ Refinement passed!")
              refined = entry
              |> Map.put("elixir_code", final_mod)
              |> Map.put("elixir_test", final_test)
              |> Map.put("refined", true)
              {:ok, refined}
            else
              do_refine(entry, feedback, {content, new_failures}, attempt + 1)
            end

          :error ->
            do_refine(entry, feedback, nil, attempt + 1)
        end

      _ ->
        log(2, "Refine LLM call failed")
        {:ok, entry}
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────

  defp format_errors(failures) do
    Enum.map_join(failures, "\n\n", fn {stage, msg} -> "### #{stage} error:\n#{msg}" end)
  end

  defp format_failure_summary(failures) do
    failures
    |> Enum.map(fn {stage, msg} ->
      case stage do
        :credence ->
          rules = Regex.scan(~r/\[(?:warning|info|high)\] ([a-z_]+):/, msg) |> Enum.map(fn [_, r] -> r end) |> Enum.uniq()
          if rules != [], do: "credence: #{Enum.join(rules, ", ")}", else: "credence"
        other -> to_string(other)
      end
    end)
    |> Enum.join(", ")
    |> then(&"(#{&1})")
  end

  # ── Progress Tracking ──────────────────────────────────────────────

  defp progress_path(jsonl_path), do: jsonl_path <> ".impl_progress"

  defp load_progress(jsonl_path) do
    path = progress_path(jsonl_path)
    if File.exists?(path) do
      path |> File.read!() |> String.split("\n") |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == "")) |> Enum.map(&String.to_integer/1) |> MapSet.new()
    else
      MapSet.new()
    end
  end

  defp mark_done(jsonl_path, idx) do
    File.write!(progress_path(jsonl_path), "#{idx}\n", [:append])
  end

  # ── Main ───────────────────────────────────────────────────────────

  def run(jsonl_path, filter_indices) do
    unless File.exists?(jsonl_path) do
      IO.puts("Error: #{jsonl_path} not found")
      System.halt(1)
    end

    errors_path = String.replace(jsonl_path, ".jsonl", "_errors.jsonl")

    log(0, "Step 1: Set up workspace")
    setup_workspace()
    update_credence()

    log(0, "\nStep 2: Load entries from #{jsonl_path}")
    entries =
      jsonl_path
      |> File.stream!()
      |> Stream.map(&String.trim/1)
      |> Stream.reject(&(&1 == ""))
      |> Stream.map(fn line -> case Jason.decode(line) do {:ok, e} -> e; _ -> nil end end)
      |> Stream.reject(&is_nil/1)
      |> Enum.to_list()

    entry_map = Map.new(entries, fn e -> {e["index"], e} end)
    all_indices = Enum.map(entries, & &1["index"]) |> Enum.sort()

    target_indices = case filter_indices do
      nil -> all_indices
      list -> Enum.filter(list, &Map.has_key?(entry_map, &1)) |> Enum.sort()
    end

    done = load_progress(jsonl_path)
    pending = Enum.reject(target_indices, &MapSet.member?(done, &1))

    log(1, "#{length(entries)} total, #{length(pending)} pending, #{MapSet.size(done)} already done")

    if pending == [] do
      log(0, "\n✓ All targeted implementations already processed.")
      log(0, "  Delete #{progress_path(jsonl_path)} to re-process.")
    else
      errors_file = File.open!(errors_path, [:append, :utf8])
      stats = %{passed: 0, fixed: 0, failed: 0, skipped: 0}
      failed_indices = []

      {failed_indices, stats} =
        pending
        |> Enum.with_index(1)
        |> Enum.reduce({failed_indices, stats}, fn {idx, num}, {failed_acc, stats} ->
          entry = entry_map[idx]
          ep = entry["entry_point"] || entry["original_entry_point"] || "?"
          t0 = System.monotonic_time(:millisecond)

          IO.puts("\n" <> String.duplicate("─", 60))
          log(0, "[#{num}/#{length(pending)}] idx=#{idx} #{ep}")

          unless entry["elixir_code"] && entry["elixir_test"] do
            log(1, "SKIP — missing code or tests")
            mark_done(jsonl_path, idx)
            {failed_acc, %{stats | skipped: stats.skipped + 1}}
          else
            log(1, "Validating existing code...")
            {failures, _final_mod, _final_test} = validate(entry["elixir_code"], entry["elixir_test"])
            elapsed_fn = fn -> Float.round((System.monotonic_time(:millisecond) - t0) / 1000, 1) end

            if failures == [] do
              log(1, "✓ Already passes all checks (#{elapsed_fn.()}s)")
              mark_done(jsonl_path, idx)
              {failed_acc, %{stats | passed: stats.passed + 1}}
            else
              detail = format_failure_summary(failures)
              log(1, "✗ Fails #{detail} — fixing...")

              case fix_entry(entry, failures) do
                {:ok, updated} ->
                  log(0, "✓ #{ep} fixed (#{elapsed_fn.()}s)")
                  :persistent_term.put({:updated_impl, idx}, updated)
                  mark_done(jsonl_path, idx)
                  {failed_acc, %{stats | fixed: stats.fixed + 1}}

                {:failed, reason} ->
                  log(0, "✗ #{ep} FAILED: #{reason} (#{elapsed_fn.()}s)")
                  error_record = Map.put(entry, "impl_retry_failure", reason)
                  IO.write(errors_file, Jason.encode!(error_record) <> "\n")
                  mark_done(jsonl_path, idx)
                  {[idx | failed_acc], %{stats | failed: stats.failed + 1}}
              end
            end
          end
        end)

      File.close(errors_file)

      # Rebuild JSONL: merge updates, remove failures
      failed_set = MapSet.new(failed_indices)

      final_entries =
        entries
        |> Enum.reject(fn e -> MapSet.member?(failed_set, e["index"]) end)
        |> Enum.map(fn entry ->
          idx = entry["index"]
          try do
            :persistent_term.get({:updated_impl, idx})
          rescue
            ArgumentError -> entry
          end
        end)

      tmp_path = jsonl_path <> ".tmp"
      File.write!(tmp_path, Enum.map_join(final_entries, "\n", &Jason.encode!/1) <> "\n")
      File.rename!(tmp_path, jsonl_path)

      # Clean up
      pending |> Enum.each(fn idx ->
        try do :persistent_term.erase({:updated_impl, idx}) rescue _ -> :ok end
      end)

      IO.puts("""

      ══════════════════════════════════
        IMPLEMENTATION RETRY REPORT
      ══════════════════════════════════
        ✓ Already passing:  #{stats.passed}
        🔧 Fixed:            #{stats.fixed}
        ✗ Failed (→ errors): #{stats.failed}
        ⏭ Skipped:           #{stats.skipped}
        Output entries:     #{length(final_entries)}

        Output:   #{jsonl_path}
        Errors:   #{errors_path}
        Progress: #{progress_path(jsonl_path)}
        (delete progress file to re-process)
      """)
    end
  end
end

# ── CLI ──────────────────────────────────────────────────────────────

args = System.argv()

{filter_indices, args} =
  case Enum.find_index(args, &(&1 == "--indices")) do
    nil -> {nil, args}
    i ->
      indices = args |> Enum.at(i + 1) |> String.split(",") |> Enum.map(&String.to_integer(String.trim(&1)))
      {indices, args |> List.delete_at(i) |> List.delete_at(i)}
  end

{filter_indices, args} =
  case Enum.find_index(args, &(&1 == "--start")) do
    nil -> {filter_indices, args}
    i ->
      start_n = args |> Enum.at(i + 1) |> String.to_integer()
      remaining = args |> List.delete_at(i) |> List.delete_at(i)
      {{:start_from, start_n}, remaining}
  end

jsonl_path = case args do
  [path] -> path
  [] -> "elixir_sft_educational_instruct.jsonl"
  _ -> IO.puts("Usage: elixir retry_implementations.exs [file.jsonl] [--start N] [--indices 1,2,3]"); System.halt(1)
end

filter_indices = case filter_indices do
  {:start_from, start_n} ->
    if File.exists?(jsonl_path) do
      jsonl_path |> File.stream!() |> Stream.map(&String.trim/1) |> Stream.reject(&(&1 == ""))
      |> Stream.map(fn line -> case Jason.decode(line) do {:ok, %{"index" => idx}} when idx >= start_n -> idx; _ -> nil end end)
      |> Stream.reject(&is_nil/1) |> Enum.to_list()
    else [] end
  other -> other
end

scope = cond do
  is_nil(filter_indices) -> "ALL entries"
  is_list(filter_indices) and length(filter_indices) > 10 -> "#{length(filter_indices)} entries"
  is_list(filter_indices) -> "indices: #{Enum.join(filter_indices, ", ")}"
end

IO.puts("""
╔═══════════════════════════════════════════════════════╗
║  Implementation Fixer                                  ║
║  validate → fix code → refine → update output          ║
╚═══════════════════════════════════════════════════════╝
  File:   #{jsonl_path}
  Scope:  #{scope}
""")

ImplementationRetrier.run(jsonl_path, filter_indices)
