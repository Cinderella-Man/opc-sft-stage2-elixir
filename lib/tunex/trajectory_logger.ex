defmodule Tunex.TrajectoryLogger do
  @moduledoc """
  Logs intermediate LLM exchanges and validation results during conversion
  for downstream training data extraction (SFT corrections, DPO pairs, reviews).

  Writes structured JSONL records with a `type` field for post-processing.
  Uses Erlang's I/O protocol for concurrent-safe appends from async workers.

  Record types:
    - `"attempt"`     — one per LLM call in the attempt loop
    - `"review"`      — one per reviewer LLM call
    - `"refinement"`  — one per refinement LLM call
    - `"summary"`     — one per completed task (success or failure)
  """

  require Logger

  # ── Lifecycle ──────────────────────────────────────────────────────

  @doc """
  Open a trajectory log file for the given subset.
  Returns a logger handle (map) to pass to logging functions.
  """
  def open(subset) do
    path = "trajectories_#{subset}.jsonl"
    file = File.open!(path, [:append, :utf8])
    Logger.info("[TrajectoryLogger] opened #{path}")
    %{file: file, path: path}
  end

  @doc "Close the trajectory log file."
  def close(%{file: file, path: path}) do
    File.close(file)
    Logger.info("[TrajectoryLogger] closed #{path}")
  end

  # ── Context ────────────────────────────────────────────────────────

  @doc """
  Create a task-scoped context to avoid repeating index/entry_point
  in every log call. Merge this into the logger handle.
  """
  def with_context(logger, index, entry_point) do
    Map.merge(logger, %{index: index, entry_point: entry_point})
  end

  # ── Attempt Logging ────────────────────────────────────────────────

  @doc """
  Log one attempt-loop iteration.

  `data` fields:
    - attempt_number (integer)
    - prompt (string) — the full user prompt sent to LLM
    - raw_response (string | nil) — full LLM output
    - llm_result (atom) — :ok, :empty, :error, :unexpected
    - llm_latency_ms (integer)
    - parse_ok (boolean)
    - instruction (string | nil)
    - module_code (string | nil) — parsed, pre-validation
    - test_code (string | nil) — parsed, pre-validation
    - naming_fixup_applied (boolean)
    - validation_failures (list of {stage, msg} | nil)
    - final_module_code (string | nil) — post-validation (formatted)
    - final_test_code (string | nil) — post-validation (formatted)
    - outcome (:passed | :failed | :parse_error | :empty | :error | :unexpected)
  """
  def log_attempt(logger, data) do
    entry = %{
      type: "attempt",
      index: logger.index,
      entry_point: logger.entry_point,
      attempt_number: data.attempt_number,
      prompt: data.prompt,
      raw_response: data.raw_response,
      llm_result: to_string(data.llm_result),
      llm_latency_ms: data.llm_latency_ms,
      parse_ok: data[:parse_ok] || false,
      instruction: data[:instruction],
      module_code: data[:module_code],
      test_code: data[:test_code],
      naming_fixup_applied: data[:naming_fixup_applied] || false,
      validation_failures: format_failures(data[:validation_failures]),
      validation_passed: data[:validation_failures] == [],
      final_module_code: data[:final_module_code],
      final_test_code: data[:final_test_code],
      outcome: to_string(data.outcome),
      timestamp: utc_now()
    }

    write(logger, entry)
  end

  # ── Review Logging ─────────────────────────────────────────────────

  @doc """
  Log a reviewer LLM exchange.

  `data` fields:
    - prompt (string) — review prompt
    - raw_response (string | nil)
    - llm_result (atom)
    - llm_latency_ms (integer)
    - no_issues_found (boolean)
    - module_code (string) — code being reviewed
    - test_code (string) — tests being reviewed
  """
  def log_review(logger, data) do
    entry = %{
      type: "review",
      index: logger.index,
      entry_point: logger.entry_point,
      prompt: data.prompt,
      raw_response: data.raw_response,
      llm_result: to_string(data.llm_result),
      llm_latency_ms: data.llm_latency_ms,
      no_issues_found: data[:no_issues_found] || false,
      module_code: data.module_code,
      test_code: data.test_code,
      timestamp: utc_now()
    }

    write(logger, entry)
  end

  # ── Refinement Logging ─────────────────────────────────────────────

  @doc """
  Log one refinement-loop iteration.

  `data` fields:
    - refinement_attempt (integer)
    - prompt (string)
    - raw_response (string | nil)
    - llm_result (atom)
    - llm_latency_ms (integer)
    - parse_ok (boolean)
    - module_before (string) — code going into refinement
    - module_after (string | nil) — code coming out (parsed)
    - test_before (string)
    - test_after (string | nil)
    - naming_fixup_applied (boolean)
    - validation_failures (list of {stage, msg} | nil)
    - final_module_code (string | nil) — post-validation
    - final_test_code (string | nil) — post-validation
    - outcome (:passed | :failed | :parse_error | :empty | :error)
    - reviewer_feedback (string) — the original feedback being addressed
  """
  def log_refinement(logger, data) do
    entry = %{
      type: "refinement",
      index: logger.index,
      entry_point: logger.entry_point,
      refinement_attempt: data.refinement_attempt,
      prompt: data.prompt,
      raw_response: data.raw_response,
      llm_result: to_string(data.llm_result),
      llm_latency_ms: data.llm_latency_ms,
      parse_ok: data[:parse_ok] || false,
      module_before: data.module_before,
      module_after: data[:module_after],
      test_before: data.test_before,
      test_after: data[:test_after],
      naming_fixup_applied: data[:naming_fixup_applied] || false,
      validation_failures: format_failures(data[:validation_failures]),
      validation_passed: data[:validation_failures] == [],
      final_module_code: data[:final_module_code],
      final_test_code: data[:final_test_code],
      outcome: to_string(data.outcome),
      reviewer_feedback: data[:reviewer_feedback],
      timestamp: utc_now()
    }

    write(logger, entry)
  end

  # ── Summary Logging ────────────────────────────────────────────────

  @doc """
  Log a per-task trajectory summary after all attempts and refinements complete.

  `data` fields:
    - total_attempts (integer)
    - total_refinements (integer)
    - total_llm_calls (integer)
    - final_outcome (:success | :failed)
    - failure_reason (string | nil)
    - elapsed_s (float)
    - original_instruction (string)
    - python_code (string)
    - final_instruction (string | nil)
    - final_module (string | nil)
    - final_test (string | nil)
    - refined (boolean)
  """
  def log_summary(logger, data) do
    entry = %{
      type: "summary",
      index: logger.index,
      entry_point: logger.entry_point,
      total_attempts: data.total_attempts,
      total_refinements: data[:total_refinements] || 0,
      total_llm_calls: data.total_llm_calls,
      final_outcome: to_string(data.final_outcome),
      failure_reason: data[:failure_reason],
      elapsed_s: data.elapsed_s,
      original_instruction: data.original_instruction,
      python_code: data.python_code,
      final_instruction: data[:final_instruction],
      final_module: data[:final_module],
      final_test: data[:final_test],
      refined: data[:refined] || false,
      timestamp: utc_now()
    }

    write(logger, entry)
  end

  # ── Internal ───────────────────────────────────────────────────────

  defp write(%{file: file}, entry) do
    IO.write(file, Jason.encode!(entry) <> "\n")
  rescue
    e ->
      Logger.error("[TrajectoryLogger] write failed: #{inspect(e)}")
  end

  defp format_failures(nil), do: []

  defp format_failures(failures) when is_list(failures) do
    Enum.map(failures, fn {stage, msg} ->
      %{stage: to_string(stage), message: msg}
    end)
  end

  defp format_failures(_), do: []

  defp utc_now, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
