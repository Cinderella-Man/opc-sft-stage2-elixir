defmodule Tunex.RulePaths do
  @moduledoc """
  Resolve a rule module → its source file + test glob in the clone (08 T2.4).

  `resolve/2` greps the clone for `defmodule <Mod> do` (the total, deterministic
  name→path mapping the BUGFIX lane relies on) and returns the single
  `lib/<phase>/<name>.ex` plus its `test/<phase>/<name>*_test.exs` glob. Exactly
  one source match is required — 0 or >1 is an error (a phantom or ambiguous
  rule must never send the implementer chasing the wrong file).
  """

  alias Tunex.Config

  @type resolved :: %{
          module: module(),
          phase: String.t(),
          rule_path: String.t(),
          test_paths: [String.t()]
        }

  @spec resolve(module(), String.t()) :: {:ok, resolved()} | {:error, term()}
  def resolve(module, clone \\ Config.credence_clone()) when is_atom(module) do
    modname = module |> Atom.to_string() |> String.replace_prefix("Elixir.", "")

    case grep_defmodule(modname, clone) do
      [rel] ->
        name = Path.basename(rel, ".ex")
        phase = rel |> Path.dirname() |> Path.basename()

        tests =
          Path.join(clone, "test/#{phase}/#{name}*_test.exs")
          |> Path.wildcard()
          |> Enum.map(&Path.relative_to(&1, clone))

        {:ok, %{module: module, phase: phase, rule_path: rel, test_paths: tests}}

      [] ->
        {:error, {:not_found, modname}}

      many ->
        {:error, {:ambiguous, modname, many}}
    end
  end

  # grep -rl returns clone-relative paths (cwd = clone). Exit 1 = no match.
  defp grep_defmodule(modname, clone) do
    case System.cmd("grep", ["-rl", "defmodule #{modname} do", "lib/"],
           cd: clone,
           stderr_to_stdout: true
         ) do
      {out, 0} -> String.split(out, "\n", trim: true)
      _ -> []
    end
  end
end
