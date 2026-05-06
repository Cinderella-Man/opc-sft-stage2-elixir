# mix run scripts/extract_dpo_pairs.exs <trajectories_file> [output_file]
#
# Extracts DPO preference pairs from trajectory logs.
#
# Pair types:
#   1. Attempt pairs: final passing code (chosen) vs last compiled-but-failed code (rejected)
#   2. Refinement pairs: refined passing code (chosen) vs pre-refinement code (rejected)
#   3. NamingFixup pairs: post-fixup code (chosen) vs pre-fixup is_ code (rejected)
#
# Quality filters:
#   - Rejected must have parse_ok: true (no formatting noise)
#   - Rejected must have at least compiled (for attempt pairs)
#   - Chosen and rejected share the same task/prompt context
#
# Output: JSONL with {index, entry_point, pair_type, prompt, chosen, rejected, metadata}

require Logger

alias Tunex.JSONL

defmodule DPOExtractor do
  @moduledoc "Extracts DPO preference pairs from trajectory logs."

  def run(input_path, output_path) do
    records = JSONL.read(input_path)
    IO.puts("Loaded #{length(records)} trajectory records from #{input_path}")

    by_index = Enum.group_by(records, & &1["index"])

    pairs =
      by_index
      |> Enum.flat_map(fn {index, task_records} ->
        attempt_pairs(index, task_records) ++
        refinement_pairs(index, task_records) ++
        naming_fixup_pairs(index, task_records)
      end)
      |> Enum.sort_by(& &1.index)

    IO.puts("Extracted #{length(pairs)} DPO pairs")
    JSONL.write(output_path, pairs)
    IO.puts("Written to #{output_path}")
    print_stats(pairs)
  end

  # ── Attempt Pairs ──────────────────────────────────────────────────

  defp attempt_pairs(index, records) do
    attempts = records
      |> Enum.filter(& &1["type"] == "attempt")
      |> Enum.sort_by(& &1["attempt_number"])

    passed = Enum.filter(attempts, & &1["outcome"] == "passed")

    # Rejected candidates: parsed OK and have code, sorted by quality (highest attempt = closest to correct)
    rejectables = attempts
      |> Enum.filter(fn a ->
        a["outcome"] == "failed" and
        a["parse_ok"] == true and
        a["final_module_code"] != nil and
        a["final_test_code"] != nil and
        # Must have at least compiled (compile not in failures)
        not Enum.any?(a["validation_failures"] || [], & &1["stage"] == "compile")
      end)
      |> Enum.sort_by(& &1["attempt_number"], :desc)

    case {passed, rejectables} do
      {[winner | _], rejects} when rejects != [] ->
        # Create a pair for each rejected candidate (best rejected first)
        Enum.map(rejects, fn rejected ->
          %{
            index: index,
            entry_point: winner["entry_point"],
            pair_type: "attempt",
            prompt: build_sft_prompt(winner),
            chosen: %{
              module_code: winner["final_module_code"],
              test_code: winner["final_test_code"],
              instruction: winner["instruction"],
              raw_response: winner["raw_response"]
            },
            rejected: %{
              module_code: rejected["final_module_code"],
              test_code: rejected["final_test_code"],
              instruction: rejected["instruction"],
              raw_response: rejected["raw_response"]
            },
            metadata: %{
              chosen_attempt: winner["attempt_number"],
              rejected_attempt: rejected["attempt_number"],
              rejected_failures: (rejected["validation_failures"] || [])
                |> Enum.map(& &1["stage"]),
              quality_gap: winner["attempt_number"] - rejected["attempt_number"]
            }
          }
        end)

      _ -> []
    end
  end

  # ── Refinement Pairs ───────────────────────────────────────────────

  defp refinement_pairs(index, records) do
    refinements = records
      |> Enum.filter(& &1["type"] == "refinement")
      |> Enum.sort_by(& &1["refinement_attempt"])

    passed = Enum.filter(refinements, & &1["outcome"] == "passed")

    case passed do
      [winner | _] ->
        # The code before refinement is the rejected version
        # (it passed validation but had style/quality issues flagged by reviewer)
        if winner["module_before"] && winner["module_after"] &&
           winner["module_before"] != winner["final_module_code"] do
          [%{
            index: index,
            entry_point: winner["entry_point"],
            pair_type: "refinement",
            prompt: build_refine_prompt(winner),
            chosen: %{
              module_code: winner["final_module_code"],
              test_code: winner["final_test_code"],
              raw_response: winner["raw_response"]
            },
            rejected: %{
              module_code: winner["module_before"],
              test_code: winner["test_before"]
            },
            metadata: %{
              refinement_attempt: winner["refinement_attempt"],
              reviewer_feedback: winner["reviewer_feedback"]
            }
          }]
        else
          []
        end

      _ ->
        # Also pair failed refinements as rejected vs the pre-refinement code
        # (since pre-refinement code at least passed validation)
        failed_refines = refinements
          |> Enum.filter(fn r ->
            r["outcome"] == "failed" and
            r["parse_ok"] == true and
            r["module_before"] != nil
          end)

        Enum.map(failed_refines, fn rejected ->
          %{
            index: index,
            entry_point: rejected["entry_point"],
            pair_type: "refinement_regression",
            prompt: build_refine_prompt(rejected),
            chosen: %{
              module_code: rejected["module_before"],
              test_code: rejected["test_before"]
            },
            rejected: %{
              module_code: rejected["module_after"] || rejected["final_module_code"],
              test_code: rejected["test_after"] || rejected["final_test_code"],
              raw_response: rejected["raw_response"]
            },
            metadata: %{
              refinement_attempt: rejected["refinement_attempt"],
              failure_stages: (rejected["validation_failures"] || [])
                |> Enum.map(& &1["stage"]),
              reviewer_feedback: rejected["reviewer_feedback"]
            }
          }
        end)
    end
  end

  # ── NamingFixup Pairs ──────────────────────────────────────────────

  defp naming_fixup_pairs(index, records) do
    # Attempts where NamingFixup was applied AND validation passed
    # The raw LLM output (with is_ prefix) is rejected,
    # the fixed version (with ?) is chosen
    records
    |> Enum.filter(fn r ->
      r["type"] in ["attempt", "refinement"] and
      r["naming_fixup_applied"] == true and
      r["outcome"] == "passed" and
      r["module_code"] != nil and
      r["final_module_code"] != nil and
      r["module_code"] != r["final_module_code"]
    end)
    |> Enum.map(fn record ->
      %{
        index: index,
        entry_point: record["entry_point"],
        pair_type: "naming_convention",
        prompt: "Fix is_ prefix to ? suffix in Elixir code",
        chosen: %{
          module_code: record["final_module_code"],
          test_code: record["final_test_code"]
        },
        rejected: %{
          module_code: record["module_code"],
          test_code: record["test_code"]
        },
        metadata: %{
          source_type: record["type"],
          attempt_number: record["attempt_number"] || record["refinement_attempt"]
        }
      }
    end)
  end

  # ── Prompt Builders ────────────────────────────────────────────────

  defp build_sft_prompt(record) do
    "Convert this Python exercise to Elixir. Function: `#{record["entry_point"]}`"
  end

  defp build_refine_prompt(record) do
    feedback = record["reviewer_feedback"] || "Improve code quality"
    "Apply reviewer feedback to improve Elixir code for `#{record["entry_point"]}`: #{String.slice(feedback, 0, 500)}"
  end

  # ── Statistics ─────────────────────────────────────────────────────

  defp print_stats(pairs) do
    by_type = Enum.group_by(pairs, & &1.pair_type)

    IO.puts("\n── DPO Pair Statistics ──")
    for {type, group} <- by_type |> Enum.sort_by(fn {_, g} -> -length(g) end) do
      IO.puts("  #{type}: #{length(group)}")
    end
    IO.puts("  Total: #{length(pairs)}")

    # Failure stage distribution for attempt pairs
    attempt_p = Map.get(by_type, "attempt", [])
    if attempt_p != [] do
      stages = attempt_p
        |> Enum.flat_map(& &1.metadata.rejected_failures)
        |> Enum.frequencies()
        |> Enum.sort_by(fn {_, c} -> -c end)

      IO.puts("\n  Rejection reasons (attempt pairs):")
      for {stage, count} <- stages do
        IO.puts("    #{stage}: #{count}")
      end
    end
  end
end

# ── CLI ──────────────────────────────────────────────────────────────

case System.argv() do
  [input] ->
    output = String.replace(input, ".jsonl", "_dpo_pairs.jsonl")
    DPOExtractor.run(input, output)

  [input, output] ->
    DPOExtractor.run(input, output)

  _ ->
    IO.puts("Usage: mix run scripts/extract_dpo_pairs.exs <trajectories.jsonl> [output.jsonl]")
    System.halt(1)
end
