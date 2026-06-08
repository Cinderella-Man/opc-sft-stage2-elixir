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

  # Classifier-split outcome dirs (07 §8). Nothing is deleted — every outcome
  # MOVES the log to its dir (08 T6.2/T6.5).
  @outcome_dirs ~w(escalated committed no_action duplicate behaviour_diverged switch_proposals classifier_errors)

  @doc "Create the run-scoped log dirs. Safe to call at boot."
  def ensure_ready do
    File.mkdir_p!(logs_dir())
    Enum.each(@outcome_dirs, fn d -> File.mkdir_p!(Config.run_path(d)) end)
    :ok
  end

  @doc "All classifier-split outcome dir names (for `mix tunex.reset`)."
  def outcome_dirs, do: @outcome_dirs

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

  @doc "Move to `no_action/` (the classifier said NO_ACTION — 07 §8; nothing deleted)."
  def no_action(index), do: move(index, Config.run_path("no_action"))

  @doc "Move to `duplicate/` (novelty pre-check = COVERED)."
  def duplicate(index), do: move(index, Config.run_path("duplicate"))

  @doc "Move to `behaviour_diverged/` (classify-time equiv = DIVERGES)."
  def behaviour_diverged(index), do: move(index, Config.run_path("behaviour_diverged"))

  @doc "Move to `switch_proposals/` (a would-be rule pending a new switch)."
  def switch_proposal(index), do: move(index, Config.run_path("switch_proposals"))

  @doc "Move to `classifier_errors/` (malformed spec after one re-ask)."
  def classifier_errors(index), do: move(index, Config.run_path("classifier_errors"))

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
