defmodule Tunex.Implement.Output do
  @moduledoc """
  Parse + validate the implementer's whole-file emit (08 T5.2; 07 §5.2).

  **New mode** — fixed-role markers (orchestrator maps roles → the scaffold
  paths): `RULE` + `CHECK_TEST` + `FIX_TEST` always; **Pattern also requires
  `EQUIVALENCE_TEST`** (the hard `equivalence_meta_test`); Syntax/Semantic
  **reject** an `EQUIVALENCE_TEST`. `PROPERTY_TEST` is required **iff** the spec
  carries `assumptions` (§3.12 Tier 1), rejected otherwise.

  **Bugfix mode** — path-keyed `TEST:<path>` markers, each `⊆` the known test
  glob; `RULE` required; ≥1 test; no new/renamed files (modify-only — §5.4).

  Returns `{:ok, result}` or `{:error, reason}`.
    * new:    `%{rule: content, tests: %{role => content}}`
    * bugfix: `%{rule: content, tests: %{path => content}}`
  """

  alias Tunex.Markers

  @doc """
  `opts`:
    * `:mode` — `:new | :bugfix`.
    * `:phase` — `:pattern | :syntax | :semantic` (new mode).
    * `:assumptions?` — boolean (new pattern: PROPERTY_TEST required iff true).
    * `:test_glob` — `[path]` of allowed bugfix test files.
  """
  def parse(text, opts) do
    sections = Markers.split(text)

    case Keyword.fetch!(opts, :mode) do
      :new -> parse_new(to_map(sections), Keyword.fetch!(opts, :phase), Keyword.get(opts, :assumptions?, false))
      :bugfix -> parse_bugfix(sections, Keyword.get(opts, :test_glob, []))
    end
  end

  # ── New mode ─────────────────────────────────────────────────────────────

  defp parse_new(map, phase, assumptions?) do
    with :ok <- require_keys(map, ["RULE", "CHECK_TEST", "FIX_TEST"]),
         :ok <- equivalence_rule(map, phase),
         :ok <- property_rule(map, assumptions?) do
      roles = ["RULE", "CHECK_TEST", "FIX_TEST", "EQUIVALENCE_TEST", "PROPERTY_TEST"]
      tests = Map.take(map, roles -- ["RULE"]) |> Map.reject(fn {_k, v} -> v in [nil, ""] end)
      {:ok, %{rule: map["RULE"], tests: tests}}
    end
  end

  # Pattern MUST carry EQUIVALENCE_TEST; Syntax/Semantic must NOT.
  defp equivalence_rule(map, :pattern) do
    if present?(map["EQUIVALENCE_TEST"]), do: :ok, else: {:error, :pattern_missing_equivalence_test}
  end

  defp equivalence_rule(map, _phase) do
    if present?(map["EQUIVALENCE_TEST"]), do: {:error, :non_pattern_has_equivalence_test}, else: :ok
  end

  defp property_rule(map, true) do
    if present?(map["PROPERTY_TEST"]), do: :ok, else: {:error, :switch_gated_missing_property_test}
  end

  defp property_rule(map, false) do
    if present?(map["PROPERTY_TEST"]), do: {:error, :no_promise_has_property_test}, else: :ok
  end

  # ── Bugfix mode ──────────────────────────────────────────────────────────

  defp parse_bugfix(sections, glob) do
    rule = Enum.find_value(sections, fn {k, v} -> if k == "RULE", do: v end)

    test_pairs =
      for {"TEST:" <> path, content} <- sections, do: {String.trim(path), content}

    cond do
      is_nil(rule) ->
        {:error, :bugfix_missing_rule}

      test_pairs == [] ->
        {:error, :bugfix_no_tests}

      bad = Enum.find(test_pairs, fn {p, _} -> p not in glob end) ->
        {:error, {:test_path_out_of_glob, elem(bad, 0)}}

      true ->
        {:ok, %{rule: rule, tests: Map.new(test_pairs)}}
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp to_map(sections), do: Enum.reduce(sections, %{}, fn {k, v}, acc -> Map.put_new(acc, k, v) end)

  defp require_keys(map, keys) do
    case Enum.find(keys, &(not present?(map[&1]))) do
      nil -> :ok
      missing -> {:error, {:missing_block, missing}}
    end
  end

  defp present?(v), do: is_binary(v) and String.trim(v) != ""
end
