# mix run scripts/revalidate.exs -- [file.jsonl] [--delete]

alias Tunex.{CLI, JSONL, Workspace, Validator, Report}

argv = System.argv()
delete? = "--delete" in argv
argv = Enum.reject(argv, &(&1 == "--delete"))

jsonl_path = CLI.jsonl_path(argv) || (IO.puts("Usage: mix run scripts/revalidate.exs -- [file.jsonl] [--delete]"); System.halt(1))
mode = if delete?, do: "REPORT + DELETE", else: "REPORT ONLY"

IO.puts("Tunex Revalidate | #{jsonl_path} | #{mode}\n")

Workspace.setup("tunex_revalidate_workspace")
Workspace.update_credence("tunex_revalidate_workspace")
ws = "tunex_revalidate_workspace"

entries = JSONL.read(jsonl_path)
IO.puts("#{length(entries)} entries loaded\n")

results =
  entries
  |> Enum.with_index(1)
  |> Enum.map(fn {entry, num} ->
    idx = entry["index"]
    ep = entry["entry_point"] || entry["original_entry_point"] || "?"

    unless entry["elixir_code"] && entry["elixir_test"] do
      IO.puts("  [#{num}/#{length(entries)}] idx=#{idx} #{ep} — SKIP")
      {entry, :skip, []}
    else
      {failures, _, _} = Validator.run(entry["elixir_code"], entry["elixir_test"], ws)

      if failures == [] do
        IO.puts("  [#{num}/#{length(entries)}] idx=#{idx} #{ep} — ✓ PASS")
        {entry, :pass, []}
      else
        detail = Report.failure_summary(failures)
        IO.puts("  [#{num}/#{length(entries)}] idx=#{idx} #{ep} — ✗ FAIL #{detail}")
        {entry, :fail, failures}
      end
    end
  end)

# ── Report ─────────────────────────────────────────────────────────

passed = Enum.count(results, fn {_, s, _} -> s == :pass end)
failed = Enum.count(results, fn {_, s, _} -> s == :fail end)
skipped = Enum.count(results, fn {_, s, _} -> s == :skip end)

IO.puts("\n" <> String.duplicate("═", 60))
IO.puts("  ✓ Passed: #{passed}  ✗ Failed: #{failed}  ⏭ Skipped: #{skipped}")

stages = Report.stage_counts(results)
if stages != [] do
  IO.puts("\n  By stage: " <> Enum.map_join(stages, ", ", fn {s, c} -> "#{s}=#{c}" end))
end

rules = Report.credence_rule_counts(results)
if rules != [] do
  IO.puts("  By rule:  " <> Enum.map_join(rules, ", ", fn {r, c} -> "#{r}=#{c}" end))
end

failed_indices = results |> Enum.filter(fn {_, s, _} -> s == :fail end) |> Enum.map(fn {e, _, _} -> e["index"] end) |> Enum.sort()
if failed_indices != [], do: IO.puts("\n  Failed indices: #{Enum.join(failed_indices, ", ")}")

IO.puts(String.duplicate("═", 60))

if delete? and failed > 0 do
  kept = results |> Enum.reject(fn {_, s, _} -> s == :fail end) |> Enum.map(fn {e, _, _} -> e end)
  JSONL.write(jsonl_path, kept)
  IO.puts("\n  Removed #{failed} entries. #{length(kept)} remaining.")
  IO.puts("  Run the converter to regenerate deleted indices.")
end
