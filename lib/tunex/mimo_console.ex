defmodule Tunex.MimoConsole do
  @moduledoc """
  Reads the **ground-truth** token budget from the MiMo console's own backend
  (`platform.xiaomimimo.com/api/v1/tokenPlan/usage`) — the only authoritative
  source for how fast the monthly token bucket is draining (the in-band
  `usage.jsonl` ledger under-reports it; see docs/04).

  Auth is the Xiaomi-Account **browser session cookie**, NOT the `tp-` API key.
  Provide it via `TUNEX_MIMO_COOKIE` or `config/secrets.exs`
  (`config :tunex, mimo_console_cookie: "cookie-preferences=…; api-platform_serviceToken=…; …"`).
  The cookie EXPIRES (days–weeks) → a `{:error, :auth_expired}` just means re-grab
  it from DevTools; callers treat that as non-fatal.

  Response shape (2026-06):

      %{"code" => 0, "data" => %{
        "monthUsage" => %{"percent" => 0.2648,
          "items" => [%{"name" => "month_total_token",
                        "used" => 10_062_512_128, "limit" => 38_000_000_000, "percent" => 0.2648}]}}}
  """

  require Logger

  @usage_url "https://platform.xiaomimimo.com/api/v1/tokenPlan/usage"
  @detail_url "https://platform.xiaomimimo.com/api/v1/tokenPlan/detail"

  @doc """
  Fetch current monthly usage. Returns
  `{:ok, %{used, limit, remaining, percent}}` (token counts), or
  `{:error, :no_cookie | :auth_expired | {:http, status, body} | {:network, reason}}`.
  """
  def usage(cookie \\ cookie()) do
    with {:ok, body} <- get(@usage_url, cookie) do
      item =
        body
        |> get_in(["data", "monthUsage", "items"])
        |> List.wrap()
        |> List.first()

      case item do
        %{"used" => used, "limit" => limit} when is_number(used) and is_number(limit) ->
          {:ok, %{used: used, limit: limit, remaining: limit - used, percent: item["percent"]}}

        _ ->
          {:error, {:unexpected_shape, body}}
      end
    end
  end

  @doc "Plan detail: `%{plan_code, plan_name, period_end, expired, auto_renew}`."
  def detail(cookie \\ cookie()) do
    with {:ok, body} <- get(@detail_url, cookie) do
      d = body["data"] || %{}

      {:ok,
       %{
         plan_code: d["planCode"],
         plan_name: d["planName"],
         period_end: d["currentPeriodEnd"],
         expired: d["expired"],
         auto_renew: d["enableAutoRenew"]
       }}
    end
  end

  @doc "True if a console cookie is configured (env or secrets)."
  def configured?, do: cookie() not in [nil, ""]

  @doc "The configured cookie (env wins), or nil."
  def cookie do
    case System.get_env("TUNEX_MIMO_COOKIE") do
      c when is_binary(c) and c != "" -> c
      _ -> Application.get_env(:tunex, :mimo_console_cookie)
    end
  end

  # ── Internal ────────────────────────────────────────────────────────

  defp get(_url, cookie) when cookie in [nil, ""], do: {:error, :no_cookie}

  defp get(url, cookie) do
    headers = [
      {"cookie", cookie},
      {"referer", "https://platform.xiaomimimo.com/"},
      {"user-agent", "tunex-budget-poller"}
    ]

    case Req.get(url, headers: headers, receive_timeout: 20_000, retry: false) do
      # The API returns its own `code` in the body; 401 means the cookie is stale.
      {:ok, %{body: %{"code" => 0} = body}} -> {:ok, body}
      {:ok, %{body: %{"code" => 401}}} -> {:error, :auth_expired}
      {:ok, %{status: 401}} -> {:error, :auth_expired}
      {:ok, %{status: status, body: body}} -> {:error, {:http, status, body}}
      {:error, reason} -> {:error, {:network, reason}}
    end
  end
end
