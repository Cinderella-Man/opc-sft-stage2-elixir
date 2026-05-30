defmodule Mix.Tasks.Tunex.Reset do
  @moduledoc """
  Re-initialize a run: wipe `var/run/` and recreate the empty run dirs.

  `var/cache/` (translations + blacklist) is left intact — it survives re-init
  so an expensive Mimo translation is never re-paid. Run scoped state
  (decisions.md, Progress, shuffle seed, SFT output, escalated/, committed/,
  logs, validation workspace) is regenerable and gets wiped.
  """
  use Mix.Task

  @shortdoc "Wipe var/run/ (keeps var/cache/) to start a fresh evolution run"

  @run_dir "var/run"
  @cache_dir "var/cache"
  @run_subdirs ~w(logs escalated committed workspace)

  @impl true
  def run(_args) do
    File.rm_rf!(@run_dir)
    File.mkdir_p!(@run_dir)
    for sub <- @run_subdirs, do: File.mkdir_p!(Path.join(@run_dir, sub))
    File.mkdir_p!(@cache_dir)

    Mix.shell().info("tunex.reset: wiped #{@run_dir}/ (kept #{@cache_dir}/)")
  end
end
