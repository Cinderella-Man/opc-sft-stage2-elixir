# mix run scripts/convert.exs [subset] [--workers N]

require Logger

alias Tunex.{CLI, Dataset, LLM, Parser, Progress, Workspace, Validator, JSONL, Report}

max_retries = Application.get_env(:tunex, :max_retries, 5)
max_refine = Application.get_env(:tunex, :max_refine_retries, 5)
max_tokens = Application.get_env(:tunex, :max_tokens, 12_288)

# ── Prompts ──────────────────────────────────────────────────────────

system_prompt = ~S"""
You convert Python coding exercises into Elixir coding exercises.
You rewrite BOTH the instruction and the code.

INSTRUCTION rules: describe the PROBLEM, not the SOLUTION. Never mention
specific Elixir functions, data structures, or recursion styles. Mention
function name, input/output contract, complexity, and edge case behavior.

Idiomatic Elixir: pattern matching, multi-clause functions, pipes, guards,
@doc/@spec. Descriptive parameter names (NEVER single letters). Prefix
unused params with _ independently per clause.

NAMING: If the Python function uses `is_` prefix (e.g. `is_palindrome`),
ALWAYS rename it to `?` suffix in Elixir (e.g. `palindrome?`).
Use the function name given in the prompt — it already has this applied.
Update ALL call sites: module code, tests, and instruction must all use
the new `?` name. NEVER use `is_` prefix for any function.

Anti-patterns: single-letter names, Enum.at in loops, ++ in loops,
length in guards, is_ prefix (use ?), Enum.count/1 (use length/1),
List.foldl (use Enum.reduce), Enum.map |> Enum.max/min/sum/join,
catch-all raise clauses, manual max/min with if.

OUTPUT: ---INSTRUCTION--- / ---MODULE--- / ---TEST--- / ---END---
Nothing else. No markdown fences.
"""

review_prompt = ~S"""
Expert Elixir reviewer. Actionable feedback on edge cases, idiom, correctness,
performance, missing tests. If excellent: "NO_ISSUES_FOUND".
Do NOT suggest catch-all raise clauses or unnecessary type guards.
Check: any function using is_ prefix? Must use ? suffix instead (e.g. palindrome? not is_palindrome).
Tests must call the ? version too.
"""

refine_prompt = ~S"""
Apply ALL suggestions. Instruction = problem only, never implementation.
Keep same module/function names. Code must compile.
If renaming is_ to ?, update ALL call sites: module, tests, instruction.
Output: ---INSTRUCTION--- / ---MODULE--- / ---TEST--- / ---END---
"""

# ── Attempt + Refine Loops ───────────────────────────────────────────

