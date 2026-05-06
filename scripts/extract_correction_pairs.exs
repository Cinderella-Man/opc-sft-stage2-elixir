# mix run scripts/extract_correction_pairs.exs <trajectories_file> [output_file]
#
# Extracts multi-turn SFT correction chains from trajectory logs.
#
# For each task that needed multiple attempts, produces a conversation:
#   System: <system prompt>
#   User: <initial prompt>
#   Assistant: <last failing response>
#   User: <error feedback prompt>
#   Assistant: <passing response>
#
# Only includes chains where:
#   - The final attempt passed validation
#   - The failing attempt at least parsed successfully (parse_ok: true)
#   - The failing attempt produced code (not empty/error)
#
# Output: JSONL with {index, entry_point, conversation, metadata} records.

require Logger

alias Tunex.JSONL

defmodule CorrectionExtractor do
  @moduledoc "Extracts correction-chain SFT data from trajectory logs."

  def run(input_path, output_path) do
    records = JSONL.read(input_path)
    IO.puts("Loaded #{length(records)} trajectory records from #{input_path}")

    # Group by index
    by_index = Enum.group_by(records, & &1["index"])

    # Process each task
    pairs =
      by_index
      |> Enum.flat_map(fn {index, task_records} ->
        extract_task_corrections(index, task_records)
      end)
      |> Enum.sort_by(& &1.index)

    IO.puts("Extracted #{length(pairs)} correction pairs")

    # Write output
    JSONL.write(output_path, pairs)
    IO.puts("Written to #{output_path}")

    # Stats
    print_stats(pairs)
  end

  defp extract_task_corrections(index, records) do
    attempts = records
      |> Enum.filter(& &1["type"] == "attempt")
      |> Enum.sort_by(& &1["attempt_number"])

    # Need at least 2 attempts (one failed, one passed)
    if length(attempts) < 2 do
      []
    else
      passed = Enum.filter(attempts, & &1["outcome"] == "passed")
      failed = attempts
        |> Enum.filter(& &1["outcome"] == "failed" and &1["parse_ok"] == true)
        |> Enum.sort_by(& &1["attempt_number"], :desc)

      case {passed, failed} do
        {[winner | _], [last_fail | _]} ->
          # Build conversation: last failing attempt → error feedback → passing attempt
          conversation = [
            %{role: "user", content: last_fail["prompt"]},
            %{role: "assistant", content: last_fail["raw_response"]},
            %{role: "user", content: winner["prompt"]},
            %{role: "assistant", content: winner["raw_response"]}
          ]

          [%{
            index: index,
            entry_point: last_fail["entry_point"],
            type: "attempt_correction",
            conversation: conversation,
            metadata: %{
              failing_attempt: last_fail["attempt_number"],
              passing_attempt: winner["attempt_number"],
              total_attempts: length(attempts),
              failure_stages: last_fail["validation_failures"]
                |> Enum.map(& &1["stage"])
                |> Enum.uniq()
            }
          }]

        _ -> []
      end
    end
    |> then(fn attempt_pairs ->
      # Also extract refinement correction chains
      refinements = records
        |> Enum.filter(& &1["type"] == "refinement")
        |> Enum.sort_by(& &1["refinement_attempt"])

      reviews = records
        |> Enum.filter(& &1["type"] == "review" and &1["no_issues_found"] == false)

      refine_pairs =
        if length(refinements) >= 1 do
          passed_refines = Enum.filter(refinements, & &1["outcome"] == "passed")
          failed_refines = refinements
            |> Enum.filter(& &1["outcome"] == "failed" and &1["parse_ok"] == true)
            |> Enum.sort_by(& &1["refinement_attempt"], :desc)

          review_feedback = case reviews do
            [review | _] -> review["raw_response"]
            [] -> nil
          end

          case {passed_refines, failed_refines, review_feedback} do
            {[winner | _], [last_fail | _], feedback} when not is_nil(feedback) ->
              conversation = [
                %{role: "user", content: last_fail["prompt"]},
                %{role: "assistant", content: last_fail["raw_response"]},
                %{role: "user", content: winner["prompt"]},
                %{role: "assistant", content: winner["raw_response"]}
              ]

              [%{
                index: index,
                entry_point: (List.first(refinements))["entry_point"],
                type: "refinement_correction",
                conversation: conversation,
                metadata: %{
                  failing_refinement: last_fail["refinement_attempt"],
                  passing_refinement: winner["refinement_attempt"],
                  total_refinements: length(refinements),
                  reviewer_feedback: feedback,
                  failure_stages: last_fail["validation_failures"]
                    |> Enum.map(& &1["stage"])
                    |> Enum.uniq()
                }
              }]

            _ -> []
          end
        else
          []
        end

      attempt_pairs ++ refine_pairs
    end)
  end

  defp print_stats(pairs) do
    attempt_corrs = Enum.count(pairs, & &1.type == "attempt_correction")
    refine_corrs = Enum.count(pairs, & &1.type == "refinement_correction")

    IO.puts("\n── Correction Pair Statistics ──")
    IO.puts("  Attempt corrections:    #{attempt_corrs}")
    IO.puts("  Refinement corrections: #{refine_corrs}")
    IO.puts("  Total:                  #{length(pairs)}")

    if pairs != [] do
      stages = pairs
        |> Enum.flat_map(& &1.metadata.failure_stages)
        |> Enum.frequencies()
        |> Enum.sort_by(fn {_, c} -> -c end)

      IO.puts("\n  Failure stages in corrections:")
      for {stage, count} <- stages do
        IO.puts("    #{stage}: #{count}")
      end
    end
  end
end

# ── CLI ──────────────────────────────────────────────────────────────

case System.argv() do
  [input] ->
    output = String.replace(input, ".jsonl", "_sft_corrections.jsonl")
    CorrectionExtractor.run(input, output)

  [input, output] ->
    CorrectionExtractor.run(input, output)

  _ ->
    IO.puts("Usage: mix run scripts/extract_correction_pairs.exs <trajectories.jsonl> [output.jsonl]")
    System.halt(1)
end
