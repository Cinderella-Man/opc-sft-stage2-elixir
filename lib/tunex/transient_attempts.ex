defmodule Tunex.TransientAttempts do
  @moduledoc """
  Persistent per-row `:transient_abort` counter (docs/10 Fix 1).

  Don't-consume means a row whose rule-gen call keeps timing out re-runs every
  pass; this counts how many times each index has transiently aborted across
  runs so the Router can give it up to `too_slow/` once it hits
  `Config.transient_row_limit/0`. Stored as a flat `index => count` JSON map
  under `var/run/` (regenerable; wiped by `tunex.reset`'s `rm_rf`). Best-effort:
  a read/write failure never crashes the loop (it just under-counts).
  """

  require Logger
  alias Tunex.Config

  @doc "Increment the abort count for `index`; return the NEW count."
  def bump(index) do
    map = read()
    key = to_string(index)
    n = Map.get(map, key, 0) + 1
    write(Map.put(map, key, n))
    n
  end

  @doc "Current abort count for `index` (0 if none)."
  def count(index), do: Map.get(read(), to_string(index), 0)

  defp read do
    with {:ok, body} <- File.read(path()),
         {:ok, map} when is_map(map) <- Jason.decode(body) do
      map
    else
      _ -> %{}
    end
  end

  defp write(map) do
    File.mkdir_p!(Path.dirname(path()))
    File.write!(path(), Jason.encode!(map))
  rescue
    e -> Logger.debug("[TransientAttempts] write failed: #{Exception.message(e)}")
  end

  defp path, do: Config.run_path("transient_attempts.json")
end
