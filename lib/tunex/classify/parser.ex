defmodule Tunex.Classify.Parser do
  @moduledoc """
  Parse the classifier's marker-fenced output into a `Tunex.Classify.Spec`
  (08 T3.2). Structure only — the deterministic validation gates (offered set,
  phase-conditional parse/compile, `after` mandatory, assumptions ⊆ registry)
  live in `Tunex.Classify` (T3.3).
  """

  alias Tunex.{Markers, Classify.Spec}

  @decisions %{
    "NO_ACTION" => :no_action,
    "BUGFIX_RULE" => :bugfix_rule,
    "POTENTIAL_NEW_RULE" => :potential_new_rule,
    "SWITCH_PROPOSAL" => :switch_proposal
  }

  @phases %{"pattern" => :pattern, "syntax" => :syntax, "semantic" => :semantic}

  @spec parse(String.t()) :: {:ok, Spec.t()} | {:error, term()}
  def parse(text) when is_binary(text) do
    m = Markers.to_map(text)

    with {:ok, decision} <- decision(m) do
      {:ok,
       %Spec{
         decision: decision,
         rule_name: rule_name(m),
         proposed_name: blank_to_nil(m["PROPOSED_NAME"]),
         phase: phase(m),
         before: blank_to_nil(m["BEFORE"]),
         after: blank_to_nil(m["AFTER"]),
         assumptions: assumptions(m),
         proposed_switch: proposed_switch(decision, m),
         rationale: blank_to_nil(m["RATIONALE"])
       }}
    end
  end

  defp decision(m) do
    case m["DECISION"] && String.trim(m["DECISION"]) do
      nil -> {:error, :missing_decision}
      raw -> Map.fetch(@decisions, raw) |> case do
               {:ok, d} -> {:ok, d}
               :error -> {:error, {:bad_decision, raw}}
             end
    end
  end

  # BUGFIX rule_name is a module name (e.g. Credence.Pattern.Foo) → module atom.
  defp rule_name(m) do
    case blank_to_nil(m["RULE_NAME"]) do
      nil -> nil
      raw -> :"Elixir.#{String.trim(raw) |> String.replace_prefix("Elixir.", "")}"
    end
  end

  defp phase(m) do
    case blank_to_nil(m["PHASE"]) do
      nil -> nil
      raw -> Map.get(@phases, String.trim(raw))
    end
  end

  defp assumptions(m) do
    (m["ASSUMPTIONS"] || "")
    |> String.split([",", " ", "\n"], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&String.to_atom/1)
  end

  # PROPOSED_SWITCH block (§3.12 Tier 2): `key: value` lines (name/summary/
  # default/divergence_class). Parsed best-effort; kept whole for the human.
  defp proposed_switch(:switch_proposal, m) do
    raw = m["PROPOSED_SWITCH"] || ""

    fields =
      raw
      |> String.split("\n", trim: true)
      |> Enum.flat_map(fn line ->
        case String.split(line, ":", parts: 2) do
          [k, v] -> [{k |> String.trim() |> String.downcase(), String.trim(v)}]
          _ -> []
        end
      end)
      |> Map.new()

    Map.put(fields, :raw, String.trim(raw))
  end

  defp proposed_switch(_other, _m), do: nil

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(s) when is_binary(s), do: if(String.trim(s) == "", do: nil, else: String.trim(s))
end
