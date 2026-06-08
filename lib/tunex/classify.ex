defmodule Tunex.Classify do
  @moduledoc """
  The classifier stage (07 §3; 08 T3.3): one raw `Tunex.LLM` call that consumes
  the distilled row log + the APPLIED_RULES closed set + the ledger and emits a
  marker-fenced spec, validated by deterministic gates with ONE re-ask.

  Returns `{:ok, %Tunex.Classify.Spec{}}` or `{:error, {:classifier_errors,
  reason, raw}}` (the row moves to `classifier_errors/`).

  Validation gates (§4.3):
    * `decision` ∈ the OFFERED set (option-shaped from the closed set, §3.3);
    * `BUGFIX_RULE` ⇒ `rule_name` ∈ closed set AND resolves to a clone file;
    * `POTENTIAL_NEW_RULE` ⇒ `phase` valid, `proposed_name` snake_case, `before`
      a full `defmodule`, `after` PRESENT, phase-conditional **parse** of
      before/after (pattern/semantic parse; syntax skipped). The pattern COMPILE
      gate is folded into the novelty pre-check (`covers` requires compilable
      input) — at classify-time we parse only, to avoid in-VM module pollution;
    * `assumptions` ⊆ the registry (unknown ⇒ invalid → re-ask);
    * `SWITCH_PROPOSAL` ⇒ a `proposed_switch` is present.
  """

  require Logger

  alias Tunex.{AppliedRules, Credence, Distill, LLM, RulePaths}
  alias Tunex.Classify.{Parser, Prompt, Spec}
  alias Tunex.Evolve.Ledger

  @snake ~r/^[a-z][a-z0-9_]*$/

  @doc """
  Classify a row. `solve_outcome` is `:solved | :failed`. `opts`:
    * `:closed_set` — override (defaults to parsing the log).
    * `:assumptions` — override registry (defaults to `Tunex.Credence`).
    * `:ledger` — override (defaults to `Ledger.read/0`).
    * `:llm` — a 2-arity fn `(user, system) -> {:ok|:truncated, content, usage} | {:error, _}`
      (test seam; defaults to `LLM.for_stage(:classify, …)`).
    * `:clone` — clone path for rule resolution.
  """
  def run(log, solve_outcome, opts \\ []) when solve_outcome in [:solved, :failed] do
    distilled = Distill.distill(log)
    closed = Keyword.get_lazy(opts, :closed_set, fn -> log |> AppliedRules.parse() |> AppliedRules.modules() end)
    assumptions = Keyword.get_lazy(opts, :assumptions, fn -> Credence.assumptions() end)
    ledger = Keyword.get_lazy(opts, :ledger, fn -> Ledger.read() end)
    clone = Keyword.get(opts, :clone, Tunex.Config.credence_clone())

    ctx = %{
      offered: Prompt.offered_decisions(closed),
      closed: closed,
      assumption_names: Enum.map(assumptions, & &1.name),
      clone: clone
    }

    user =
      Prompt.build(
        distilled_log: distilled,
        closed_set: closed,
        ledger: ledger,
        assumptions: assumptions,
        solve_outcome: solve_outcome
      )

    llm = Keyword.get(opts, :llm, &default_llm/2)

    attempt(user, Prompt.system(), llm, ctx, 1)
  end

  # ── Attempt + one re-ask ────────────────────────────────────────────────

  defp attempt(user, system, llm, ctx, n) do
    case llm.(user, system) do
      {tag, content, _usage} when tag in [:ok, :truncated] ->
        with {:ok, spec} <- Parser.parse(content),
             :ok <- validate(spec, ctx) do
          {:ok, spec}
        else
          {:error, reason} -> reask_or_fail(user, system, llm, ctx, n, reason, content)
        end

      {:error, reason} ->
        {:error, {:classifier_errors, {:llm_error, reason}, ""}}
    end
  end

  defp reask_or_fail(_user, _system, _llm, _ctx, 2, reason, content) do
    {:error, {:classifier_errors, reason, content}}
  end

  defp reask_or_fail(user, system, llm, ctx, 1, reason, _content) do
    Logger.info("[Classify] re-ask after invalid spec: #{inspect(reason)}")
    reask_user = user <> "\n\n## YOUR PREVIOUS REPLY WAS INVALID\nFix this and re-send the full spec: #{inspect(reason)}\n"
    attempt(reask_user, system, llm, ctx, 2)
  end

  # ── Validation gates ─────────────────────────────────────────────────────

  defp validate(%Spec{decision: d} = spec, ctx) do
    with :ok <- check_offered(d, ctx),
         :ok <- check_decision(spec, ctx) do
      :ok
    end
  end

  defp check_offered(decision, ctx) do
    if up(decision) in ctx.offered, do: :ok, else: {:error, {:decision_not_offered, decision}}
  end

  defp check_decision(%Spec{decision: :no_action}, _ctx), do: :ok

  defp check_decision(%Spec{decision: :bugfix_rule, rule_name: name}, ctx) do
    cond do
      is_nil(name) -> {:error, :bugfix_missing_rule_name}
      name not in ctx.closed -> {:error, {:rule_name_not_in_closed_set, name}}
      match?({:error, _}, RulePaths.resolve(name, ctx.clone)) -> {:error, {:rule_name_unresolvable, name}}
      true -> :ok
    end
  end

  defp check_decision(%Spec{decision: :potential_new_rule} = s, ctx) do
    with :ok <- require_phase(s.phase),
         :ok <- require_snake(s.proposed_name),
         :ok <- require_before(s),
         :ok <- require_after(s),
         :ok <- check_assumptions(s.assumptions, ctx) do
      :ok
    end
  end

  defp check_decision(%Spec{decision: :switch_proposal, proposed_switch: ps, before: before}, _ctx) do
    cond do
      is_nil(ps) -> {:error, :switch_proposal_missing_switch}
      is_nil(before) -> {:error, :switch_proposal_missing_before}
      true -> :ok
    end
  end

  defp require_phase(p) when p in [:pattern, :syntax, :semantic], do: :ok
  defp require_phase(p), do: {:error, {:bad_phase, p}}

  defp require_snake(name) when is_binary(name) do
    if Regex.match?(@snake, name), do: :ok, else: {:error, {:bad_proposed_name, name}}
  end

  defp require_snake(_), do: {:error, :missing_proposed_name}

  # `before` must be present and (phase-conditional) parse. Syntax targets
  # non-parsing code, so the parse gate is skipped there.
  defp require_before(%Spec{before: nil}), do: {:error, :missing_before}
  defp require_before(%Spec{phase: :syntax}), do: :ok
  defp require_before(%Spec{before: src}), do: parses?(src, :before)

  # `after` is MANDATORY for any proposed rule (no check-only). It must parse
  # for non-syntax phases.
  defp require_after(%Spec{after: nil}), do: {:error, :missing_after}
  defp require_after(%Spec{phase: :syntax}), do: :ok
  defp require_after(%Spec{after: src}), do: parses?(src, :after)

  defp check_assumptions(assumptions, ctx) do
    case Enum.reject(assumptions, &(&1 in ctx.assumption_names)) do
      [] -> :ok
      unknown -> {:error, {:unknown_assumptions, unknown}}
    end
  end

  defp parses?(src, which) do
    case Code.string_to_quoted(src) do
      {:ok, _} -> :ok
      {:error, _} -> {:error, {:does_not_parse, which}}
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp up(:no_action), do: "NO_ACTION"
  defp up(:bugfix_rule), do: "BUGFIX_RULE"
  defp up(:potential_new_rule), do: "POTENTIAL_NEW_RULE"
  defp up(:switch_proposal), do: "SWITCH_PROPOSAL"

  defp default_llm(user, system), do: LLM.for_stage(:classify, user, system)
end