defmodule ConvertLoop do
  require Logger

  def attempt(_example, _prompt, _sys, _opts, attempt, _ws) when attempt > 5 do
    Logger.warning("[attempt] giving up after #{attempt - 1} attempts")
    {:failed, "exceeded retries"}
  end

  def attempt(example, prompt, sys, opts, attempt, ws) do
    Logger.info("[attempt #{attempt}] calling LLM for entry_point=#{example.entry_point}")
    Logger.debug("[attempt #{attempt}] prompt length=#{String.length(prompt)} chars")

    case Tunex.LLM.call(prompt, sys, opts) do
      {:ok, content} ->
        Logger.info("[attempt #{attempt}] LLM returned #{String.length(content)} chars")
        Logger.debug("[attempt #{attempt}] parsing LLM response")

        case Tunex.Parser.parse_full(content) do
          {:ok, instr, mod, test} ->
            Logger.info("[attempt #{attempt}] parse OK — running validator")
            Logger.debug("[attempt #{attempt}] instruction=#{String.length(instr || "")} mod=#{String.length(mod)} test=#{String.length(test)} chars")

            {fails, final_mod, final_test} = Tunex.Validator.run(mod, test, ws)

            if fails == [] do
              Logger.info("[attempt #{attempt}] validation PASSED")
              {:ok, %{instruction: instr, elixir_code: final_mod, elixir_test: final_test,
                      original_instruction: example.instruction, python_code: example.code,
                      entry_point: Tunex.Parser.elixir_name(example.entry_point),
                      original_entry_point: example.entry_point, attempts: attempt,
                      refined: false}}
            else
              Logger.warning("[attempt #{attempt}] validation FAILED with #{length(fails)} error(s): #{inspect(Enum.map(fails, &elem(&1, 0)))}")
              Logger.debug("[attempt #{attempt}] errors: #{Tunex.Report.format_errors(fails)}")

              retry = """
              Your previous conversion had errors. Fix them.
              ## Original Python
              #{example.instruction}
              ```python
              #{example.code}
              ```
              ## Previous Output (ERRORS)
              #{content}
              ## Errors
              #{Tunex.Report.format_errors(fails)}

              Common pitfalls: unused variable→prefix _ per clause; descriptive names in ALL clauses;
              is_ prefix→use ? suffix (e.g. palindrome? not is_palindrome) in module AND tests.
              Output: ---INSTRUCTION--- / ---MODULE--- / ---TEST--- / ---END---
              """
              Logger.info("[attempt #{attempt}] retrying with error feedback")
              attempt(example, retry, sys, opts, attempt + 1, ws)
            end

          :error ->
            Logger.warning("[attempt #{attempt}] parse FAILED — could not extract sections from LLM output")
            Logger.debug("[attempt #{attempt}] raw output (first 500 chars): #{String.slice(content, 0, 500)}")
            attempt(example, prompt, sys, opts, attempt + 1, ws)
        end

      {:empty, reason} ->
        Logger.warning("[attempt #{attempt}] LLM returned empty: #{reason}")
        attempt(example, prompt, sys, opts, attempt + 1, ws)

      {:error, reason} ->
        Logger.error("[attempt #{attempt}] LLM call error: #{reason}")
        attempt(example, prompt, sys, opts, attempt + 1, ws)

      other ->
        Logger.error("[attempt #{attempt}] LLM unexpected result: #{inspect(other)}")
        attempt(example, prompt, sys, opts, attempt + 1, ws)
    end
  end

  def refine(entry, review_sys, refine_sys, opts, ws) do
    Logger.info("[refine] starting review for entry_point=#{entry.entry_point}")

    review = """
    Review this Elixir code for edge cases, idiom, missing tests.
    ## Instruction\n#{entry.instruction}
    ## Module\n```elixir\n#{entry.elixir_code}\n```
    ## Tests\n```elixir\n#{entry.elixir_test}\n```
    If excellent: NO_ISSUES_FOUND
    """

    case Tunex.LLM.call(review, review_sys, opts) do
      {:ok, fb} ->
        if String.contains?(fb, "NO_ISSUES_FOUND") do
          Logger.info("[refine] reviewer says NO_ISSUES_FOUND — skipping refinement")
          {:ok, %{entry | refined: false}}
        else
          Logger.info("[refine] reviewer found issues — starting refinement loop")
          Logger.debug("[refine] feedback (first 500 chars): #{String.slice(fb, 0, 500)}")
          do_refine(entry, fb, nil, 1, refine_sys, opts, ws)
        end

      {:empty, reason} ->
        Logger.warning("[refine] review LLM returned empty: #{reason} — skipping refinement")
        {:ok, %{entry | refined: false}}

      {:error, reason} ->
        Logger.error("[refine] review LLM error: #{reason} — skipping refinement")
        {:ok, %{entry | refined: false}}

      other ->
        Logger.warning("[refine] review LLM unexpected result: #{inspect(other)} — skipping refinement")
        {:ok, %{entry | refined: false}}
    end
  end

  defp do_refine(entry, _fb, _prev, attempt, _sys, _opts, _ws) when attempt > 5 do
    Logger.warning("[do_refine] giving up after #{attempt - 1} refinement attempts — keeping last good version")
    {:ok, entry}
  end

  defp do_refine(entry, fb, prev_errors, attempt, sys, opts, ws) do
    Logger.info("[do_refine #{attempt}] building refinement prompt")

    prompt = if prev_errors do
      {prev, errs} = prev_errors
      Logger.debug("[do_refine #{attempt}] using error-correction prompt (#{length(errs)} errors)")
      """
      Refinement had errors. Fix them.
      ## Working Module\n```elixir\n#{entry.elixir_code}\n```
      ## Working Tests\n```elixir\n#{entry.elixir_test}\n```
      ## Previous (ERRORS)\n#{prev}
      ## Errors\n#{Tunex.Report.format_errors(errs)}
      Output: ---INSTRUCTION--- / ---MODULE--- / ---TEST--- / ---END---
      """
    else
      Logger.debug("[do_refine #{attempt}] using feedback-application prompt")
      """
      Apply feedback to improve this code.
      ## Instruction\n#{entry.instruction}
      ## Module\n```elixir\n#{entry.elixir_code}\n```
      ## Tests\n```elixir\n#{entry.elixir_test}\n```
      ## Feedback\n#{fb}
      Output: ---INSTRUCTION--- / ---MODULE--- / ---TEST--- / ---END---
      """
    end

    Logger.info("[do_refine #{attempt}] calling LLM")

    case Tunex.LLM.call(prompt, sys, opts) do
      {:ok, content} ->
        Logger.info("[do_refine #{attempt}] LLM returned #{String.length(content)} chars")

        case Tunex.Parser.parse_full(content) do
          {:ok, instr, mod, test} ->
            Logger.info("[do_refine #{attempt}] parse OK — running validator")
            {fails, fm, ft} = Tunex.Validator.run(mod, test, ws)

            if fails == [] do
              Logger.info("[do_refine #{attempt}] validation PASSED — refinement successful")
              {:ok, %{entry | instruction: instr || entry.instruction,
                      elixir_code: fm, elixir_test: ft, refined: true}}
            else
              Logger.warning("[do_refine #{attempt}] validation FAILED with #{length(fails)} error(s): #{inspect(Enum.map(fails, &elem(&1, 0)))}")
              Logger.debug("[do_refine #{attempt}] errors: #{Tunex.Report.format_errors(fails)}")
              do_refine(entry, fb, {content, fails}, attempt + 1, sys, opts, ws)
            end

          :error ->
            Logger.warning("[do_refine #{attempt}] parse FAILED — retrying")
            Logger.debug("[do_refine #{attempt}] raw output (first 500 chars): #{String.slice(content, 0, 500)}")
            do_refine(entry, fb, nil, attempt + 1, sys, opts, ws)
        end

      {:empty, reason} ->
        Logger.warning("[do_refine #{attempt}] LLM returned empty: #{reason} — keeping current version")
        {:ok, entry}

      {:error, reason} ->
        Logger.error("[do_refine #{attempt}] LLM error: #{reason} — keeping current version")
        {:ok, entry}

      other ->
        Logger.warning("[do_refine #{attempt}] LLM unexpected result: #{inspect(other)} — keeping current version")
        {:ok, entry}
    end
  end
