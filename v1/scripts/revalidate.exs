# mix run scripts/revalidate.exs [file.jsonl] [--delete]

alias Tunex.{CLI, JSONL, Workspace, Validator, Report}

argv = System.argv()
delete? = "--delete" in argv
argv = Enum.reject(argv, &(&1 == "--delete"))

jsonl_path =
  CLI.jsonl_path(argv) ||
    (IO.puts("Usage: mix run scripts/revalidate.exs -- [file.jsonl] [--delete]")
     System.halt(1))

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
    total = length(entries)
    prefix = "  [#{num}/#{total}] idx=#{idx} #{ep}"

    unless entry["elixir_code"] && entry["elixir_test"] do
      IO.puts("#{prefix} — SKIP (missing code or test)")
      {entry, :skip, []}
    else
      # Step 1: Try credence auto-fix on module + propagate renames to tests
      {fix_status, module_code, test_code} =
        case Validator.apply_credence_fix(entry["elixir_code"], entry["elixir_test"], ws) do
          {:ok, fixed_mod, fixed_test} -> {:ok, fixed_mod, fixed_test}
          {:error, orig_mod, orig_test} -> {:error, orig_mod, orig_test}
        end

      mod_changed? = String.trim(module_code) != String.trim(entry["elixir_code"])
      test_changed? = String.trim(test_code) != String.trim(entry["elixir_test"])
      credence_fixed? = mod_changed? or test_changed?

      if credence_fixed? do
        changes = [if(mod_changed?, do: "module"), if(test_changed?, do: "tests")]
                  |> Enum.reject(&is_nil/1)
                  |> Enum.join(" + ")
        IO.puts("#{prefix} — credence auto-fixed #{changes}, validating...")
      end

      if fix_status == :error and not credence_fixed? do
        IO.puts("#{prefix} — credence fix failed (compile error), validating original...")
      end

      # Step 2: Full validation on the (potentially fixed) code + tests
      {failures, final_mod, final_test} =
        Validator.run(module_code, test_code, ws)

      final_changed? =
        String.trim(final_mod) != String.trim(entry["elixir_code"]) or
          String.trim(final_test) != String.trim(entry["elixir_test"])

      if failures == [] do
        updated =
          entry
          |> Map.put("elixir_code", final_mod)
          |> Map.put("elixir_test", final_test)

        if final_changed? do
          IO.puts("#{prefix} — ✓ FIXED (auto-fixed)")
          {updated, :fixed, []}
        else
          IO.puts("#{prefix} — ✓ PASS")
          {updated, :pass, []}
        end
      else
        detail = Report.failure_summary(failures)
        IO.puts("#{prefix} — ✗ FAIL #{detail}")

        # Flag if credence fix may have caused a regression
        if credence_fixed? do
          test_broke? = Enum.any?(failures, fn {stage, _} -> stage == :test end)

          if test_broke? do
            IO.puts("    ⚠ WARNING: credence fix changed code AND tests now fail")
            IO.puts("      This may be a credence fix regression — tests may have passed before")
          end
        end

        # Print detailed failure info for each stage
        for {stage, msg} <- failures do
          IO.puts("    ── #{stage} ──")

          lines = String.split(msg, "\n")
          truncated? = length(lines) > 20

          lines
          |> Enum.take(20)
          |> Enum.each(fn line -> IO.puts("    #{line}") end)

          if truncated? do
            IO.puts("    ... (#{length(lines) - 20} more lines)")
          end
        end

        IO.puts("")
        {entry, :fail, failures}
      end
    end
  end)

# ── Report ─────────────────────────────────────────────────────────

passed = Enum.count(results, fn {_, s, _} -> s == :pass end)
fixed = Enum.count(results, fn {_, s, _} -> s == :fixed end)
failed = Enum.count(results, fn {_, s, _} -> s == :fail end)
skipped = Enum.count(results, fn {_, s, _} -> s == :skip end)

IO.puts("\n" <> String.duplicate("═", 60))
IO.puts("  ✓ Passed: #{passed}  🔧 Fixed: #{fixed}  ✗ Failed: #{failed}  ⏭ Skipped: #{skipped}")

stages = Report.stage_counts(results)

if stages != [] do
  IO.puts(
    "\n  By stage: " <> Enum.map_join(stages, ", ", fn {s, c} -> "#{s}=#{c}" end)
  )
end

rules = Report.credence_rule_counts(results)

if rules != [] do
  IO.puts(
    "  By rule:  " <> Enum.map_join(rules, ", ", fn {r, c} -> "#{r}=#{c}" end)
  )
end

failed_indices =
  results
  |> Enum.filter(fn {_, s, _} -> s == :fail end)
  |> Enum.map(fn {e, _, _} -> e["index"] end)
  |> Enum.sort()

if failed_indices != [],
  do: IO.puts("\n  Failed indices: #{Enum.join(failed_indices, ", ")}")

IO.puts(String.duplicate("═", 60))

# ── Write back ─────────────────────────────────────────────────────

needs_write? = fixed > 0 or (delete? and failed > 0)

if needs_write? do
  final_entries =
    results
    |> Enum.reject(fn {_, s, _} -> delete? and s == :fail end)
    |> Enum.map(fn {e, _, _} -> e end)

  JSONL.write(jsonl_path, final_entries)

  if fixed > 0, do: IO.puts("\n  Updated #{fixed} entries with auto-fixed code.")

  if delete? and failed > 0 do
    IO.puts("  Removed #{failed} unfixable entries. #{length(final_entries)} remaining.")
    IO.puts("  Run the converter to regenerate deleted indices.")
  end
end
