defmodule Tunex.Cache do
  @moduledoc """
  Durable translation cache (survives `mix tunex.reset`).

  Backed by `var/cache/translations.jsonl`, one record per row keyed by
  `sha256(system_prompt + rendered_user_prompt + model)` — so any prompt change
  auto-invalidates. Loaded into an in-memory map on boot; `put/2` appends to the
  jsonl and updates the map.

  Each record carries a `verdict` (`:ok | :blacklist`) and, when blacklisted, a
  `reason` (`:roundtrip_fail | :untranslatable`). A `:blacklist` record may be
  payload-less (the untranslatable/truncation negative-cache entry). There is no
  separate blacklist file — a row is blacklisted iff its record has
  `verdict: :blacklist`.

  Started as a GenServer (added to the supervision tree in M5).
  """

  use GenServer
  require Logger

  alias Tunex.Config

  @name __MODULE__

  # ── Public API ──────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, @name))
  end

  @doc "Cache key = sha256(system + rendered user prompt + model)."
  def key(system_prompt, rendered_user_prompt, model) do
    :crypto.hash(:sha256, [system_prompt, "\n", rendered_user_prompt, "\n", model])
    |> Base.encode16(case: :lower)
  end

  @doc "Fetch a record by key, or `nil`. Record fields are atom-keyed."
  def get(key, server \\ @name), do: GenServer.call(server, {:get, key})

  @doc """
  Persist a record. `fields` must include `:verdict` (`:ok | :blacklist`) and may
  include `:reason` and the payload (`:instruction`, `:test`, `:reference`).
  Called exactly once per row, by RoundTrip, after the verdict resolves.
  """
  def put(key, fields, server \\ @name), do: GenServer.call(server, {:put, key, fields})

  @doc "True if a fetched record is a blacklist entry."
  def blacklisted?(nil), do: false
  def blacklisted?(%{verdict: :blacklist}), do: true
  def blacklisted?(%{verdict: _}), do: false

  # ── GenServer ───────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :path, Config.cache_path("translations.jsonl"))
    File.mkdir_p!(Path.dirname(path))
    map = load(path)
    Logger.info("[Cache] loaded #{map_size(map)} record(s) from #{path}")
    {:ok, %{path: path, map: map}}
  end

  @impl true
  def handle_call({:get, key}, _from, state) do
    {:reply, Map.get(state.map, key), state}
  end

  @impl true
  def handle_call({:put, key, fields}, _from, state) do
    record = normalize(Map.put(fields, :key, key))
    line = Jason.encode!(encode(record)) <> "\n"
    File.write!(state.path, line, [:append, :utf8])
    {:reply, :ok, %{state | map: Map.put(state.map, key, record)}}
  end

  # ── Internal ────────────────────────────────────────────────────────

  defp load(path) do
    if File.exists?(path) do
      path
      |> File.stream!()
      |> Stream.map(&String.trim/1)
      |> Stream.reject(&(&1 == ""))
      |> Stream.map(&Jason.decode!/1)
      |> Stream.map(&normalize/1)
      |> Map.new(fn r -> {r.key, r} end)
    else
      %{}
    end
  end

  # Accept either string-keyed (from jsonl) or atom-keyed (from put) maps and
  # produce a canonical atom-keyed record.
  defp normalize(m) do
    %{
      key: fetch(m, :key),
      verdict: to_verdict(fetch(m, :verdict)),
      reason: to_reason(fetch(m, :reason)),
      instruction: fetch(m, :instruction),
      test: fetch(m, :test),
      reference: fetch(m, :reference)
    }
  end

  defp fetch(m, k), do: Map.get(m, k) || Map.get(m, to_string(k))

  defp to_verdict(:ok), do: :ok
  defp to_verdict(:blacklist), do: :blacklist
  defp to_verdict("ok"), do: :ok
  defp to_verdict("blacklist"), do: :blacklist

  defp to_reason(nil), do: nil
  defp to_reason(r) when is_atom(r), do: r
  defp to_reason("roundtrip_fail"), do: :roundtrip_fail
  defp to_reason("untranslatable"), do: :untranslatable
  defp to_reason(_), do: nil

  defp encode(record) do
    %{
      "key" => record.key,
      "verdict" => to_string(record.verdict),
      "reason" => record.reason && to_string(record.reason),
      "instruction" => record.instruction,
      "test" => record.test,
      "reference" => record.reference
    }
  end
end
