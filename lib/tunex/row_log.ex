defmodule Tunex.RowLog do
  @moduledoc """
  Per-row log capture via a native `:logger` file handler (`:logger_std_h`).

  The row's raw log file is the literal input the rule-gen agent reads (solve
  output + the full Credence before/after fix trace + `applied_rules`). v1
  already `Logger.debug`s all of that; RowLog points a dedicated file handler at
  `var/run/logs/<index>.log` per row and manages the file's fate on completion.

  NOTE: `logger_std_h` rejects changing a live handler's destination file
  (`:illegal_config_change`), so each row gets a **fresh handler** (remove +
  add) rather than an in-place path swap. Rows take minutes, so the per-row
  add/remove cost is negligible.

  Lifecycle per row (plan #15 routing table):
    * `open(index)`  — fresh handler → `var/run/logs/<index>.log`
    * `path/1`       — current log path (rule-gen reads after `filesync/0`)
    * `close/1`      — delete the log (ordinary success / no_opportunity)
    * `escalate/1`   — move to `escalated/<index>.log` (dead-end / phantom / reject)
    * `commit/1`     — move to `committed/<index>.log` (rule landed)
  """

  require Logger

  alias Tunex.Config

  @handler :row_file

  @doc "Create the run-scoped log dirs. Safe to call at boot."
  def ensure_ready do
    File.mkdir_p!(logs_dir())
    File.mkdir_p!(Config.run_path("escalated"))
    File.mkdir_p!(Config.run_path("committed"))
    :ok
  end

  # ── Per-row lifecycle ───────────────────────────────────────────────

  @doc "Begin capturing the current row's logs to `var/run/logs/<index>.log`."
  def open(index) do
    ensure_ready()
    path = log_path(index)
    File.write!(path, "")
    add_handler(path)
    path
  end

  @doc "Path of the current row's log file (by index)."
  def path(index), do: log_path(index)

  @doc "Force a filesync so the rule-gen agent reads a complete log."
  def filesync do
    if handler_present?(), do: :logger_std_h.filesync(@handler)
    :ok
  end

  @doc "Ordinary completion: delete the row log."
  def close(index) do
    filesync()
    remove_handler()
    File.rm(log_path(index))
    :ok
  end

  @doc "Move the row log to `escalated/` (dead-end / phantom / Gate reject)."
  def escalate(index), do: move(index, Config.run_path("escalated"))

  @doc "Move the row log to `committed/` (a rule landed)."
  def commit(index), do: move(index, Config.run_path("committed"))

  # ── Internal ────────────────────────────────────────────────────────

  defp move(index, dest_dir) do
    filesync()
    remove_handler()
    File.mkdir_p!(dest_dir)
    src = log_path(index)
    dest = Path.join(dest_dir, "#{index}.log")
    if File.exists?(src), do: File.rename!(src, dest)
    dest
  end

  defp add_handler(path) do
    remove_handler()

    :ok =
      :logger.add_handler(@handler, :logger_std_h, %{
        level: :debug,
        config: %{file: charlist(path)},
        formatter: Logger.Formatter.new(format: "$time [$level] $message\n")
      })
  end

  defp remove_handler do
    if handler_present?(), do: :logger.remove_handler(@handler)
    :ok
  end

  defp handler_present?, do: Enum.member?(:logger.get_handler_ids(), @handler)

  defp logs_dir, do: Config.run_path("logs")
  defp log_path(index), do: Path.join(logs_dir(), "#{index}.log")
  defp charlist(path), do: String.to_charlist(path)
end
