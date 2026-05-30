# mix run scripts/extract_reviews.exs <trajectories_file> [output_file]
#
# Extracts reviewer training data from trajectory logs.
#
# Two categories:
#   1. Validated reviews: reviewer gave feedback, subsequent refinement passed
#      → The review was useful and correct (high quality)
#   2. All reviews: every reviewer exchange regardless of refinement outcome
#      → Larger dataset but may include misleading feedback
#
# Output: JSONL with {index, entry_point, category, input, output, metadata}

require Logger

alias Tunex.JSONL

defmodule ReviewExtractor do
  @moduledoc "Extracts code review training data from trajectory logs."

  def run(input_path, output_path) do
    records = JSONL.read(input_path)
    IO.puts("Loaded #{length(records)} trajectory records from #{input_path}")

    by_index = Enum.group_by(records, & &1["index"])

    reviews =
      by_index
      |> Enum.flat_map(fn {index, task_records} ->
        extract_reviews(index, task_records)
      end)
      |> Enum.sort_by(& &1.index)

    IO.puts("Extracted #{length(reviews)} review examples")
    JSONL.write(output_path, reviews)
    IO.puts("Written to #{output_path}")
    print_stats(reviews)
  end

  defp extract_reviews(index, records) do
    review_records = records
      |> Enum.filter(& &1["type"] == "review" and &1["llm_result"] == "ok")

    refinement_records = records
      |> Enum.filter(& &1["type"] == "refinement")

    summary_records = records
      |> Enum.filter(& &1["type"] == "summary")

    # Did any refinement succeed for this task?
    refinement_succeeded = Enum.any?(refinement_records, & &1["outcome"] == "passed")

    # Was the overall task successful?
    task_succeeded = Enum.any?(summary_records, & &1["final_outcome"] == "success")

    Enum.flat_map(review_records, fn review ->
      base = %{
        index: index,
        entry_point: review["entry_point"],
        input: %{
          instruction: extract_instruction_from_prompt(review["prompt"]),
          module_code: review["module_code"],
          test_code: review["test_code"]
        },
        output: review["raw_response"],
        no_issues_found: review["no_issues_found"],
        metadata: %{
          llm_latency_ms: review["llm_latency_ms"],
          task_succeeded: task_succeeded
        }
      }

      cond do
        review["no_issues_found"] ->
          # NO_ISSUES_FOUND reviews — only include from successful tasks
          if task_succeeded do
            [Map.merge(base, %{category: "validated_approval"})]
          else
            # Reviewer said OK but task later failed — suspicious
            [Map.merge(base, %{category: "false_approval"})]
          end

        refinement_succeeded ->
          # Feedback that led to successful refinement — high quality
          [Map.merge(base, %{category: "validated_feedback"})]

        true ->
          # Feedback but refinement didn't succeed — may be misleading
          [Map.merge(base, %{category: "unvalidated_feedback"})]
      end
    end)
  end

  defp extract_instruction_from_prompt(prompt) when is_binary(prompt) do
    # Try to extract the instruction section from the review prompt
    case String.split(prompt, "## Instruction\n", parts: 2) do
      [_, rest] ->
        case String.split(rest, "\n## Module", parts: 2) do
          [instr, _] -> String.trim(instr)
          _ -> nil
        end
      _ -> nil
    end
  end

  defp extract_instruction_from_prompt(_), do: nil

  defp print_stats(reviews) do
    by_cat = Enum.group_by(reviews, & &1.category)

    IO.puts("\n── Review Data Statistics ──")
    for {cat, group} <- by_cat |> Enum.sort_by(fn {_, g} -> -length(g) end) do
      IO.puts("  #{cat}: #{length(group)}")
    end
    IO.puts("  Total: #{length(reviews)}")

    no_issues = Enum.count(reviews, & &1.no_issues_found)
    with_feedback = length(reviews) - no_issues
    IO.puts("\n  NO_ISSUES_FOUND: #{no_issues}")
    IO.puts("  With feedback:   #{with_feedback}")

    validated = Enum.count(reviews, & &1.category in ["validated_feedback", "validated_approval"])
    IO.puts("\n  Validated (safe for training): #{validated}")
    IO.puts("  Unvalidated (use with care):  #{length(reviews) - validated}")
  end
end

# ── CLI ──────────────────────────────────────────────────────────────

case System.argv() do
  [input] ->
    output = String.replace(input, ".jsonl", "_reviews.jsonl")
    ReviewExtractor.run(input, output)

  [input, output] ->
    ReviewExtractor.run(input, output)

  _ ->
    IO.puts("Usage: mix run scripts/extract_reviews.exs <trajectories.jsonl> [output.jsonl]")
    System.halt(1)
end
