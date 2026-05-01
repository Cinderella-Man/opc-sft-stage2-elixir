# mix run scripts/retry_implementations.exs -- [file.jsonl] [--start N] [--indices 1,2,3]

alias Tunex.{CLI, LLM, Parser, JSONL, Progress, Workspace, Validator, Report}

max_retries = Application.get_env(:tunex, :max_retries, 5)
max_refine = Application.get_env(:tunex, :max_refine_retries, 5)

fix_prompt = ~S"""
Expert Elixir programmer. Fix the code so it passes ALL checks:
compile (--warnings-as-errors), format, credo, credence, tests.
Fix issues — don't rewrite from scratch. Keep as much original as possible.

Use descriptive params (never single letters). Prefix unused params with _ per clause.
Use ? suffix for booleans (not is_ prefix). Use Enum.reduce not List.foldl.
Use Enum.map_join not map|>join. Use max/min not manual if comparisons.

Pitfalls: unused variable→_ per clause; undefined→renamed to _name but still used;
descriptive_names→rename in ALL clauses.

Keep same module/function names and instruction.
Output: ---MODULE--- / ---TEST--- / ---END---
"""

review_prompt = ~S"""
Expert Elixir reviewer. Actionable feedback on edge cases, idiom, correctness,
performance, missing tests. If excellent: "NO_ISSUES_FOUND".
Do NOT suggest catch-all raise clauses or unnecessary type guards.
"""

refine_prompt = ~S"""
Apply ALL suggestions. Keep same module/function names. Do NOT change instruction.
Output: ---MODULE--- / ---TEST--- / ---END---
"""

# ── Fix + Refine Loops ───────────────────────────────────────────────

defmodule FixLoop do
  def fix(entry, failures, opts, ws, attempt \\ 1)
  def fix(_entry, _failures, _opts, _ws, attempt) when attempt > 5,
    do: {:failed, "exceeded fix retries"}

  def fix(entry, failures, opts, ws, attempt) do
    prompt = """
    Fix this Elixir code.
    ## Instruction\n#{entry["instruction"]}
    ## Current Module (HAS ERRORS)\n```elixir\n#{entry["elixir_code"]}\n```
    ## Current Tests\n```elixir\n#{entry["elixir_test"]}\n```
    ## Errors\n#{Tunex.Report.format_errors(failures)}
    Output: ---MODULE--- / ---TEST--- / ---END---
    """

    fix_sys = Application.get_env(:tunex, :fix_prompt, opts[:fix_prompt])

    case Tunex.LLM.call(prompt, fix_sys, opts) do
      {:ok, content} ->
        case Tunex.Parser.parse_module_test(content) do
          {:ok, mod, test} ->
            {new_fails, fm, ft} = Tunex.Validator.run(mod, test, ws)
            if new_fails == [] do
              updated = entry |> Map.put("elixir_code", fm) |> Map.put("elixir_test", ft)
              refine(updated, opts, ws)
            else
              fix(entry, new_fails, opts, ws, attempt + 1)
            end
          :error -> fix(entry, failures, opts, ws, attempt + 1)
        end
      {:empty, _} -> fix(entry, failures, opts, ws, attempt + 1)
      {:error, reason} -> {:failed, reason}
    end
  end

  def refine(entry, opts, ws) do
    review_sys = opts[:review_prompt]
    review = """
    Review this Elixir code.
    ## Instruction\n#{entry["instruction"]}
    ## Module\n```elixir\n#{entry["elixir_code"]}\n```
    ## Tests\n```elixir\n#{entry["elixir_test"]}\n```
    If excellent: NO_ISSUES_FOUND
    """
    case Tunex.LLM.call(review, review_sys, opts) do
      {:ok, fb} ->
        if String.contains?(fb, "NO_ISSUES_FOUND"),
          do: {:ok, entry},
          else: do_refine(entry, fb, nil, 1, opts, ws)
      _ -> {:ok, entry}
    end
  end

  defp do_refine(entry, _fb, _prev, attempt, _opts, _ws) when attempt > 5, do: {:ok, entry}

  defp do_refine(entry, fb, prev_errors, attempt, opts, ws) do
    refine_sys = opts[:refine_prompt]
    prompt = if prev_errors do
      {prev, errs} = prev_errors
      """
      Refinement had errors. Fix.
      ## Working Module\n```elixir\n#{entry["elixir_code"]}\n```
      ## Working Tests\n```elixir\n#{entry["elixir_test"]}\n```
      ## Previous (ERRORS)\n#{prev}
      ## Errors\n#{Tunex.Report.format_errors(errs)}
      Output: ---MODULE--- / ---TEST--- / ---END---
      """
    else
      """
      Apply feedback.
      ## Module\n```elixir\n#{entry["elixir_code"]}\n```
      ## Tests\n```elixir\n#{entry["elixir_test"]}\n```
      ## Feedback\n#{fb}
      Output: ---MODULE--- / ---TEST--- / ---END---
      """
    end

    case Tunex.LLM.call(prompt, refine_sys, opts) do
      {:ok, content} ->
        case Tunex.Parser.parse_module_test(content) do
          {:ok, mod, test} ->
            {fails, fm, ft} = Tunex.Validator.run(mod, test, ws)
            if fails == [] do
              {:ok, entry |> Map.put("elixir_code", fm) |> Map.put("elixir_test", ft) |> Map.put("refined", true)}
            else
              do_refine(entry, fb, {content, fails}, attempt + 1, opts, ws)
            end
          :error -> do_refine(entry, fb, nil, attempt + 1, opts, ws)
        end
      _ -> {:ok, entry}
    end
  end