end

# ── CLI ──────────────────────────────────────────────────────────────

argv = System.argv()
{concurrency, argv} = CLI.parse_workers(argv)
{subset, start_index} = case argv do
  [s, n] -> {s, String.to_integer(n)}; [s] -> {s, 0}; [] -> {"educational_instruct", 0}
end

IO.puts("Tunex Convert | subset=#{subset} start=#{start_index} workers=#{concurrency}\n")

Logger.info("Loading dataset for subset=#{subset}")
parquet = Dataset.ensure_downloaded(subset)
output_path = "elixir_sft_#{subset}.jsonl"
errors_path = CLI.errors_path(output_path)
Logger.info("Output: #{output_path}  Errors: #{errors_path}")

Logger.info("Setting up workspace pool (#{concurrency} workers)")
Workspace.setup_pool("tunex_workspace", concurrency)
{all_rows, total} = Dataset.load_rows(parquet)
Logger.info("Loaded #{total} rows from parquet")

completed = Progress.load_completed_indices(output_path, errors_path)
pending = start_index..(total - 1) |> Enum.reject(&MapSet.member?(completed, &1))
IO.puts("#{length(pending)} pending, #{MapSet.size(completed)} done\n")
Logger.info("#{length(pending)} pending indices, #{MapSet.size(completed)} already completed")

