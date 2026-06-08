defmodule Mix.Tasks.Tunex.Usage do
  @shortdoc "Summarize var/run/usage.jsonl + rows.jsonl: cost by stage and by outcome"
  @moduledoc """
  Reads the two instrumentation ledgers written during a run and prints where
  the money actually goes — split by **stage** (translate / solve / rule-gen)
  and by **row outcome** (committed / no_opportunity / gave_up / …).

      mix tunex.usage            # uses var/run/{usage,rows}.jsonl
      mix tunex.usage path/to    # custom var/run dir

  Token counts are exact (logged per Mimo/CC call); `$` is a best-effort
  estimate at the corrected pay-as-you-go prices (the real plan meters
  discounted Credits, so treat $ as relative, not absolute).
  """
  use Mix.Task

  @impl true
  def run(args) do
    dir = List.first(args) || "var/run"
    usage = read_jsonl(Path.join(dir, "usage.jsonl"))
    rows = read_jsonl(Path.join(dir, "rows.jsonl"))

    if usage == [] do
      Mix.shell().info("No usage data at #{dir}/usage.jsonl — run the loop first.")
    else
      outcome_by_row = Map.new(rows, fn r -> {r["index"], outcome(r)} end)
      report(usage, outcome_by_row)
      projection(rows)
    end
  end

  # Throughput + 24/7 projection from the per-row ledger (ts span + cost_est).
  # Token counts are exact; $ is approximate (the plan meters discounted credits
  # — cross-check the absolute number against the MiMo console).
  defp projection(rows) do
    stamped = Enum.filter(rows, &is_integer(&1["ts"]))
    header("PROJECTION (24/7 feasibility — $ is approximate; verify vs console)")

    if length(stamped) < 2 do
      Mix.shell().info("need ≥2 timestamped rows to project — run more.")
    else
      tss = Enum.map(stamped, & &1["ts"])
      span_h = max((Enum.max(tss) - Enum.min(tss)) / 3600, 1.0e-9)
      n = length(stamped)
      cost = Enum.sum(Enum.map(stamped, &(&1["cost_est"] || 0)))

      rows_hr = n / span_h
      usd_day = cost / span_h * 24

      Mix.shell().info("window: #{Float.round(span_h, 2)}h, #{n} rows → #{Float.round(rows_hr, 1)} rows/hr (#{round(rows_hr * 24)} rows/day)")
      Mix.shell().info("est spend: #{usd(usd_day)}/day → #{usd(usd_day * 30)}/30-day month (APPROX)")
      Mix.shell().info("=> on a $50 plan, est runway ≈ #{Float.round(50 / max(usd_day, 1.0e-9), 1)} days at this rate")
      Mix.shell().info("(authoritative check: read MiMo console credit delta over this window instead of trusting the $ above)")
    end
  end

  # ── Aggregation ───────────────────────────────────────────────────────

  defp report(usage, outcome_by_row) do
    by_stage = Enum.group_by(usage, &stage/1)

    header("BY STAGE (every Mimo/CC call)")
    Enum.each(~w(translate solve classify implement rule-gen other), fn s ->
      calls = Map.get(by_stage, s, [])
      if calls != [], do: print_group(s, calls)
    end)
    print_group("TOTAL", usage)
    model_usage_recon(usage)

    # Per-row cost, then grouped by outcome.
    per_row =
      usage
      |> Enum.group_by(& &1["row"])
      |> Enum.map(fn {row, calls} -> {row, sum_cost(calls), sum_tok(calls, "out")} end)

    by_outcome =
      Enum.group_by(per_row, fn {row, _c, _o} -> Map.get(outcome_by_row, row, "(no row stat)") end)

    header("BY ROW OUTCOME")
    Mix.shell().info(pad("outcome", 22) <> pad("rows", 6) <> pad("mean $", 10) <> pad("total $", 11) <> "mean out-tok")

    by_outcome
    |> Enum.map(fn {o, rs} ->
      cost = Enum.sum(Enum.map(rs, fn {_r, c, _o} -> c end))
      {o, length(rs), cost, Enum.sum(Enum.map(rs, fn {_r, _c, ot} -> ot end))}
    end)
    |> Enum.sort_by(fn {_o, _n, c, _t} -> -c end)
    |> Enum.each(fn {o, n, c, ot} ->
      Mix.shell().info(
        pad(o, 22) <> pad(n, 6) <> pad(usd(c / n), 10) <> pad(usd(c), 11) <> Integer.to_string(div(ot, max(n, 1)))
      )
    end)

    triage_estimate(usage, outcome_by_row)
    headline(by_outcome)
  end

  # Claude Code reports two cumulative token figures per session: `usage` (the
  # standard field, recorded as in/cache_read/cache_create/out) and `modelUsage`
  # (per-model, a few % higher). Show both totals so the ledger isn't blind to
  # the latter — and so the console delta can be matched against whichever is
  # closer to ground truth.
  defp model_usage_recon(usage) do
    cc = Enum.filter(usage, &(&1["kind"] == "cc"))

    usage_tot = Enum.sum(Enum.map(cc, &call_total/1))

    mu_calls = Enum.filter(cc, &is_map(&1["model_usage"]))
    mu_tot = Enum.sum(Enum.map(mu_calls, fn c -> mu_total(c["model_usage"]) end))

    header("MODELUSAGE RECON (rule-gen: result.usage vs modelUsage token totals)")

    cond do
      usage_tot == 0 ->
        Mix.shell().info("no rule-gen calls with usage yet.")

      mu_calls == [] ->
        Mix.shell().info("result.usage total: #{usage_tot} tok — no modelUsage logged (older ledger).")

      true ->
        delta = Float.round(100 * (mu_tot - usage_tot) / usage_tot, 1)
        Mix.shell().info("result.usage total: #{usage_tot} tok (#{length(cc)} calls)")
        Mix.shell().info("modelUsage total:   #{mu_tot} tok (#{length(mu_calls)} calls)")
        Mix.shell().info("Δ modelUsage vs result.usage: #{delta}%  (match your CONSOLE delta to whichever is closer)")
    end
  end

  defp call_total(c),
    do: (c["in"] || 0) + (c["cache_read"] || 0) + (c["cache_create"] || 0) + (c["out"] || 0)

  defp mu_total(mu),
    do: (mu["in"] || 0) + (mu["cache_read"] || 0) + (mu["cache_create"] || 0) + (mu["out"] || 0)

  # The triage/build question, answered from data: how much RULE-GEN spend is
  # burned on no_opportunity rows (the full Claude Code session that finds
  # nothing)? That spend is what a one-shot triage call would replace.
  defp triage_estimate(usage, outcome_by_row) do
    rule_gen = Enum.filter(usage, &(stage(&1) == "rule-gen"))
    by_o = Enum.group_by(rule_gen, fn c -> Map.get(outcome_by_row, c["row"], "(no row stat)") end)

    no_opp = Map.get(by_o, "no_opportunity", [])
    no_opp_rows = no_opp |> Enum.map(& &1["row"]) |> Enum.uniq() |> length()
    no_opp_cost = sum_cost(no_opp)
    rg_total = sum_cost(rule_gen)
    all_rg_rows = rule_gen |> Enum.map(& &1["row"]) |> Enum.uniq() |> length()

    header("TRIAGE/BUILD ESTIMATE (rule-gen spend only)")

    if no_opp_rows > 0 and rg_total > 0 do
      triage_per = 0.002
      saved = no_opp_cost - no_opp_rows * triage_per

      Mix.shell().info("no_opportunity: #{no_opp_rows} of #{all_rg_rows} rule-gen rows")
      Mix.shell().info("  full-session cost on them now: #{usd(no_opp_cost)} (mean #{usd(no_opp_cost / no_opp_rows)}/row)")
      Mix.shell().info("  triage (1 pro call, no tools) ~#{usd(triage_per)}/row → #{usd(no_opp_rows * triage_per)}")
      Mix.shell().info("  => saves #{usd(saved)} of #{usd(rg_total)} rule-gen = #{round(100 * saved / rg_total)}% off rule-gen (#{Float.round(rg_total / max(rg_total - saved, 1.0e-9), 2)}x)")
    else
      Mix.shell().info("no no_opportunity rows yet — run more rows.")
    end
  end

  # The grilling question, answered: how much of total spend is burned on
  # no_opportunity rows (full agent session that finds nothing)?
  defp headline(by_outcome) do
    cost = fn key ->
      by_outcome |> Map.get(key, []) |> Enum.map(fn {_r, c, _o} -> c end) |> Enum.sum()
    end

    total = by_outcome |> Map.values() |> List.flatten() |> Enum.map(fn {_r, c, _o} -> c end) |> Enum.sum()
    no_opp = cost.("no_opportunity")

    header("HEADLINE")
    Mix.shell().info("Total estimated spend: #{usd(total)}")

    if total > 0 do
      Mix.shell().info(
        "no_opportunity rows burned #{usd(no_opp)} (#{round(100 * no_opp / total)}% of spend to find NOTHING)"
      )
    end
  end

  defp print_group(label, calls) do
    Mix.shell().info(
      pad(label, 10) <>
        "calls=" <> pad(length(calls), 7) <>
        "in=" <> pad(sum_tok(calls, "in"), 11) <>
        "cache_rd=" <> pad(sum_tok(calls, "cache_read"), 12) <>
        "out=" <> pad(sum_tok(calls, "out"), 10) <>
        "est=" <> usd(sum_cost(calls))
    )
  end

  # ── Classification ────────────────────────────────────────────────────

  # Prefer the explicit stage tag (T0.2 — classify/implement share the pro
  # provider with translate, so provider-inference is ambiguous now). Fall back
  # to the legacy provider/kind inference for pre-T0.2 ledger lines.
  defp stage(%{"stage" => s}) when is_binary(s) and s != "", do: s
  defp stage(%{"kind" => "cc"}), do: "rule-gen"
  defp stage(%{"kind" => "chat", "provider" => "xiaomi_mimo_2_5_pro"}), do: "translate"
  defp stage(%{"kind" => "chat", "provider" => "xiaomi_mimo_2_5"}), do: "solve"
  defp stage(_), do: "other"

  defp outcome(%{"blacklist" => r}) when not is_nil(r), do: "blacklist:#{r}"
  defp outcome(%{"outcome" => "exception"}), do: "exception"
  defp outcome(%{"rulegen" => rg}) when not is_nil(rg), do: to_string(rg)
  defp outcome(_), do: "(reached solve, no rule-gen)"

  # ── Helpers ───────────────────────────────────────────────────────────

  defp sum_tok(calls, key), do: Enum.sum(Enum.map(calls, &(&1[key] || 0)))
  defp sum_cost(calls), do: Enum.sum(Enum.map(calls, &(&1["cost_usd"] || 0)))

  defp read_jsonl(path) do
    case File.read(path) do
      {:ok, body} ->
        body
        |> String.split("\n", trim: true)
        |> Enum.map(&Jason.decode!/1)

      {:error, _} ->
        []
    end
  end

  defp usd(n), do: "$#{:erlang.float_to_binary(n / 1, decimals: 4)}"
  defp pad(v, n), do: String.pad_trailing(to_string(v), n)
  defp header(t), do: Mix.shell().info("\n=== #{t} ===")
end
