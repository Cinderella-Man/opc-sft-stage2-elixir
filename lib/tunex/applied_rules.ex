defmodule Tunex.AppliedRules do
  @moduledoc """
  Parse the closed set of rules that actually fired from a row log (08 T2.3).

  Credence's fix script emits one `APPLIED_RULES: [{Module, count | :reverted}]`
  line per solve attempt (workspace.ex). `parse/1` collects every entry across
  every attempt **un-deduped** (intermediate over-firing matters — a rule can
  over-fire on an early attempt and be masked by a later rewrite).

  Drives:
    * the `:reverted` deterministic bugfix lane (`reverted/1`, 07 §3.9),
    * BUGFIX closed-set validation + option-shaping (`modules/1`, 07 §3.3/§4.3).
  """

  # APPLIED_RULES: [ ... ]  — capture the bracketed list body.
  @line ~r/APPLIED_RULES:\s*\[(?<body>.*)\]/
  # {Credence.Pattern.Foo, 3}  or  {Credence.Pattern.Foo, :reverted}
  @pair ~r/\{\s*(?<mod>[A-Z][A-Za-z0-9_.]*)\s*,\s*(?<count>:reverted|\d+)\s*\}/

  @type entry :: {module(), non_neg_integer() | :reverted}

  @spec parse(String.t()) :: [entry()]
  def parse(log) when is_binary(log) do
    log
    |> String.split("\n")
    |> Enum.flat_map(&parse_line/1)
  end

  @doc "The `:reverted` culprits (Pattern rules that broke compilation, 07 §3.9)."
  @spec reverted([entry()]) :: [module()]
  def reverted(entries) do
    for {mod, :reverted} <- entries, do: mod
  end

  @doc "Unique fired modules — the BUGFIX closed set (any count, incl. :reverted)."
  @spec modules([entry()]) :: [module()]
  def modules(entries) do
    entries |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
  end

  defp parse_line(line) do
    case Regex.named_captures(@line, line) do
      %{"body" => body} ->
        @pair
        |> Regex.scan(body, capture: ["mod", "count"])
        |> Enum.map(&to_entry/1)

      nil ->
        []
    end
  end

  defp to_entry([mod, ":reverted"]), do: {module_atom(mod), :reverted}
  defp to_entry([mod, count]), do: {module_atom(mod), String.to_integer(count)}

  # Build the module atom from its source name without requiring it loaded
  # (the clone may carry a rule not yet recompiled into this build).
  defp module_atom(name), do: :"Elixir.#{name}"
end
