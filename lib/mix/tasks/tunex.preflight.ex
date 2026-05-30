defmodule Mix.Tasks.Tunex.Preflight do
  @moduledoc """
  Validate the full live setup **without** starting the paid row loop.

  Runs the same preflight + reconciliation the Orchestrator runs at boot:
  clone exists + on `evolution` + clean, `claude` on PATH, secrets present,
  reconcile (reset/clean/push catch-up/deps.get/workspace build/recompile), then
  the live smoke tests — a one-shot Claude Code call against Mimo and a tiny Mimo
  chat call — plus a credence compile. Halts with actionable guidance on any
  miss; prints "preflight OK" and exits 0 on success.

  Use this before `TUNEX_RUN=1 mix run --no-halt` to confirm credentials and the
  clone are good with only two tiny Mimo calls of spend.
  """
  use Mix.Task

  @shortdoc "Validate clone + Mimo + CC setup without running the loop"

  @impl true
  def run(_args) do
    {:ok, _} = Application.ensure_all_started(:tunex)
    Tunex.Preflight.run!()
    Mix.shell().info("\n✓ preflight OK — ready to run: TUNEX_RUN=1 TUNEX_SOLVE_PROVIDER=xiaomi_mimo_2_5_pro mix run --no-halt")
  end
end
