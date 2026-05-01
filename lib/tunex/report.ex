defmodule Tunex.Report do
  @moduledoc """
  Format validation failures for display and LLM error prompts.
  """

  @doc """
  One-line summary of failures with credence rule names.
  Returns string like "(credence: no_manual_max, descriptive_names, compile)"
  """
  def failure_summary(failures) do
    failures
    |> Enum.map(fn {stage, msg} ->
      case stage do
        :credence ->
          rules = extract_credence_rules(msg)
          if rules != [], do: "credence: #{Enum.join(rules, ", ")}", else: "credence"

        other ->
          to_string(other)
      end
    end)
    |> Enum.join(", ")
    |> then(&"(#{&1})")
  end

  @doc "Format failures as text suitable for LLM error prompts."
  def format_errors(failures) do
    Enum.map_join(failures, "\n\n", fn {stage, msg} ->
      "### #{stage} error:\n#{msg}"
    end)
  end

  @doc "Extract unique credence rule names from credence output."
  def extract_credence_rules(msg) do
    Regex.scan(~r/\[(?:warning|info|high)\] ([a-z_]+):/, msg)
    |> Enum.map(fn [_, rule] -> rule end)
    |> Enum.uniq()
  end

  @doc "Count failures by stage from a list of `{entry, status, failures}` tuples."
  def stage_counts(results) do
    results
    |> Enum.flat_map(fn {_, _, failures} -> Enum.map(failures, &elem(&1, 0)) end)
    |> Enum.frequencies()
    |> Enum.sort_by(fn {_, count} -> -count end)
  end

  @doc "Count credence failures by rule name."
  def credence_rule_counts(results) do
    results
    |> Enum.flat_map(fn {_, _, failures} ->
      failures
      |> Enum.filter(fn {stage, _} -> stage == :credence end)
      |> Enum.flat_map(fn {_, msg} -> extract_credence_rules(msg) end)
    end)
    |> Enum.frequencies()
    |> Enum.sort_by(fn {_, count} -> -count end)
  end

  @doc "Count test definitions in test code."
  def count_tests(test_code) when is_binary(test_code) do
    test_code |> String.split("\n") |> Enum.count(&String.contains?(&1, "test \""))
  end
  def count_tests(_), do: 0
end
