#!/usr/bin/env elixir

# Convert OpenCoder SFT dataset to Elixir — rewrites BOTH instruction and code
#
# Usage:
#   elixir convert.exs [subset] [start_index] [--think]
#
# Examples:
#   elixir convert.exs educational_instruct
#   elixir convert.exs educational_instruct 500
#   elixir convert.exs evol_instruct 0 --think
#
# Subsets: educational_instruct, evol_instruct, mceval_instruct, package_instruct

Mix.install([
  {:req, "~> 0.5"},
  {:explorer, "~> 0.10"},
  {:jason, "~> 1.4"}
])

defmodule ElixirSFTConverter do
  @llama_url "http://127.0.0.1:8080/v1/chat/completions"
  @dataset_base "https://huggingface.co/datasets/OpenCoder-LLM/opc-sft-stage2/resolve/refs%2Fconvert%2Fparquet"

  @system_prompt """
  You convert Python coding exercises into Elixir coding exercises.

  You receive a Python problem (instruction + solution + tests) and you produce
  an equivalent Elixir version where BOTH the instruction and the code are
  rewritten for Elixir.

  When rewriting the INSTRUCTION:
  - Replace all Python references with Elixir equivalents
  - Replace Python types: dict→map, list→list, tuple→tuple, set→MapSet, string→string/binary
  - Replace Python concepts: class→module, decorator→behaviour/macro, list comprehension→Enum/for comprehension, "in-place"→use accumulators or reduce
  - Adapt complexity notes for Elixir data structures (linked lists are O(n) access; no mutation; use recursion with accumulators instead of loops)
  - Remove any mention of Python entirely
  - Keep the core algorithmic problem the same

  When writing the CODE:
  - Write idiomatic Elixir: pattern matching, pipe operator, guards, Enum/Stream, recursion with accumulators
  - Do NOT transliterate Python line-by-line
  - Put the solution in a module with @doc and @spec
  - Include ExUnit tests matching the original assertions

  OUTPUT FORMAT — use exactly these delimiters:

  ---INSTRUCTION---
  (rewritten Elixir instruction)
  ---CODE---
  (Elixir module + ExUnit tests)
  ---END---

  Output NOTHING else. No explanations, no markdown, no preamble.
  """

  def run(subset, start_index, thinking?) do
    parquet_path = ensure_downloaded(subset)
    output_path = "elixir_sft_#{subset}.jsonl"
    log_path = "convert_debug_#{subset}.log"

    max_tokens = if thinking?, do: 16_384, else: 4_096

    IO.puts("Loading #{parquet_path}...")
    df = Explorer.DataFrame.from_parquet!(parquet_path)
    total = Explorer.DataFrame.n_rows(df)
    IO.puts("#{total} rows. Starting at #{start_index}. max_tokens=#{max_tokens}\n")

    file = File.open!(output_path, [:append, :utf8])
    log = File.open!(log_path, [:append, :utf8])

    counters = %{ok: 0, skip: 0, parse_fail: 0, error: 0}

    counters =
      df
      |> Explorer.DataFrame.slice(start_index, total - start_index)
      |> Explorer.DataFrame.to_rows()
      |> Enum.with_index(start_index)
      |> Enum.reduce(counters, fn {row, idx}, acc ->
        t0 = System.monotonic_time(:millisecond)
        entry = row["entry_point"] || "unknown"
        IO.write("\r[#{idx + 1}/#{total}] #{entry}...                    ")

        {status, acc} =
          case convert_one(row, thinking?, max_tokens) do
            {:ok, result} ->
              IO.write(file, Jason.encode!(result) <> "\n")
              elapsed_s = Float.round((System.monotonic_time(:millisecond) - t0) / 1000, 1)
              IO.write("\r[#{idx + 1}/#{total}] ✓ #{entry} (#{String.length(result.elixir_code)} chars, #{elapsed_s}s)\n")
              {:ok, %{acc | ok: acc.ok + 1}}

            {:parse_fail, raw_content} ->
              # Save anyway with raw content so it's not lost
              fallback = %{
                instruction: row["instruction"],
                elixir_code: raw_content,
                python_code: row["code"],
                entry_point: entry,
                parse_failed: true
              }
              IO.write(file, Jason.encode!(fallback) <> "\n")
              elapsed_s = Float.round((System.monotonic_time(:millisecond) - t0) / 1000, 1)
              IO.write("\r[#{idx + 1}/#{total}] ~ #{entry} (parse fail, saved raw, #{elapsed_s}s)\n")
              IO.write(log, "[#{idx}] #{entry} PARSE_FAIL: delimiters missing\n")
              {:parse_fail, %{acc | parse_fail: acc.parse_fail + 1}}

            {:skip, reason, debug} ->
              elapsed_s = Float.round((System.monotonic_time(:millisecond) - t0) / 1000, 1)
              IO.write("\r[#{idx + 1}/#{total}] ⚠ #{entry}: #{reason} (#{elapsed_s}s)\n")
              IO.write(log, "[#{idx}] #{entry} SKIP: #{reason} | #{debug}\n")
              {:skip, %{acc | skip: acc.skip + 1}}

            {:error, reason} ->
              elapsed_s = Float.round((System.monotonic_time(:millisecond) - t0) / 1000, 1)
              IO.write("\r[#{idx + 1}/#{total}] ✗ #{entry}: #{reason} (#{elapsed_s}s)\n")
              IO.write(log, "[#{idx}] #{entry} ERROR: #{reason}\n")
              {:error, %{acc | error: acc.error + 1}}
          end

        acc
      end)

    File.close(file)
    File.close(log)

    IO.puts("""
    \n════════════════════════════════
    FINISHED
    ════════════════════════════════
      ✓ Converted: #{counters.ok}
      ~ Parse fail: #{counters.parse_fail} (saved raw)
      ⚠ Skipped:   #{counters.skip}
      ✗ Errors:    #{counters.error}

      Output: #{output_path}
      Log:    #{log_path}
    """)
  end

  defp convert_one(row, thinking?, max_tokens) do
    instruction = row["instruction"]
    python_code = row["code"]
    entry_point = row["entry_point"]
    testcases = row["testcase"]

    prefix = unless thinking?, do: "/no_think\n", else: ""

    user_prompt = """
    #{prefix}Convert this Python exercise to Elixir. Rewrite both the instruction and the code.

    ## Python Instruction
    #{instruction}

    ## Python Solution
    ```python
    #{python_code}
    ```

    ## Python Tests
    #{format_tests(testcases)}

    The main Elixir function should be named `#{snake_name(entry_point)}`.
    Remember: output ONLY the ---INSTRUCTION--- / ---CODE--- / ---END--- structure.
    """

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
        finish = choice["finish_reason"]
        content = (msg["content"] || "") |> String.trim()
        reasoning = (msg["reasoning_content"] || "") |> String.trim()
        usage = resp["usage"]
        comp_tokens = if usage, do: usage["completion_tokens"], else: nil

        cond do
          # Got content — try to parse structured output
          String.length(content) > 0 ->
            case parse_output(content) do
              {:ok, new_instruction, elixir_code} ->
                {:ok, %{
                  instruction: new_instruction,
                  elixir_code: elixir_code,
                  original_instruction: instruction,
                  python_code: python_code,
                  entry_point: snake_name(entry_point),
                  original_entry_point: entry_point,
                  finish_reason: finish,
                  completion_tokens: comp_tokens
                }}

              :error ->
                # Delimiters missing but there might still be usable Elixir code
                {:parse_fail, strip_fences(content)}
            end

          # Thinking model exhausted token budget
          finish == "length" and String.length(reasoning) > 0 ->
            {:skip, "thinking used all #{comp_tokens} tokens",
             "reasoning=#{String.length(reasoning)} chars"}

          true ->
            {:skip, "empty response, finish=#{finish}",
             "content=#{String.length(content)} reasoning=#{String.length(reasoning)}"}
        end

      {:ok, %{status: status, body: body}} ->
        {:error, "HTTP #{status}: #{inspect(body, limit: 200)}"}

      {:error, err} ->
        {:error, "request: #{inspect(err, limit: 200)}"}
    end
  end

  defp parse_output(content) do
    content =
      content
      |> String.replace(~r/^```\w*\n?/, "")
      |> String.replace(~r/\n?```$/, "")
      |> String.trim()

    with [_, after_instr] <- String.split(content, "---INSTRUCTION---", parts: 2),
         [instruction, after_code] <- String.split(after_instr, "---CODE---", parts: 2) do
      code =
        after_code
        |> String.split("---END---", parts: 2)
        |> List.first()
        |> strip_fences()
        |> String.trim()

      instruction = String.trim(instruction)

      if instruction != "" and code != "" do
        {:ok, instruction, code}
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
    |> String.replace(~r/\n?```$/m, "")
    |> String.trim()
  end

  defp ensure_downloaded(subset) do
    filename = "#{subset}_train.parquet"

    unless File.exists?(filename) do
      url = "#{@dataset_base}/#{subset}/train/0000.parquet"
      IO.puts("Downloading #{subset}...")
      IO.puts("URL: #{url}")

      case Req.get(url, into: File.stream!(filename), receive_timeout: 300_000) do
        {:ok, %{status: 200}} -> IO.puts("✓ Downloaded #{filename}")
        {:ok, %{status: s}} -> File.rm(filename); raise "Download failed: HTTP #{s}"
        {:error, e} -> File.rm(filename); raise "Download failed: #{inspect(e)}"
      end
    end

    filename
  end

  defp format_tests(tests) when is_list(tests), do: Enum.join(tests, "\n")
  defp format_tests(tests), do: to_string(tests)

  defp snake_name(name), do: name |> String.downcase() |> String.replace(~r/[^a-z0-9_]/, "_")
end

# --- CLI ---
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
╔══════════════════════════════════════════╗
║   Elixir SFT Converter (v2)             ║
║   Rewrites instruction + code            ║
╚══════════════════════════════════════════╝
  Subset:   #{subset}
  Start:    #{start}
  Thinking: #{thinking?}
  Output:   elixir_sft_#{subset}.jsonl
""")

ElixirSFTConverter.run(subset, start, thinking?)
