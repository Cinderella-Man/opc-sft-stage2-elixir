defmodule Tunex.Evolve.Git do
  @moduledoc """
  After the Gate passes: **commit → recompile → push**.

  The app never handles credentials — git auth lives in the clone's SSH remote.
  The commit message tags the decision type and flags removals to direct human
  PR attention. Recompiling the credence path dep after committing makes the new
  rule take effect for subsequent rows (and auto-dedups the pattern from future
  output). The push to `origin evolution` is **non-fatal** — a failure warns and
  continues; boot reconciliation catches up later.
  """

  require Logger

  alias Tunex.{Config, Workspace}

  @branch "evolution"

  @doc """
  Commit the staged rule change, recompile credence, and push.

  `summary` is the Gate summary (`:removes`); `opts[:decision]` enriches the
  message. Returns `:ok` (commit succeeded; push best-effort) or
  `{:error, reason}` if the commit itself failed.
  """
  def commit_and_push(idx, summary, opts \\ []) do
    clone = Keyword.get(opts, :clone, Config.credence_clone())
    msg = commit_message(idx, summary, opts)

    git(clone, ["add", "-A"])

    case git(clone, ["commit", "-m", msg]) do
      {_out, 0} ->
        Logger.info("[Git] committed: #{msg}")
        Workspace.recompile_credence()
        push(clone)
        :ok

      {out, code} ->
        Logger.error("[Git] commit failed (exit #{code}): #{out}")
        {:error, {:commit_failed, code}}
    end
  end

  @doc "Compose the tagged commit message."
  def commit_message(idx, summary, opts) do
    decision = Keyword.get(opts, :decision, "update credence rules")
    removes = Map.get(summary, :removes, [])

    removes_tag =
      case removes do
        [] -> ""
        list -> " [removes #{Enum.join(list, ", ")}]"
      end

    "cred-gen: #{decision}#{removes_tag} [row #{idx}]"
  end

  # ── Internal ────────────────────────────────────────────────────────

  defp push(clone) do
    case git(clone, ["push", "origin", @branch]) do
      {_out, 0} ->
        Logger.info("[Git] pushed origin/#{@branch}")
        :ok

      {out, code} ->
        Logger.warning("[Git] push failed (exit #{code}, non-fatal): #{out}")
        :ok
    end
  end

  defp git(clone, args), do: System.cmd("git", args, cd: clone, stderr_to_stdout: true)
end
