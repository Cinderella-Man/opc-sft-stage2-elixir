# mix run scripts/retry_instructions.exs [file.jsonl] [--start N] [--indices 1,2,3]

alias Tunex.{CLI, LLM, Parser, JSONL, Progress}

system_prompt = ~S"""
You rewrite coding exercise instructions for Elixir.

You receive working Elixir code + tests + original instruction. Write a clean
problem-focused instruction.

Rules:
- Describe the PROBLEM, not the SOLUTION
- NEVER mention Elixir functions, modules, data structures, or patterns
- NEVER say tail-recursive, guard clause, multi-clause, pipe operator
- DO mention function name, input/output types, complexity, edge cases
- Think of it as a coding interview question

OUTPUT: ---INSTRUCTION--- / ---END---
Nothing else.
"""

# ── CLI ──────────────────────────────────────────────────────────────

argv = System.argv()
{filter, argv} = CLI.parse_indices(argv)
{filter, argv} = if filter, do: {filter, argv}, else: CLI.parse_start(argv, CLI.jsonl_path(argv) || "")

jsonl_path = CLI.jsonl_path(argv) || (IO.puts("Usage: mix run scripts/retry_instructions.exs -- [file.jsonl] [--start N]"); System.halt(1))
progress_file = jsonl_path <> ".instruction_progress"

IO.puts("Tunex Retry Instructions | #{jsonl_path} | #{CLI.scope_label(filter)}\n")

entries = JSONL.read(jsonl_path)
entry_map = Map.new(entries, fn e -> {e["index"], e} end)
all_indices = Enum.map(entries, & &1["index"]) |> Enum.sort()

target = case filter do
  nil -> all_indices
  list -> Enum.filter(list, &Map.has_key?(entry_map, &1)) |> Enum.sort()
end

done = Progress.load(progress_file)
pending = Enum.reject(target, &MapSet.member?(done, &1))
IO.puts("#{length(pending)} pending, #{MapSet.size(done)} already done\n")

if pending == [] do
  IO.puts("✓ All done. Delete #{progress_file} to re-process.")
else
  stats = %{ok: 0, fail: 0, skip: 0}

  stats = Enum.reduce(Enum.with_index(pending, 1), stats, fn {idx, num}, stats ->
    entry = entry_map[idx]
    ep = entry["entry_point"] || entry["original_entry_point"] || "?"

    unless entry["elixir_code"] && entry["elixir_test"] do
      IO.puts("  [#{num}/#{length(pending)}] idx=#{idx} #{ep} — SKIP")
      Progress.mark_done(progress_file, idx)
      %{stats | skip: stats.skip + 1}
    else
      original = entry["original_instruction"] || entry["instruction"]

      prompt = """
      Rewrite the instruction for this Elixir exercise. Describe the problem only.

      ## Original Instruction (for context)
      #{original}

      ## Working Elixir Module
      ```elixir
      #{entry["elixir_code"]}
      ```

      ## Working Tests
      ```elixir
      #{entry["elixir_test"]}
      ```

      ## Function Name
      #{ep}

      Output: ---INSTRUCTION--- / ---END---
      """

      case LLM.call(prompt, system_prompt, max_tokens: 4096) do
        {:ok, content} ->
          case Parser.parse_instruction(content) do
            {:ok, instruction} ->
              IO.puts("  [#{num}/#{length(pending)}] idx=#{idx} #{ep} — ✓ (#{String.length(instruction)} chars)")
              :persistent_term.put({:instr_update, idx}, Map.put(entry, "instruction", instruction))
              Progress.mark_done(progress_file, idx)
              %{stats | ok: stats.ok + 1}

            :error ->
              IO.puts("  [#{num}/#{length(pending)}] idx=#{idx} #{ep} — ✗ parse error")
              Progress.mark_done(progress_file, idx)
              %{stats | fail: stats.fail + 1}
          end

        _ ->
          IO.puts("  [#{num}/#{length(pending)}] idx=#{idx} #{ep} — ✗ LLM error")
          Progress.mark_done(progress_file, idx)
          %{stats | fail: stats.fail + 1}
      end
    end
  end)

  # Merge updates back
  final = Enum.map(entries, fn entry ->
    idx = entry["index"]
    try do :persistent_term.get({:instr_update, idx})
    rescue ArgumentError -> entry end
  end)

  JSONL.write(jsonl_path, final)
  pending |> Enum.each(fn idx ->
    try do :persistent_term.erase({:instr_update, idx}) rescue _ -> :ok end
  end)

  IO.puts("\n✓ Rewritten: #{stats.ok}, Failed: #{stats.fail}, Skipped: #{stats.skip}")
  IO.puts("  Progress: #{progress_file}")
end
