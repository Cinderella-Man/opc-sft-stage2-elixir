# mix run scripts/analyze_trajectories.exs <trajectories_file>
#
# Analyzes trajectory data to produce statistics, failure patterns,
# and data quality metrics for training data decisions.
#
# Reports:
#   1. Overall conversion statistics (success rate, retry distribution)
#   2. Validation failure patterns (which stages fail most)
#   3. Credence/credo rule frequencies
#   4. LLM call efficiency (latency, token usage implied by retries)
#   5. Data yield estimates (how many SFT/DPO/review examples)
#   6. Quality tier breakdown

require Logger

alias Tunex.JSONL

defmodule TrajectoryAnalyzer do
  @moduledoc "Analyzes trajectory logs for patterns and data yield estimates."

  def run(input_path) do
    records = JSONL.read(input_path)
    IO.puts("Loaded #{length(records)} trajectory records from #{input_path}\n")

    by_type = Enum.group_by(records, & &1["type"])
    by_index = Enum.group_by(records, & &1["index"])

    summaries = Map.get(by_type, "summary", [])
    attempts = Map.get(by_type, "attempt", [])
    reviews = Map.get(by_type, "review", [])
    refinements = Map.get(by_type, "refinement", [])

    section("Record Counts", fn ->
      IO.puts("  Summaries:    #{length(summaries)}")
      IO.puts("  Attempts:     #{length(attempts)}")
      IO.puts("  Reviews:      #{length(reviews)}")
      IO.puts("  Refinements:  #{length(refinements)}")
      IO.puts("  Unique tasks: #{map_size(by_index)}")
    end)

    section("Conversion Outcomes", fn ->
      success = Enum.count(summaries, & &1["final_outcome"] == "success")
      failed = Enum.count(summaries, & &1["final_outcome"] == "failed")
      total = length(summaries)
      rate = if total > 0, do: Float.round(success / total * 100, 1), else: 0.0

      IO.puts("  Success: #{success} (#{rate}%)")
      IO.puts("  Failed:  #{failed}")
      IO.puts("  Total:   #{total}")
    end)

    section("Attempt Distribution", fn ->
      attempt_counts = summaries
        |> Enum.map(& &1["total_attempts"])
        |> Enum.frequencies()
        |> Enum.sort_by(fn {k, _} -> k end)

      for {count, freq} <- attempt_counts do
        bar = String.duplicate("█", min(freq, 60))
        IO.puts("  #{count} attempt(s): #{String.pad_leading("#{freq}", 5)} #{bar}")
      end

      avg = if summaries != [] do
        total_attempts = Enum.sum(Enum.map(summaries, & &1["total_attempts"]))
        Float.round(total_attempts / length(summaries), 2)
      else 0.0 end
      IO.puts("\n  Average attempts per task: #{avg}")
    end)

    section("LLM Call Statistics", fn ->
      total_calls = Enum.sum(Enum.map(summaries, &((&1["total_llm_calls"]) || 0)))
      IO.puts("  Total LLM calls: #{total_calls}")

      latencies = (attempts ++ reviews ++ refinements)
        |> Enum.map(& &1["llm_latency_ms"])
        |> Enum.filter(&is_number/1)
        |> Enum.sort()

      if latencies != [] do
        IO.puts("  Latency (ms):")
        IO.puts("    min:    #{List.first(latencies)}")
        IO.puts("    median: #{Enum.at(latencies, div(length(latencies), 2))}")
        IO.puts("    p95:    #{Enum.at(latencies, round(length(latencies) * 0.95))}")
        IO.puts("    max:    #{List.last(latencies)}")
        IO.puts("    mean:   #{round(Enum.sum(latencies) / length(latencies))}")
      end

      total_time_s = summaries
        |> Enum.map(&((&1["elapsed_s"]) || 0))
        |> Enum.sum()
        |> Float.round(1)
      IO.puts("\n  Total wall-clock time: #{total_time_s}s (#{Float.round(total_time_s / 3600, 2)}h)")
    end)

    section("Attempt Outcome Breakdown", fn ->
      outcomes = attempts
        |> Enum.map(& &1["outcome"])
        |> Enum.frequencies()
        |> Enum.sort_by(fn {_, c} -> -c end)

      for {outcome, count} <- outcomes do
        pct = Float.round(count / max(length(attempts), 1) * 100, 1)
        IO.puts("  #{String.pad_trailing(outcome, 15)} #{String.pad_leading("#{count}", 6)} (#{pct}%)")
      end
    end)

    section("Validation Failure Stages", fn ->
      failed_attempts = Enum.filter(attempts, & &1["outcome"] == "failed")
      stages = failed_attempts
        |> Enum.flat_map(fn a ->
          (a["validation_failures"] || []) |> Enum.map(& &1["stage"])
        end)
        |> Enum.frequencies()
        |> Enum.sort_by(fn {_, c} -> -c end)

      for {stage, count} <- stages do
        IO.puts("  #{String.pad_trailing(stage, 15)} #{count}")
      end
    end)

    section("Credence Rule Failures", fn ->
      credence_msgs = (attempts ++ refinements)
        |> Enum.flat_map(fn r ->
          (r["validation_failures"] || [])
          |> Enum.filter(& &1["stage"] == "credence")
          |> Enum.map(& &1["message"])
        end)

      rules = credence_msgs
        |> Enum.flat_map(fn msg ->
          Regex.scan(~r/\[(?:warning|info|high)\] ([a-z_]+):/, msg)
          |> Enum.map(fn [_, rule] -> rule end)
        end)
        |> Enum.frequencies()
        |> Enum.sort_by(fn {_, c} -> -c end)

      if rules == [] do
        IO.puts("  (no credence failures)")
      else
        for {rule, count} <- rules do
          IO.puts("  #{String.pad_trailing(rule, 25)} #{count}")
        end
      end
    end)

    section("NamingFixup Statistics", fn ->
      fixup_count = (attempts ++ refinements)
        |> Enum.count(& &1["naming_fixup_applied"] == true)

      total = length(attempts) + length(refinements)
      pct = if total > 0, do: Float.round(fixup_count / total * 100, 1), else: 0.0

      IO.puts("  NamingFixup applied: #{fixup_count}/#{total} (#{pct}%)")
    end)

    section("Review Statistics", fn ->
      no_issues = Enum.count(reviews, & &1["no_issues_found"] == true)
      with_feedback = length(reviews) - no_issues

      IO.puts("  Total reviews:     #{length(reviews)}")
      IO.puts("  NO_ISSUES_FOUND:   #{no_issues}")
      IO.puts("  With feedback:     #{with_feedback}")

      if reviews != [] do
        pct = Float.round(no_issues / length(reviews) * 100, 1)
        IO.puts("  First-pass quality: #{pct}%")
      end
    end)

    section("Refinement Statistics", fn ->
      if refinements != [] do
        passed = Enum.count(refinements, & &1["outcome"] == "passed")
        failed = Enum.count(refinements, & &1["outcome"] == "failed")
        parse_err = Enum.count(refinements, & &1["outcome"] == "parse_error")

        IO.puts("  Total refinement attempts: #{length(refinements)}")
        IO.puts("  Passed:      #{passed}")
        IO.puts("  Failed:      #{failed}")
        IO.puts("  Parse error: #{parse_err}")
      else
        IO.puts("  (no refinements)")
      end
    end)

    section("Quality Tiers", fn ->
      # Tier based on final task outcome and attempt count
      tier1 = Enum.count(summaries, fn s ->
        s["final_outcome"] == "success" and s["total_attempts"] == 1 and !s["refined"]
      end)
      tier2 = Enum.count(summaries, fn s ->
        s["final_outcome"] == "success" and (s["total_attempts"] > 1 or s["refined"])
      end)
      tier_fail = Enum.count(summaries, & &1["final_outcome"] == "failed")

      IO.puts("  Tier 1 (Gold — passed first try, no refinement): #{tier1}")
      IO.puts("  Tier 2 (Silver — passed after retries/refinement): #{tier2}")
      IO.puts("  Failed (no usable final output):                   #{tier_fail}")
    end)

    section("Estimated Data Yield", fn ->
      success_count = Enum.count(summaries, & &1["final_outcome"] == "success")

      # Multi-attempt tasks → correction pairs
      multi_attempt = Enum.count(summaries, fn s ->
        s["final_outcome"] == "success" and s["total_attempts"] > 1
      end)

      # Compiled-but-failed attempts → DPO pairs
      compiled_failures = attempts
        |> Enum.filter(fn a ->
          a["outcome"] == "failed" and
          a["parse_ok"] == true and
          not Enum.any?(a["validation_failures"] || [], & &1["stage"] == "compile")
        end)
        |> length()

      # Reviews with feedback from successful tasks
      validated_reviews = reviews
        |> Enum.filter(fn r ->
          r["no_issues_found"] == false and r["llm_result"] == "ok"
        end)
        |> length()

      # Naming fixup pairs
      fixup_pairs = (attempts ++ refinements)
        |> Enum.count(fn r ->
          r["naming_fixup_applied"] == true and r["outcome"] == "passed"
        end)

      IO.puts("  Primary SFT (final outputs):        #{success_count}")
      IO.puts("  Multi-turn SFT (correction chains):  ~#{multi_attempt}")
      IO.puts("  DPO pairs (compiled failures):       ~#{compiled_failures}")
      IO.puts("  DPO pairs (naming convention):       ~#{fixup_pairs}")
      IO.puts("  Review SFT (with feedback):          ~#{validated_reviews}")
      IO.puts("  ─────────────────────────────────────")

      total_yield = success_count + multi_attempt + compiled_failures + fixup_pairs + validated_reviews
      multiplier = if success_count > 0, do: Float.round(total_yield / success_count, 1), else: 0.0
      IO.puts("  Total estimated yield:               ~#{total_yield}")
      IO.puts("  Multiplier over primary SFT:         #{multiplier}x")
    end)

    section("Hardest Tasks (Most Retries)", fn ->
      summaries
      |> Enum.sort_by(& &1["total_llm_calls"], :desc)
      |> Enum.take(10)
      |> Enum.each(fn s ->
        status = if s["final_outcome"] == "success", do: "✓", else: "✗"
        IO.puts("  #{status} [#{s["index"]}] #{s["entry_point"]} — #{s["total_llm_calls"]} calls, #{s["total_attempts"]} attempts, #{s["elapsed_s"]}s")
      end)
    end)
  end

  defp section(title, fun) do
    IO.puts("═══ #{title} ═══")
    fun.()
    IO.puts("")
  end
end

# ── CLI ──────────────────────────────────────────────────────────────

case System.argv() do
  [input] ->
    TrajectoryAnalyzer.run(input)

  _ ->
    IO.puts("Usage: mix run scripts/analyze_trajectories.exs <trajectories.jsonl>")
    System.halt(1)
end
