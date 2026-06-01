defmodule Mix.Tasks.Tunex.Budget do
  @shortdoc "Read the live MiMo token-bucket balance from the console API"
  @moduledoc """
  Queries the MiMo console for the AUTHORITATIVE monthly token usage (the
  ground truth the in-band ledger under-reports). Needs the console cookie in
  `TUNEX_MIMO_COOKIE` or `config/secrets.exs` (`mimo_console_cookie`).

      mix tunex.budget

  Prints used / limit / remaining tokens, % consumed, plan + period end, and a
  crude runway estimate. Cookie stale → tells you to re-grab it from DevTools.
  """
  use Mix.Task

  alias Tunex.MimoConsole

  @impl true
  def run(_args) do
    Mix.Task.run("app.start")

    unless MimoConsole.configured?() do
      Mix.shell().error("""
      No console cookie configured. Add to config/secrets.exs:
          config :tunex, mimo_console_cookie: "cookie-preferences=…; api-platform_serviceToken=…; userId=…; api-platform_slh=…; api-platform_ph=…"
      or export TUNEX_MIMO_COOKIE='…'. Grab it from DevTools → Network → tokenPlan/usage → Copy as cURL.
      """)
    else
      report()
    end
  end

  defp report do
    case MimoConsole.usage() do
      {:ok, u} ->
        pct = (u.percent || u.used / max(u.limit, 1)) * 100

        Mix.shell().info("""
        === MiMo token bucket (console ground truth) ===
        used:      #{fmt(u.used)} tokens
        limit:     #{fmt(u.limit)} tokens
        remaining: #{fmt(u.remaining)} tokens
        consumed:  #{Float.round(pct, 2)}%
        """)

        detail_line()
        runway(u)

      {:error, :auth_expired} ->
        Mix.shell().error("Console cookie expired — re-grab it (DevTools → Network → tokenPlan/usage → Copy as cURL).")

      {:error, reason} ->
        Mix.shell().error("Could not read console usage: #{inspect(reason)}")
    end
  end

  defp detail_line do
    case MimoConsole.detail() do
      {:ok, d} ->
        Mix.shell().info("plan: #{d.plan_name} (#{d.plan_code}) · period ends #{d.period_end} · auto-renew #{d.auto_renew}")

      _ ->
        :ok
    end
  end

  # Crude runway: remaining ÷ even-daily-allowance, and remaining ÷ (used so far
  # this period, assuming it accrued evenly). Both are rough — the console delta
  # over a real day is the real number.
  defp runway(u) do
    daily_budget = u.limit / 30
    Mix.shell().info("even-pace budget: #{fmt(round(daily_budget))} tokens/day (limit ÷ 30)")

    if u.used > 0 do
      Mix.shell().info(
        "if today's burn ≈ #{Float.round((u.percent || u.used / u.limit) * 100, 1)}% of the bucket, runway ≈ " <>
          "#{Float.round(u.remaining / max(u.used, 1), 1)}× today's spend"
      )
    end
  end

  defp fmt(n) when is_integer(n) do
    n |> Integer.to_string() |> String.reverse() |> String.replace(~r/(\d{3})(?=\d)/, "\\1,") |> String.reverse()
  end

  defp fmt(n), do: to_string(n)
end
