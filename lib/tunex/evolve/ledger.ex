defmodule Tunex.Evolve.Ledger do
  @moduledoc """
  The `var/run/decisions.md` dead-end ledger (plan #8).

  Written by the orchestrator (never the agent) for **dead-ends only**:
  `gave_up` patterns, Gate rejections, and phantoms. It is NOT written for
  `no_opportunity` rows (the majority), so it stays small — and the whole ledger
  is inlined into every rule-gen prompt so the agent won't retry these.

  Append-always (no auto-dedup; the agent reading it is what prevents
  re-proposing). Run-scoped — wiped by `mix tunex.reset`.
  """

  alias Tunex.Config

  @doc "Path to the ledger file."
  def path, do: Config.run_path("decisions.md")

  @doc "Full ledger contents, or `\"\"` if none yet."
  def read do
    p = path()
    if File.exists?(p), do: File.read!(p), else: ""
  end

  @doc "Append a dead-end entry (a markdown block)."
  def append(body) do
    p = path()
    File.mkdir_p!(Path.dirname(p))
    File.write!(p, body <> "\n\n", [:append, :utf8])
    :ok
  end

  @doc "Compose + append a `gave_up` dead-end entry."
  def gave_up(index, detail) do
    append("## row #{index} — gave_up\n#{detail}")
  end

  @doc "Compose + append a Gate-rejection entry."
  def gate_reject(index, reason, decision) do
    append("## row #{index} — gate_reject (#{inspect(reason)})\nattempted: #{decision}")
  end

  @doc "Compose + append a phantom entry (claimed success, clean tree)."
  def phantom(index, decision) do
    append("## row #{index} — phantom\nagent reported success but produced no diff (#{decision})")
  end
end
