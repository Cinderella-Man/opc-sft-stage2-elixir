defmodule Tunex.Implement.Naming do
  @moduledoc """
  Orchestrator-owned naming + generator scaffold (07 §3.8/§5.0/§6.1; 08 T5.4).

  `resolve_and_scaffold/3`: a semantic `proposed_name` → the first free `_N`
  suffix → `mix credence.gen.rule <Pascal> --type <phase>` in the clone (which
  writes honest-red, gate-passing stubs and aborts on collision — a free name
  backstop). Returns the final module + the generator's exact paths + their
  contents (the seed reads these back, §5.3). The model never picks paths.
  """

  alias Tunex.{Config, Credence}

  @type scaffold :: %{
          snake: String.t(),
          pascal: String.t(),
          module: module(),
          phase: atom(),
          paths: [String.t()],
          files: %{optional(String.t()) => String.t()}
        }

  @spec resolve_and_scaffold(String.t(), atom(), String.t()) :: {:ok, scaffold()} | {:error, term()}
  def resolve_and_scaffold(proposed_name, phase, clone \\ Config.credence_clone()) do
    snake = free_snake(proposed_name, phase, clone)
    pascal = Macro.camelize(snake)

    case Credence.gen_rule(pascal, phase, clone) do
      {:ok, paths} ->
        files = Map.new(paths, fn rel -> {rel, read_rel(clone, rel)} end)

        {:ok,
         %{
           snake: snake,
           pascal: pascal,
           module: :"Elixir.Credence.#{phase_mod(phase)}.#{pascal}",
           phase: phase,
           paths: paths,
           files: files
         }}

      {:error, out} ->
        {:error, {:gen_rule_failed, out}}
    end
  end

  # First free snake name (`base`, then `base_2`, `base_3`, …) by checking the
  # clone's `lib/<phase>/<snake>.ex` — independent of pattern novelty (§3.8).
  defp free_snake(base, phase, clone) do
    if rule_exists?(base, phase, clone) do
      Enum.find_value(2..99, "#{base}_collision", fn n ->
        cand = "#{base}_#{n}"
        if rule_exists?(cand, phase, clone), do: false, else: cand
      end)
    else
      base
    end
  end

  defp rule_exists?(snake, phase, clone),
    do: File.exists?(Path.join(clone, "lib/#{phase}/#{snake}.ex"))

  defp read_rel(clone, rel) do
    case File.read(Path.join(clone, rel)) do
      {:ok, content} -> content
      _ -> ""
    end
  end

  defp phase_mod(:pattern), do: "Pattern"
  defp phase_mod(:syntax), do: "Syntax"
  defp phase_mod(:semantic), do: "Semantic"
end