end

# ── CLI ──────────────────────────────────────────────────────────────

argv = System.argv()
{filter, argv} = CLI.parse_indices(argv)
{filter, argv} = if filter, do: {filter, argv}, else: CLI.parse_start(argv, CLI.jsonl_path(argv) || "")

jsonl_path = CLI.jsonl_path(argv) || (IO.puts("Usage: mix run scripts/retry_implementations.exs -- [file.jsonl] [--start N]"); System.halt(1))
errors_path = CLI.errors_path(jsonl_path)
progress_file = jsonl_path <> ".impl_progress"

IO.puts("Tunex Retry Implementations | #{jsonl_path} | #{CLI.scope_label(filter)}\n")

Workspace.setup("tunex_retry_impl_workspace")
Workspace.update_credence("tunex_retry_impl_workspace")
ws = "tunex_retry_impl_workspace"

entries = JSONL.read(jsonl_path)
entry_map = Map.new(entries, fn e -> {e["index"], e} end)
all_indices = Enum.map(entries, & &1["index"]) |> Enum.sort()

target = case filter do nil -> all_indices; list -> Enum.filter(list, &Map.has_key?(entry_map, &1)) |> Enum.sort() end
done = Progress.load(progress_file)
pending = Enum.reject(target, &MapSet.member?(done, &1))
IO.puts("#{length(pending)} pending, #{MapSet.size(done)} done\n")

if pending == [] do
  IO.puts("✓ All done. Delete #{progress_file} to re-process.")
else
  err_file = JSONL.open_append(errors_path)
  opts = [max_tokens: 12_288, fix_prompt: fix_prompt, review_prompt: review_prompt, refine_prompt: refine_prompt]
  stats = %{passed: 0, fixed: 0, failed: 0, skipped: 0}
  failed_indices = []

  {failed_indices, stats} =
    pending
    |> Enum.with_index(1)
    |> Enum.reduce({failed_indices, stats}, fn {idx, num}, {fail_acc, stats} ->
      entry = entry_map[idx]
      ep = entry["entry_point"] || entry["original_entry_point"] || "?"
      t0 = System.monotonic_time(:millisecond)

      unless entry["elixir_code"] && entry["elixir_test"] do
        IO.puts("  [#{num}/#{length(pending)}] idx=#{idx} #{ep} — SKIP")
        Progress.mark_done(progress_file, idx)
        {fail_acc, %{stats | skipped: stats.skipped + 1}}
      else
        {failures, _, _} = Validator.run(entry["elixir_code"], entry["elixir_test"], ws)
        elapsed_fn = fn -> Float.round((System.monotonic_time(:millisecond) - t0) / 1000, 1) end

        if failures == [] do
          IO.puts("  [#{num}/#{length(pending)}] idx=#{idx} #{ep} — ✓ passes (#{elapsed_fn.()}s)")
          Progress.mark_done(progress_file, idx)
          {fail_acc, %{stats | passed: stats.passed + 1}}
        else
          detail = Report.failure_summary(failures)
          IO.puts("  [#{num}/#{length(pending)}] idx=#{idx} #{ep} — fixing #{detail}...")

          case FixLoop.fix(entry, failures, opts, ws) do
            {:ok, updated} ->
              IO.puts("    ✓ fixed (#{elapsed_fn.()}s)")
              :persistent_term.put({:impl_update, idx}, updated)
              Progress.mark_done(progress_file, idx)
              {fail_acc, %{stats | fixed: stats.fixed + 1}}

            {:failed, reason} ->
              IO.puts("    ✗ FAILED: #{reason} (#{elapsed_fn.()}s)")
              JSONL.append_to(err_file, Map.put(entry, "impl_retry_failure", reason))
              Progress.mark_done(progress_file, idx)
              {[idx | fail_acc], %{stats | failed: stats.failed + 1}}
          end
        end
      end
    end)

  File.close(err_file)

  # Rebuild: merge updates, remove failures
  failed_set = MapSet.new(failed_indices)
  final = entries
  |> Enum.reject(fn e -> MapSet.member?(failed_set, e["index"]) end)
  |> Enum.map(fn e ->
    try do :persistent_term.get({:impl_update, e["index"]})
    rescue ArgumentError -> e end
  end)

  JSONL.write(jsonl_path, final)
  pending |> Enum.each(fn idx ->
    try do :persistent_term.erase({:impl_update, idx}) rescue _ -> :ok end
  end)

  IO.puts("\n✓ Passed: #{stats.passed}, Fixed: #{stats.fixed}, Failed: #{stats.failed}, Skipped: #{stats.skipped}")
  IO.puts("  Output: #{jsonl_path}, Errors: #{errors_path}")
end