unless pending == [] do
  out = JSONL.open_append(output_path)
  err = JSONL.open_append(errors_path)
  opts = [max_tokens: max_tokens]

  Logger.info("Starting processing with max_tokens=#{max_tokens}, concurrency=#{concurrency}")

  pending
  |> Enum.map(fn idx -> {Enum.at(all_rows, idx), idx} end)
  |> Task.async_stream(fn {row, idx} ->
    wid = Workspace.checkout()
    ws = Workspace.pool_path("tunex_workspace", wid)
    Logger.info("[idx=#{idx}] checked out workspace #{wid} (#{ws})")

    ex = %{instruction: row["instruction"], code: row["code"],
           entry_point: row["entry_point"], tests: row["testcase"] || []}

    Logger.info("[idx=#{idx}] entry_point=#{ex.entry_point}")
    Logger.debug("[idx=#{idx}] instruction length=#{String.length(ex.instruction || "")}, code length=#{String.length(ex.code || "")}")

    tests = if is_list(ex.tests), do: Enum.join(ex.tests, "\n"), else: to_string(ex.tests)
    elixir_fn = Parser.elixir_name(ex.entry_point)
    Logger.debug("[idx=#{idx}] elixir function name: #{elixir_fn}")

    prompt = """
    Convert this Python exercise to Elixir.
    ## Python Instruction\n#{ex.instruction}
    ## Python Solution\n```python\n#{ex.code}\n```
    ## Python Tests\n#{tests}
    Function: `#{elixir_fn}`#{if elixir_fn != Parser.snake_name(ex.entry_point), do: " (renamed from Python `#{Parser.snake_name(ex.entry_point)}` — use the `?` version everywhere)", else: ""}
    Output: ---INSTRUCTION--- / ---MODULE--- / ---TEST--- / ---END---
    """

    t0 = System.monotonic_time(:millisecond)
    Logger.info("[idx=#{idx}] starting attempt loop")

    result = case ConvertLoop.attempt(ex, prompt, system_prompt, opts, 1, ws) do
      {:ok, entry} ->
        Logger.info("[idx=#{idx}] attempt loop succeeded (#{entry.attempts} attempt(s)) — starting refine")
        ConvertLoop.refine(entry, review_prompt, refine_prompt, opts, ws)
      fail ->
        Logger.warning("[idx=#{idx}] attempt loop failed: #{inspect(fail)}")
        fail
    end

    Workspace.checkin(wid)
    elapsed = Float.round((System.monotonic_time(:millisecond) - t0) / 1000, 1)
    Logger.info("[idx=#{idx}] finished in #{elapsed}s — result: #{if match?({:ok, _}, result), do: "OK", else: "FAILED"}")
    {row, idx, result, elapsed}
  end, max_concurrency: concurrency, timeout: :infinity, ordered: false)
  |> Enum.each(fn {:ok, {row, idx, result, elapsed}} ->
    ep = row["entry_point"] || "?"
    case result do
      {:ok, entry} ->
        IO.puts("✓ [#{idx}] #{ep} (#{elapsed}s)")
        Logger.debug("[idx=#{idx}] writing success to JSONL (refined=#{entry.refined})")
        JSONL.append_to(out, Map.put(entry, :index, idx))
      {:failed, reason} ->
        IO.puts("✗ [#{idx}] #{ep}: #{reason} (#{elapsed}s)")
        Logger.debug("[idx=#{idx}] writing failure to errors JSONL")
        JSONL.append_to(err, %{index: idx, entry_point: ep, failure_reason: reason})
    end
  end)

  File.close(out)
  File.close(err)
  Logger.info("All files closed")
end

IO.puts("\n✓ Done. Output: #{output_path}")
Logger.info("Conversion complete")