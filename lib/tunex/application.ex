defmodule Tunex.Application do
  @moduledoc """
  OTP application entry point + supervision tree.

  `Tunex.Cache` and `Tunex.Budget` always run. The `Tunex.Orchestrator` (which
  drives the full seeded-shuffle pass, including the halting preflight) starts
  **only** when `TUNEX_RUN=1` — so `mix test`, `mix run -e …`, and other dev
  invocations boot the app without kicking off a real run.

  The per-row `:logger` file handler is managed by `Tunex.RowLog` (fresh handler
  per row); `RowLog.ensure_ready/0` creates its dirs at boot.

  Real run: `TUNEX_RUN=1 mix run --no-halt`
  (GPU-less: add `TUNEX_SOLVE_PROVIDER=xiaomi_mimo_2_5_pro`).
  """

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    Tunex.RowLog.ensure_ready()

    children = [Tunex.Cache, Tunex.Budget] ++ orchestrator_child()

    opts = [strategy: :one_for_one, name: Tunex.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp orchestrator_child do
    if System.get_env("TUNEX_RUN") == "1" do
      Logger.info("[Application] TUNEX_RUN=1 — starting Orchestrator")
      [Tunex.Orchestrator]
    else
      []
    end
  end
end
