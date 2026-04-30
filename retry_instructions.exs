#!/usr/bin/env elixir

# Regenerate instructions for existing JSONL entries.
#
# Reads each entry, sends the Elixir code + tests + original Python instruction
# to the LLM, and gets back a clean problem-description-only instruction.
# No code changes. No validation. Just instruction rewriting.
#
# Resumable: writes completed indices to a .progress file. Stop and restart
# at any time — already-processed indices are skipped.
#
# Usage:
#   elixir retry_instructions.exs elixir_sft_educational_instruct.jsonl
#   elixir retry_instructions.exs elixir_sft_educational_instruct.jsonl --start 200
#   elixir retry_instructions.exs elixir_sft_educational_instruct.jsonl --indices 201,218,222

Mix.install([
  {:req, "~> 0.5"},
  {:jason, "~> 1.4"}
])

defmodule InstructionRetrier do
  @llama_url "http://127.0.0.1:8020/v1/chat/completions"

  @system_prompt """
  You rewrite coding exercise instructions for Elixir.

  You will receive an Elixir module (working code), its tests, and either the
  original Python instruction or a previous Elixir instruction that may be too
  prescriptive. Your job is to write a clean, problem-focused instruction.

  Rules:
  - Describe the PROBLEM, not the SOLUTION
  - Say WHAT to compute and what edge cases to handle
  - NEVER mention specific Elixir functions, modules, or data structures
    (no Enum.reduce, MapSet, String.graphemes, Enum.scan, pattern matching, etc.)
  - NEVER dictate recursion style, accumulator patterns, or code structure
  - NEVER say "tail-recursive", "guard clause", "multi-clause", "pipe operator"
  - NEVER reference the implementation in any way
  - DO mention the expected function name and its input/output types
  - DO mention expected time/space complexity if the problem warrants it
  - DO mention edge case behavior (empty input, negative numbers, unicode, etc.)
  - DO mention what to return for invalid or boundary inputs
  - Think of it as a coding interview question — problem + constraints, not answer

  Good example:
    "Write a function named `find_second_max/1` that accepts a list of integers
    and returns the second largest distinct value. Return `nil` if there are
    fewer than two distinct values in the list."

  Bad example:
    "Use Enum.uniq/1 to deduplicate, then pattern match on [_, _ | _] to enforce
    minimum length, and use a single-pass Enum.reduce to track the top two values."

  OUTPUT FORMAT — exactly:

  ---INSTRUCTION---
  (the rewritten instruction — just the problem description, nothing else)
  ---END---

  Nothing else. No markdown. No explanation. No preamble.
  """

  defp log(indent, msg), do: IO.puts(String.duplicate("  ", indent) <> msg)

  # ── LLM ────────────────────────────────────────────────────────────

  defp call_llm(user_prompt) do
    body = %{
      messages: [
        %{role: "system", content: @system_prompt},
        %{role: "user", content: user_prompt}
      ],
      model: "qwen3.6-27b-autoround",
      max_tokens: 4096
    }

    case Req.post(@llama_url, json: body, receive_timeout: 300_000) do
      {:ok, %{status: 200, body: resp}} ->
        content = resp["choices"] |> List.first() |> get_in(["message", "content"]) |> to_string() |> String.trim()
        if content != "", do: {:ok, content}, else: {:empty, "no content"}

      {:ok, %{status: s}} -> {:error, "HTTP #{s}"}
      {:error, err} -> {:error, inspect(err, limit: 100)}
    end
  end

  defp parse_instruction(content) do
    content = content |> String.replace(~r/^```\w*\n?/, "") |> String.replace(~r/\n?```$/, "") |> String.trim()

    with [_, rest] <- String.split(content, "---INSTRUCTION---", parts: 2) do
      instruction = rest |> String.split("---END---", parts: 2) |> List.first() |> String.trim()
      if instruction != "", do: {:ok, instruction}, else: :error
    else
      _ -> :error
    end
  end

  # ── Progress Tracking ──────────────────────────────────────────────

  defp progress_path(jsonl_path), do: jsonl_path <> ".instruction_progress"

  defp load_progress(jsonl_path) do
    path = progress_path(jsonl_path)
    if File.exists?(path) do
      path
      |> File.read!()
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&String.to_integer/1)
      |> MapSet.new()
    else
      MapSet.new()
    end
  end

  defp mark_done(jsonl_path, idx) do
    File.write!(progress_path(jsonl_path), "#{idx}\n", [:append])
  end

  # ── Rewrite One Entry ─────────────────────────────────────────────

  defp rewrite_instruction(entry) do
    original_python = entry["original_instruction"] || entry["instruction"]

    prompt = """
    Rewrite the instruction for this Elixir exercise. Read the working code and
    tests to understand what the function does, then write a clean problem
    description. Do NOT describe the implementation.

    ## Original Python Instruction (for context on the problem)
    #{original_python}

    ## Working Elixir Module
    ```elixir
    #{entry["elixir_code"]}
    ```

    ## Working Tests
    ```elixir
    #{entry["elixir_test"]}
    ```

    ## Function Name
    #{entry["entry_point"] || entry["original_entry_point"]}

    Write the instruction as a coding interview question. Describe the problem,
    input/output contract, and edge cases. Never mention implementation details.

    Output: ---INSTRUCTION--- / ---END---
    """

    case call_llm(prompt) do
      {:ok, content} ->
        case parse_instruction(content) do
          {:ok, instruction} -> {:ok, instruction}
          :error -> {:error, "could not parse"}
        end

      {:empty, _} -> {:error, "empty response"}
      {:error, reason} -> {:error, reason}
    end
  end

  # ── Main ───────────────────────────────────────────────────────────

  def run(jsonl_path, filter_indices) do
    unless File.exists?(jsonl_path) do
      IO.puts("Error: #{jsonl_path} not found")
      System.halt(1)
    end

    log(0, "Loading entries from #{jsonl_path}")
    entries =
      jsonl_path
      |> File.stream!()
      |> Stream.map(&String.trim/1)
      |> Stream.reject(&(&1 == ""))
      |> Stream.map(fn line -> case Jason.decode(line) do {:ok, e} -> e; _ -> nil end end)
      |> Stream.reject(&is_nil/1)
      |> Enum.to_list()

    log(1, "#{length(entries)} entries loaded")

    # Build index → position map for fast lookup
    entry_map = Map.new(entries, fn e -> {e["index"], e} end)
    all_indices = Enum.map(entries, & &1["index"]) |> Enum.sort()

    # Determine which to process
    target_indices = case filter_indices do
      nil -> all_indices
      list -> Enum.filter(list, &Map.has_key?(entry_map, &1)) |> Enum.sort()
    end

    # Load progress (already-done indices)
    done = load_progress(jsonl_path)
    pending = Enum.reject(target_indices, &MapSet.member?(done, &1))

    log(1, "#{length(pending)} pending (#{MapSet.size(done)} already done, #{length(target_indices)} targeted)")

    if pending == [] do
      log(0, "\n✓ All targeted instructions already rewritten. Nothing to do.")
      log(0, "  Delete #{progress_path(jsonl_path)} to re-process all.")
    else
      stats = %{rewritten: 0, failed: 0, skipped: 0}

      stats =
        pending
        |> Enum.with_index(1)
        |> Enum.reduce(stats, fn {idx, num}, stats ->
          entry = entry_map[idx]
          ep = entry["entry_point"] || entry["original_entry_point"] || "?"

          unless entry["elixir_code"] && entry["elixir_test"] do
            IO.puts("  [#{num}/#{length(pending)}] idx=#{idx} #{ep} — SKIP (missing code/test)")
            mark_done(jsonl_path, idx)
            %{stats | skipped: stats.skipped + 1}
          else
            IO.write("  [#{num}/#{length(pending)}] idx=#{idx} #{ep} — ")

            case rewrite_instruction(entry) do
              {:ok, new_instruction} ->
                IO.puts("✓ (#{String.length(new_instruction)} chars)")
                # Update in the map
                updated = Map.put(entry, "instruction", new_instruction)
                :persistent_term.put({:updated_entry, idx}, updated)
                mark_done(jsonl_path, idx)
                %{stats | rewritten: stats.rewritten + 1}

              {:error, reason} ->
                IO.puts("✗ #{reason}")
                mark_done(jsonl_path, idx)
                %{stats | failed: stats.failed + 1}
            end
          end
        end)

      # Write updated JSONL — merge updates back
      log(0, "\nWriting updated entries to #{jsonl_path}")
      final_entries =
        Enum.map(entries, fn entry ->
          idx = entry["index"]
          try do
            :persistent_term.get({:updated_entry, idx})
          rescue
            ArgumentError -> entry
          end
        end)

      tmp_path = jsonl_path <> ".tmp"
      File.write!(tmp_path, Enum.map_join(final_entries, "\n", &Jason.encode!/1) <> "\n")
      File.rename!(tmp_path, jsonl_path)

      # Clean up persistent terms
      pending |> Enum.each(fn idx ->
        try do :persistent_term.erase({:updated_entry, idx}) rescue _ -> :ok end
      end)

      IO.puts("""

      ══════════════════════════════════
        INSTRUCTION RETRY REPORT
      ══════════════════════════════════
        📝 Rewritten:   #{stats.rewritten}
        ✗ Failed:       #{stats.failed}
        ⏭ Skipped:      #{stats.skipped}
        Total entries:  #{length(entries)}

        Progress file:  #{progress_path(jsonl_path)}
        (delete it to re-process, or run again to continue)
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
  _ -> IO.puts("Usage: elixir retry_instructions.exs [file.jsonl] [--start N] [--indices 1,2,3]"); System.halt(1)
end

# Resolve --start into actual indices
filter_indices = case filter_indices do
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
  is_list(filter_indices) and length(filter_indices) > 10 -> "#{length(filter_indices)} entries"
  is_list(filter_indices) -> "indices: #{Enum.join(filter_indices, ", ")}"
end

IO.puts("""
╔═══════════════════════════════════════════════════════╗
║  Instruction Rewriter                                  ║
║  Rewrite instructions to problem-description only      ║
╚═══════════════════════════════════════════════════════╝
  File:   #{jsonl_path}
  Scope:  #{scope}
""")

InstructionRetrier.run(jsonl_path, filter_indices)
