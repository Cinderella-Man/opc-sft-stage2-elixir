defmodule Tunex.Diag do
  @moduledoc """
  Raw, verbatim diagnostics sink (`var/run/diag.jsonl`) — one line per API
  interaction, capturing EVERYTHING the Mimo chat + Claude Code endpoints return
  about token usage, **before** any normalization/aggregation.

  This exists because we cannot yet trust the normalized ledger (`usage.jsonl`)
  against the MiMo console token-bucket: we don't know which fields the bucket
  actually debits (reasoning tokens? cache_read? per-request floor?), and the
  usage signal might also live in response HEADERS, not the body. So we hoard the
  full payloads and reconcile later (see docs/04 + `mix tunex.diag`).

  Best-effort: a write failure never crashes the loop.
  """

  require Logger

  @doc "Append one verbatim diagnostics record (a map) to var/run/diag.jsonl."
  def record(map) when is_map(map) do
    path = Tunex.Config.run_path("diag.jsonl")
    line = Jason.encode!(Map.put_new(map, :ts, System.os_time(:second)), pretty: false)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, [line, "\n"], [:append])
  rescue
    e ->
      # Some payloads (e.g. odd header encodings) may not encode — degrade to a
      # sanitized record rather than losing the line entirely.
      try do
        path = Tunex.Config.run_path("diag.jsonl")
        File.write!(path, [Jason.encode!(%{ts: System.os_time(:second), encode_error: Exception.message(e), keys: Map.keys(map)}), "\n"], [:append])
      rescue
        _ -> :ok
      end
  end

  def record(_), do: :ok

  @doc """
  Normalize Req response headers (map of `key => [values]`, or a keyword list on
  older Req) into a plain JSON-friendly `%{key => value}` map.
  """
  def headers_to_map(headers) when is_map(headers) do
    Map.new(headers, fn {k, v} -> {to_string(k), header_val(v)} end)
  end

  def headers_to_map(headers) when is_list(headers) do
    Map.new(headers, fn {k, v} -> {to_string(k), header_val(v)} end)
  end

  def headers_to_map(_), do: %{}

  defp header_val([v | _]), do: to_string(v)
  defp header_val(v), do: to_string(v)
end
