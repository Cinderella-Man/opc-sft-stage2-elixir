#!/usr/bin/env elixir

# Convert OpenCoder SFT dataset to Elixir with full validation pipeline.
#
# For each row:
#   1. LLM rewrites instruction + code for Elixir
#   2. Module written to lib/, tests to test/
#   3. Pipeline: mix compile → mix format → mix credo → mix test
#   4. If anything fails, errors sent back to LLM (up to 3 retries)
#   5. Final result saved to JSONL
#
# Usage:
#   elixir convert_to_elixir.exs [subset] [start_index] [--think]
#
# First run creates a Mix project in ./elixir_sft_workspace/
# Requires: Elixir 1.15+, llama.cpp on http://127.0.0.1:8080

Mix.install([
  {:req, "~> 0.5"},
  {:explorer, "~> 0.10"},
  {:jason, "~> 1.4"}
])

defmodule ElixirSFTConverter do
  @llama_url "http://127.0.0.1:8080/v1/chat/completions"
  @workspace "elixir_sft_workspace"
  @dataset_base "https://huggingface.co/datasets/OpenCoder-LLM/opc-sft-stage2/resolve/refs%2Fconvert%2Fparquet"
  @max_retries 3

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

    # Step 1: Compile
    log(2, "[1/4] Running `mix compile --warnings-as-errors --force`...")
    {output, code} = System.cmd("mix", ["compile", "--warnings-as-errors", "--force"],
      cd: @workspace, stderr_to_stdout: true, env: [{"MIX_ENV", "test"}])
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
      log(2, "[2/4] Running `mix format --check-formatted`...")
      {_, code} = System.cmd("mix", ["format", "--check-formatted", "lib/solution.ex", "test/solution_test.exs"],
        cd: @workspace, stderr_to_stdout: true)
      if code != 0 do
        log(3, "~ Code was not formatted, running `mix format` to auto-fix...")
        System.cmd("mix", ["format", "lib/solution.ex", "test/solution_test.exs"],
          cd: @workspace, stderr_to_stdout: true)
        log(3, "✓ Auto-formatted (will use formatted version)")
        false
      else
        log(3, "✓ Already properly formatted")
        true
      end
    else
      log(2, "[2/4] Skipping format check (compilation failed)")
      nil
    end

    # Step 3: Credo
    credo_issues = if compiled do
      log(2, "[3/4] Running `mix credo --strict` on lib/solution.ex...")
      {output, _} = System.cmd("mix", ["credo", "list", "--strict", "--format", "oneline", "lib/solution.ex"],
        cd: @workspace, stderr_to_stdout: true, env: [{"MIX_ENV", "test"}])
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
      log(2, "[3/4] Skipping credo (compilation failed)")
      []
    end
    errors = if credo_issues != [], do: errors ++ [{:credo, Enum.join(credo_issues, "\n")}], else: errors

    # Step 4: Tests
    {test_result, errors} = if compiled do
      log(2, "[4/4] Running `mix test test/solution_test.exs`...")
      {output, code} = System.cmd("mix", ["test", "test/solution_test.exs", "--no-deps-check"],
        cd: @workspace, stderr_to_stdout: true, env: [{"MIX_ENV", "test"}])
      if code == 0 do
        log(3, "✓ All tests passed")
        {:pass, errors}
      else
        log(3, "✗ Tests failed:")
        clean(output) |> String.split("\n") |> Enum.take(10) |> Enum.each(&log(4, &1))
        {:fail, errors ++ [{:test, clean(output)}]}
      end
    else
      log(2, "[4/4] Skipping tests (compilation failed)")
      {:skip, errors}
    end

    # Re-read (may have been auto-formatted)
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

  def convert_row(row, thinking?, max_tokens) do
    entry = row["entry_point"] || "?"
    log(1, "Building initial prompt from Python: #{String.slice(row["instruction"], 0, 80)}...")

    example = %{
      instruction: row["instruction"],
      code: row["code"],
      entry_point: row["entry_point"],
      tests: row["testcase"] || []
    }

    prompt = build_initial_prompt(example, thinking?)
    log(1, "Prompt built (#{String.length(prompt)} chars). Starting conversion attempts...")
    do_attempt(example, prompt, thinking?, max_tokens, 1)
  end

  defp do_attempt(_example, _prompt, _thinking?, _max_tokens, attempt) when attempt > @max_retries do
    log(1, "✗ Giving up after #{@max_retries} attempts")
    {:failed, "exceeded #{@max_retries} retries"}
  end

  defp do_attempt(example, prompt, thinking?, max_tokens, attempt) do
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

            result = validate(module_code, test_code)

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
              retry = build_retry_prompt(example, content, result.errors, thinking?)
              log(1, "Retry prompt built (#{String.length(retry)} chars)")
              do_attempt(example, retry, thinking?, max_tokens, attempt + 1)
            end

          :error ->
            log(1, "✗ Could not find delimiters in LLM output. First 150 chars:")
            log(2, String.slice(content, 0, 150))
            log(1, "Building parse-retry prompt (includes previous output so LLM can see what went wrong)...")
            retry = build_parse_retry_prompt(example, content, thinking?)
            do_attempt(example, retry, thinking?, max_tokens, attempt + 1)
        end

      {:empty, reason} ->
        elapsed = System.monotonic_time(:millisecond) - t0
        log(1, "✗ LLM returned empty response after #{Float.round(elapsed / 1000, 1)}s: #{reason}")
        if attempt < @max_retries do
          log(1, "Retrying with a shorter prompt and /no_think reinforcement...")
          retry = build_empty_retry_prompt(example)
          do_attempt(example, retry, thinking?, max_tokens, attempt + 1)
        else
          log(1, "✗ No retries left")
          {:failed, reason}
        end

      {:error, reason} ->
        elapsed = System.monotonic_time(:millisecond) - t0
        log(1, "✗ LLM request error after #{Float.round(elapsed / 1000, 1)}s: #{reason}")
        if attempt < @max_retries do
          log(1, "Retrying in case it was a transient error...")
          do_attempt(example, prompt, thinking?, max_tokens, attempt + 1)
        else
          log(1, "✗ No retries left")
          {:failed, reason}
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
          finish == "length" -> {:empty, "thinking exhausted all #{usage["completion_tokens"]} tokens (reasoning=#{String.length(reasoning)} chars)"}
          true -> {:empty, "empty content, finish=#{finish}"}
        end

      {:ok, %{status: s}} -> {:error, "HTTP #{s}"}
      {:error, err} -> {:error, inspect(err, limit: 100)}
    end
  end

  # ── Prompt Builders ────────────────────────────────────────────────

  defp build_initial_prompt(example, thinking?) do
    prefix = unless thinking?, do: "/no_think\n", else: ""
    tests = if is_list(example.tests), do: Enum.join(example.tests, "\n"), else: to_string(example.tests)

    """
    #{prefix}Convert this Python exercise to Elixir. Rewrite both the instruction and the code.

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
    # Always force /no_think on retry — the whole reason we got empty was thinking eating all tokens
    tests = if is_list(example.tests), do: Enum.join(example.tests, "\n"), else: to_string(example.tests)

    """
    /no_think
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
    tests = if is_list(example.tests), do: Enum.join(example.tests, "\n"), else: to_string(example.tests)

    """
    #{prefix}Your output could not be parsed. Use the EXACT delimiters below.

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

  # ── Main ───────────────────────────────────────────────────────────

  def run(subset, start_index, thinking?) do
    log(0, "Step 1: Ensure dataset is downloaded")
    parquet_path = ensure_downloaded(subset)

    output_path = "elixir_sft_#{subset}.jsonl"
    errors_path = "elixir_sft_#{subset}_errors.jsonl"
    log_path = "convert_log_#{subset}.txt"
    max_tokens = if thinking?, do: 16_384, else: 4_096

    log(0, "\nStep 2: Set up Mix workspace for validation")
    setup_workspace()

    log(0, "\nStep 3: Load dataset from #{parquet_path}")
    df = Explorer.DataFrame.from_parquet!(parquet_path)
    total = Explorer.DataFrame.n_rows(df)
    log(1, "Loaded #{total} rows total")
    log(1, "Will process rows #{start_index}..#{total - 1} (#{total - start_index} rows)")
    log(1, "LLM: #{@llama_url}, max_tokens=#{max_tokens}, thinking=#{thinking?}")
    log(1, "Output  → #{output_path}")
    log(1, "Errors  → #{errors_path}")
    log(1, "Log     → #{log_path}")

    log(0, "\nStep 4: Begin conversion loop")
    file = File.open!(output_path, [:append, :utf8])
    errors_file = File.open!(errors_path, [:append, :utf8])
    log = File.open!(log_path, [:append, :utf8])

    stats = %{ok: 0, failed: 0, total_attempts: 0}

    stats =
      df
      |> Explorer.DataFrame.slice(start_index, total - start_index)
      |> Explorer.DataFrame.to_rows()
      |> Enum.with_index(start_index)
      |> Enum.reduce(stats, fn {row, idx}, stats ->
        entry = row["entry_point"] || "?"
        t0 = System.monotonic_time(:millisecond)

        IO.puts("\n" <> String.duplicate("─", 60))
        log(0, "[#{idx + 1}/#{total}] Converting: #{entry}")
        IO.puts(String.duplicate("─", 60))

        case convert_row(row, thinking?, max_tokens) do
          {:ok, result} ->
            elapsed = Float.round((System.monotonic_time(:millisecond) - t0) / 1000, 1)
            log(0, "✓ SUCCESS: #{entry} | #{result.attempts} attempt(s) | #{elapsed}s | #{String.length(result.elixir_code)} chars of Elixir")
            log(1, "Appending result to #{output_path}")
            IO.write(file, Jason.encode!(result) <> "\n")
            IO.write(log, "[#{idx}] ✓ #{entry} attempts=#{result.attempts} time=#{elapsed}s\n")
            %{stats | ok: stats.ok + 1, total_attempts: stats.total_attempts + result.attempts}

          {:failed, reason} ->
            elapsed = Float.round((System.monotonic_time(:millisecond) - t0) / 1000, 1)
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
            IO.write(log, "[#{idx}] ✗ #{entry}: #{reason} time=#{elapsed}s\n")
            %{stats | failed: stats.failed + 1, total_attempts: stats.total_attempts + @max_retries}
        end
      end)

    File.close(file)
    File.close(errors_file)
    File.close(log)

    processed = stats.ok + stats.failed
    avg_attempts = if processed > 0, do: Float.round(stats.total_attempts / processed, 1), else: 0

    IO.puts("""

    ══════════════════════════════════
      FINISHED
    ══════════════════════════════════
      ✓ Converted:      #{stats.ok}
      ✗ Failed:          #{stats.failed}
      Avg attempts/row:  #{avg_attempts}

      Output:  #{output_path}
      Errors:  #{errors_path}
      Log:     #{log_path}
    """)
  end
end

# ── CLI ──────────────────────────────────────────────────────────────

argv = System.argv()
thinking? = "--think" in argv
args = Enum.reject(argv, &(&1 == "--think"))

{subset, start} =
  case args do
    [s, n] -> {s, String.to_integer(n)}
    [s] -> {s, 0}
    [] -> {"educational_instruct", 0}
  end

IO.puts("""
╔════════════════════════════════════════════╗
║  Elixir SFT Converter (v3 — validated)    ║
║  compile → format → credo → test → retry  ║
╚════════════════════════════════════════════╝
  Subset:   #{subset}
  Start:    #{start}
  Thinking: #{thinking?}
  Retries:  up to 3 per row
  Output:   elixir_sft_#{subset}.jsonl
  Errors:   elixir_sft_#{subset}_errors.jsonl
""")

ElixirSFTConverter.run(subset, start, thinking?)
