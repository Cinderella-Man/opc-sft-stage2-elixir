defmodule Tunex do
  @moduledoc """
  Tunex v2 — a self-evolving Elixir SFT converter.

  Walks the OpenCoder SFT dataset once in a seeded-shuffle order; per row it
  translates (remote Mimo) → round-trip checks → solves (local Qwen) →
  validates → drives a Claude-Code agent (Mimo) to generate/extend/fix a
  Credence rule. The primary goal is rule discovery; dataset conversion is the
  workload that surfaces where Credence is weak.

  See `docs/plan.md` for the full design.
  """

  require Logger

  @sft_handle_keys [{__MODULE__, :sft_out}, {__MODULE__, :sft_err}]

  @doc """
  Graceful shutdown. Flushes/syncs/closes durable handles (RowLog + the SFT /
  error file handles registered in `:persistent_term`), then halts the VM
  cleanly so the supervisor cannot restart into a fatal storm. Never raises.
  """
  def shutdown(reason) do
    Logger.error("[Tunex.shutdown] halting: #{inspect(reason)}")

    safe(fn -> Tunex.RowLog.filesync() end)

    for key <- @sft_handle_keys do
      case :persistent_term.get(key, nil) do
        nil -> :ok
        handle -> safe(fn -> :file.sync(handle) end) && safe(fn -> :file.close(handle) end)
      end
    end

    System.halt(1)
  end

  @doc false
  def sft_handle_keys, do: @sft_handle_keys

  defp safe(fun) do
    fun.()
    true
  rescue
    _ -> true
  catch
    _, _ -> true
  end
end
