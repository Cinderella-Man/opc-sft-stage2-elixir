defmodule Tunex.Credence do
  @moduledoc """
  Thin wrapper over the Credence clone's CLI (the clone is NOT a loaded dep of
  Tunex — `Code.ensure_loaded?(Credence.*)` is false here, so everything goes
  through `mix` in the clone).

  Currently: the assumptions registry (07 §3.12 — injected into the classifier
  prompt and used by the validation gate). `covers`/`equiv`/`ast`/`gen.rule`
  wrappers are added by Phases 4–5.
  """

  alias Tunex.Config

  @pt_key {__MODULE__, :assumptions}

  @type switch :: %{name: atom(), default: boolean(), summary: String.t()}

  @doc """
  The assumption-switch registry (`Credence.Assumptions.all/0`) as a list of
  `%{name, default, summary}`. Shelled from the clone once and cached for the
  run (switches change only via a human Tier-2 PR between runs).
  """
  @spec assumptions(String.t()) :: [switch()]
  def assumptions(clone \\ Config.credence_clone()) do
    case :persistent_term.get(@pt_key, nil) do
      nil ->
        v = read_assumptions(clone)
        :persistent_term.put(@pt_key, v)
        v

      v ->
        v
    end
  end

  @doc "Just the switch names (⊆-check for the classifier `assumptions` gate)."
  @spec assumption_names(String.t()) :: [atom()]
  def assumption_names(clone \\ Config.credence_clone()), do: assumptions(clone) |> Enum.map(& &1.name)

  @doc "Test seam: prime the cache directly (skips shelling)."
  def put_assumptions(list) when is_list(list), do: :persistent_term.put(@pt_key, list)

  # ── covers (novelty pre-check, 07 §3.7) ─────────────────────────────────

  @doc """
  `mix credence.covers` on a full-`defmodule` snippet → `:covered | :novel`.
  COVERED = a real rule engaged (code changed / applied_rules / non-parse-error
  issue). Runs in the `:dev` build of the clone.
  """
  @spec covers?(String.t(), String.t()) :: :covered | :novel
  def covers?(snippet, clone \\ Config.credence_clone()) do
    path = Path.join(System.tmp_dir!(), "covers_#{System.unique_integer([:positive])}.exs")
    File.write!(path, snippet)

    {out, _code} =
      System.cmd("mix", ["credence.covers", path], cd: clone, stderr_to_stdout: true)

    File.rm(path)
    if verdict_line(out, ~r/^(COVERED|NOVEL)$/) == "COVERED", do: :covered, else: :novel
  end

  # ── equiv (behavioural-equivalence trichotomy, 07 §3.11) ────────────────

  @doc """
  `MIX_ENV=test mix credence.equiv` on expression-level before/after + vars.
  Returns the raw verdict line (`EQUIVALENT [minimal_set=...]` / `REPAIR ...` /
  `DIVERGES ...`). `opts`: `:assumptions` (list of atoms), `:minimal_set` (bool),
  `:dim` (comma string). Writes the two expressions to temp files.
  """
  @spec equiv(String.t(), String.t(), [String.t()], keyword()) :: String.t()
  def equiv(before_expr, after_expr, vars, opts \\ []) do
    clone = Keyword.get(opts, :clone, Config.credence_clone())
    bf = Path.join(System.tmp_dir!(), "equiv_before_#{System.unique_integer([:positive])}.exs")
    af = Path.join(System.tmp_dir!(), "equiv_after_#{System.unique_integer([:positive])}.exs")
    File.write!(bf, before_expr)
    File.write!(af, after_expr)

    args =
      ["credence.equiv", "--before", bf, "--after", af, "--vars", Enum.join(vars, ",")]
      |> maybe_arg("--dim", opts[:dim])
      |> maybe_arg("--assumptions", assumptions_arg(opts[:assumptions]))
      |> maybe_flag("--minimal-set", Keyword.get(opts, :minimal_set, false))

    {out, _code} =
      System.cmd("mix", args, cd: clone, stderr_to_stdout: true, env: [{"MIX_ENV", "test"}])

    File.rm(bf)
    File.rm(af)
    verdict_line(out, ~r/^(EQUIVALENT|REPAIR|DIVERGES)\b/)
  end

  defp assumptions_arg(nil), do: nil
  defp assumptions_arg([]), do: nil
  defp assumptions_arg(list), do: Enum.join(list, ",")

  defp maybe_arg(args, _flag, nil), do: args
  defp maybe_arg(args, flag, val), do: args ++ [flag, val]

  defp maybe_flag(args, _flag, false), do: args
  defp maybe_flag(args, flag, true), do: args ++ [flag]

  # ── ast (AST dump for the implementer seed, 07 §6) ──────────────────────

  @doc "`mix credence.ast` on a snippet → the raw + layout-stripped dump string."
  @spec ast(String.t(), String.t()) :: String.t()
  def ast(snippet, clone \\ Config.credence_clone()) do
    path = Path.join(System.tmp_dir!(), "ast_#{System.unique_integer([:positive])}.exs")
    File.write!(path, snippet)
    {out, _code} = System.cmd("mix", ["credence.ast", path], cd: clone, stderr_to_stdout: true)
    File.rm(path)
    out
  end

  # ── gen.rule (scaffold generator, 07 §5.0/§6.1) ─────────────────────────

  @doc """
  `mix credence.gen.rule <Pascal> --type <phase>` in the clone. Returns
  `{:ok, [created_path]}` (clone-relative) or `{:error, output}` (e.g. a path
  collision — the generator's free name backstop). Paths are parsed from the
  task's `* created <path>` lines.
  """
  @spec gen_rule(String.t(), atom(), String.t()) :: {:ok, [String.t()]} | {:error, String.t()}
  def gen_rule(pascal_name, phase, clone \\ Config.credence_clone()) do
    {out, code} =
      System.cmd("mix", ["credence.gen.rule", pascal_name, "--type", to_string(phase)],
        cd: clone,
        stderr_to_stdout: true
      )

    if code == 0 do
      paths =
        Regex.scan(~r/^\* created (.+)$/m, out)
        |> Enum.map(fn [_, p] -> String.trim(p) end)

      {:ok, paths}
    else
      {:error, out}
    end
  end

  # Find the verdict line matching `re` (the task prints log noise around it).
  # Last match wins (defensive against an echoed prompt).
  defp verdict_line(out, re) do
    out
    |> String.split("\n", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&Regex.match?(re, &1))
    |> List.last()
    |> Kernel.||("")
  end

  defp read_assumptions(clone) do
    script =
      ~S'Enum.each(Credence.Assumptions.all(), fn {n, m} -> IO.puts("ASSUMP\t#{n}\t#{m.default}\t#{m.summary}") end)'

    {out, _code} =
      System.cmd("mix", ["run", "-e", script], cd: clone, stderr_to_stdout: true)

    out
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case String.split(line, "\t") do
        ["ASSUMP", name, default, summary] ->
          [%{name: String.to_atom(name), default: default == "true", summary: summary}]

        _ ->
          []
      end
    end)
  end
end
