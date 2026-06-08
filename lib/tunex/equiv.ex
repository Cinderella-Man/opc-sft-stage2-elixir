defmodule Tunex.Equiv do
  @moduledoc """
  Classify-time behavioural-equivalence check (07 §3.11, 08 T4.3a).

  The classifier emits `before`/`after` as full `defmodule`s, but `credence.equiv`
  is **expression-level** (07 §3.11 honest limits). `extract/1` bridges them: it
  pulls the single public `def`'s **parameter names (→ vars)** and **body
  expression** out of a simple single-clause module. When the rewrite is
  module-structural (T2 — multi-clause, pattern params, >1 var, multiple defs)
  extraction returns `:error` and `check/2` returns **`:skipped`** — the safety
  net there is the built rule's mandatory `_equivalence_test` at the Gate.

  `check/2` returns:
    * `{:equivalent, minimal_switch_set}` — proceed (no-promise if `[]`, else
      switch-gated; the set OVERRIDES/corrects the spec's `assumptions` tag),
    * `{:repair, evidence}` — proceed in repair sub-mode (`mark_equivalence_repair`),
    * `{:diverges, detail}` — behaviour-changing ⇒ `NO_ACTION` → `behaviour_diverged/`,
    * `:skipped` — T2 / un-extractable; defer to the Gate's per-rule equiv test.
  """

  alias Tunex.Credence

  @type verdict ::
          {:equivalent, [atom()]} | {:repair, String.t()} | {:diverges, String.t()} | :skipped

  @spec check(Tunex.Classify.Spec.t(), keyword()) :: verdict()
  def check(%{before: before, after: after_src, assumptions: assumptions}, opts \\ []) do
    with {:ok, vars, before_expr} <- extract(before),
         {:ok, _avars, after_expr} <- extract(after_src),
         true <- length(vars) == 1 do
      Credence.equiv(before_expr, after_expr, vars,
        minimal_set: true,
        assumptions: assumptions,
        clone: Keyword.get(opts, :clone, Tunex.Config.credence_clone())
      )
      |> interpret()
    else
      _ -> :skipped
    end
  end

  @doc "Extract `{:ok, vars, body_expr}` from a single-public-def module, or `:error`."
  @spec extract(String.t() | nil) :: {:ok, [String.t()], String.t()} | :error
  def extract(nil), do: :error

  def extract(module_src) do
    case Code.string_to_quoted(module_src) do
      {:ok, ast} -> find_def(ast)
      _ -> :error
    end
  end

  defp find_def(ast) do
    {_ast, found} =
      Macro.prewalk(ast, nil, fn
        {:def, _, [head, kw]} = node, nil -> {node, head_body(head, kw)}
        node, acc -> {node, acc}
      end)

    found || :error
  end

  # `def f(a, b) when guard do/, do: body` → strip the guard wrapper.
  defp head_body({:when, _, [head, _guard]}, kw), do: head_body(head, kw)

  defp head_body({_name, _, args}, kw) when is_list(kw) do
    body = Keyword.get(kw, :do)
    params = if is_list(args), do: args, else: []

    case vars(params) do
      {:ok, names} when body != nil -> {:ok, names, Macro.to_string(body)}
      _ -> nil
    end
  end

  defp head_body(_other, _kw), do: nil

  # All params must be simple variables (no pattern destructuring) to map to
  # `credence.equiv` vars.
  defp vars(params) do
    Enum.reduce_while(params, {:ok, []}, fn
      {name, _, ctx}, {:ok, acc} when is_atom(name) and is_atom(ctx) ->
        {:cont, {:ok, acc ++ [Atom.to_string(name)]}}

      _other, _acc ->
        {:halt, :error}
    end)
  end

  # ── Verdict interpretation ──────────────────────────────────────────────

  defp interpret("EQUIVALENT" <> rest) do
    {:equivalent, parse_minimal_set(rest)}
  end

  defp interpret("REPAIR" <> rest), do: {:repair, String.trim(rest)}
  defp interpret("DIVERGES" <> rest), do: {:diverges, String.trim(rest)}
  defp interpret(_), do: :skipped

  # " minimal_set=[single_codepoint_graphemes]" → [:single_codepoint_graphemes];
  # "minimal_set=[]" / "" → [].
  defp parse_minimal_set(rest) do
    case Regex.run(~r/minimal_set=\[(.*?)\]/, rest) do
      [_, inner] ->
        inner
        |> String.split(",", trim: true)
        |> Enum.map(&(&1 |> String.trim() |> String.to_atom()))

      _ ->
        []
    end
  end
end
