defmodule Tunex.Budget do
  @moduledoc """
  Tracks Mimo spend (the only paid dependency) and classifies API errors.

  Spend is accumulated from `usage` on every Translate response **and** from the
  Claude Code JSON output (`input_tokens`/`output_tokens` + cache fields). CC's
  `total_cost_usd` is **ignored** (it uses Anthropic pricing, wrong for a custom
  Mimo model). When `usage` is absent we fall back to a session count.

  Runs **essentially uncapped** with a **runaway-safety ceiling** only — when
  cumulative spend crosses `runaway_ceiling_usd` it triggers a graceful
  `Tunex.shutdown/1` (never a raise, so the supervisor can't restart into a
  fatal storm).

  Error classification (plan #12/T5.1): `401/402/403` → `:fatal`; `429` →
  `:fatal` after N consecutive, else `:transient`; `5xx`/network → `:transient`.
  The orchestrator retries `:transient` with backoff and halts on `:fatal`.
  """

  use GenServer
  require Logger

  alias Tunex.Config

  @name __MODULE__
  @default_max_consecutive_429 5
  @default_price %{in: 0.435 / 1_000_000, cache_read: 0.0036 / 1_000_000, out: 0.87 / 1_000_000}

  # ── Public API ──────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, @name))
  end

  @doc """
  Record token usage. `kind` is `:chat` (Mimo) or `:cc` (Claude Code). `meta`
  may carry `:provider` (a stage provider atom, e.g. `:xiaomi_mimo_2_5_pro`)
  and `:model`, used for per-provider pricing + the per-call usage ledger.
  """
  def record(usage, kind, meta \\ %{}, server \\ @name),
    do: GenServer.cast(server, {:record, usage, kind, meta})

  @doc "Tag subsequent `record/4` calls with the current row index (for the ledger)."
  def set_row(index, server \\ @name), do: GenServer.cast(server, {:set_row, index})

  @doc "Cumulative spend in USD."
  def spent(server \\ @name), do: GenServer.call(server, :spent)

  @doc """
  Classify an API error tuple as `:fatal | :transient`. Stateful: tracks the
  consecutive-429 streak.
  """
  def classify_error(error, server \\ @name), do: GenServer.call(server, {:classify, error})

  @doc "Reset the consecutive-429 streak (call after any successful request)."
  def note_success(server \\ @name), do: GenServer.cast(server, :note_success)

  @doc "Live snapshot: spent, token totals by category, record count, elapsed."
  def stats(server \\ @name), do: GenServer.call(server, :stats)

  @heartbeat_ms 300_000

  # ── GenServer ───────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    budget = Config.budget()

    if Keyword.get(opts, :heartbeat, true), do: :timer.send_interval(@heartbeat_ms, self(), :heartbeat)

    state = %{
      spent_usd: 0.0,
      sessions_without_usage: 0,
      consecutive_429: 0,
      current_row: nil,
      records: 0,
      tokens: %{in: 0, cache_read: 0, cache_create: 0, out: 0},
      started_mono: nil,
      ceiling: Map.get(budget, :runaway_ceiling_usd, 500.0),
      max_429: Map.get(budget, :max_consecutive_429, @default_max_consecutive_429),
      prices: Map.get(budget, :prices, %{}),
      default_price: Map.get(budget, :default_price, @default_price),
      usage_log: Config.run_path("usage.jsonl"),
      heartbeat_log: Config.run_path("heartbeat.jsonl"),
      on_runaway: Keyword.get(opts, :on_runaway, &Tunex.shutdown/1)
    }

    {:ok, state}
  end

  @impl true
  def handle_cast({:set_row, index}, state), do: {:noreply, %{state | current_row: index}}

  def handle_cast({:record, usage, kind, meta}, state) do
    breakdown = breakdown(usage, kind)
    provider = pricing_provider(kind, meta)
    c = cost(breakdown, price_for(state, provider))

    log_call(state, kind, provider, meta, breakdown, c)

    state = %{state | started_mono: state.started_mono || System.monotonic_time(:millisecond)}

    state =
      if breakdown == nil or c == nil do
        %{state | sessions_without_usage: state.sessions_without_usage + 1}
      else
        %{
          state
          | spent_usd: state.spent_usd + c,
            records: state.records + 1,
            tokens: accumulate(state.tokens, breakdown)
        }
      end

    Logger.debug("[Budget] spent so far (est.): $#{Float.round(state.spent_usd, 4)}")

    if state.spent_usd > state.ceiling do
      Logger.error("[Budget] RUNAWAY: $#{Float.round(state.spent_usd, 2)} > ceiling $#{state.ceiling}")
      state.on_runaway.({:runaway_budget, state.spent_usd})
    end

    {:noreply, state}
  end

  def handle_cast(:note_success, state), do: {:noreply, %{state | consecutive_429: 0}}

  @impl true
  def handle_call(:spent, _from, state), do: {:reply, state.spent_usd, state}

  def handle_call(:stats, _from, state), do: {:reply, snapshot(state), state}

  def handle_call({:classify, error}, _from, state) do
    {verdict, state} = do_classify(error, state)
    {:reply, verdict, state}
  end

  @impl true
  def handle_info(:heartbeat, state) do
    if state.records > 0 do
      s = snapshot(state)

      Logger.info(
        "[Budget] HEARTBEAT — #{s.records} paid calls, est $#{Float.round(s.spent_usd, 4)} over " <>
          "#{s.elapsed_min}min → ~$#{Float.round(s.usd_per_hr, 4)}/hr, ~$#{Float.round(s.usd_per_day, 2)}/day " <>
          "(tok in=#{s.tokens.in} cache_rd=#{s.tokens.cache_read} out=#{s.tokens.out})"
      )

      append_jsonl(state.heartbeat_log, Map.put(s, :ts, System.os_time(:second)))
    end

    {:noreply, state}
  end

  defp snapshot(state) do
    elapsed_ms =
      case state.started_mono do
        nil -> 0
        t -> System.monotonic_time(:millisecond) - t
      end

    hrs = max(elapsed_ms / 3_600_000, 1.0e-9)

    %{
      spent_usd: state.spent_usd,
      records: state.records,
      tokens: state.tokens,
      sessions_without_usage: state.sessions_without_usage,
      elapsed_min: Float.round(elapsed_ms / 60_000, 1),
      usd_per_hr: state.spent_usd / hrs,
      usd_per_day: state.spent_usd / hrs * 24
    }
  end

  defp accumulate(t, b) do
    %{
      in: t.in + b.in,
      cache_read: t.cache_read + b.cache_read,
      cache_create: t.cache_create + b.cache_create,
      out: t.out + b.out
    }
  end

  defp append_jsonl(path, map) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, [Jason.encode!(map), "\n"], [:append])
  rescue
    e -> Logger.debug("[Budget] jsonl write failed: #{Exception.message(e)}")
  end

  # ── Cost ────────────────────────────────────────────────────────────

  # Normalize raw usage into `%{in, cache_read, cache_create, out}` token
  # counts (the exact ground truth), independent of provider/price. Returns
  # nil when there's nothing to record.
  #
  # Mimo chat: prompt_tokens / completion_tokens (no separate cache fields).
  defp breakdown(%{} = usage, :chat) do
    nz(%{
      in: num(usage, "prompt_tokens"),
      cache_read: 0,
      cache_create: 0,
      out: num(usage, "completion_tokens")
    })
  end

  # Claude Code: input_tokens / output_tokens + cache_{read,creation}_input_tokens.
  defp breakdown(%{} = usage, :cc) do
    nz(%{
      in: num(usage, "input_tokens"),
      cache_read: num(usage, "cache_read_input_tokens"),
      cache_create: num(usage, "cache_creation_input_tokens"),
      out: num(usage, "output_tokens")
    })
  end

  defp breakdown(_other, _kind), do: nil

  defp nz(%{in: i, cache_read: r, cache_create: cc, out: o} = b) do
    if i == 0 and r == 0 and cc == 0 and o == 0, do: nil, else: b
  end

  # cache_create is billed as fresh input (MiMo cache-write currently free, but
  # price it as input to stay conservative if that changes).
  defp cost(nil, _price), do: nil

  defp cost(%{in: i, cache_read: r, cache_create: cc, out: o}, price) do
    (i + cc) * price.in + r * price.cache_read + o * price.out
  end

  # Pricing key: chat uses the stage provider from meta; cc uses the :cc bucket.
  defp pricing_provider(:cc, _meta), do: :cc
  defp pricing_provider(:chat, meta), do: Map.get(meta, :provider)

  defp price_for(state, provider) do
    Map.get(state.prices, provider, state.default_price)
  end

  defp num(map, key) do
    case Map.get(map, key) do
      n when is_number(n) -> n
      _ -> 0
    end
  end

  # Sum Claude Code's `modelUsage` (per-model, camelCase) into the same
  # `%{in, cache_read, cache_create, out}` shape as `breakdown/2`. nil when
  # absent (chat calls, or a CC result without modelUsage).
  defp model_usage_totals(mu) when is_map(mu) and map_size(mu) > 0 do
    Enum.reduce(mu, %{in: 0, cache_read: 0, cache_create: 0, out: 0}, fn {_model, m}, acc ->
      %{
        in: acc.in + num(m, "inputTokens"),
        cache_read: acc.cache_read + num(m, "cacheReadInputTokens"),
        cache_create: acc.cache_create + num(m, "cacheCreationInputTokens"),
        out: acc.out + num(m, "outputTokens")
      }
    end)
  end

  defp model_usage_totals(_), do: nil

  # ── Per-call usage ledger (var/run/usage.jsonl) ─────────────────────
  # One line per Mimo/CC call: raw token counts (exact) + derived cost +
  # row/provider/model tags. Best-effort — a write failure never crashes the
  # loop (e.g. in tests with no run dir).
  defp log_call(_state, _kind, _provider, _meta, nil, _cost), do: :ok

  defp log_call(state, kind, provider, meta, breakdown, cost) do
    line =
      Jason.encode!(%{
        ts: System.os_time(:second),
        row: state.current_row,
        kind: kind,
        provider: provider,
        model: Map.get(meta, :model),
        in: breakdown.in,
        cache_read: breakdown.cache_read,
        cache_create: breakdown.cache_create,
        out: breakdown.out,
        cost_usd: cost && Float.round(cost, 6),
        # Claude Code's per-model cumulative (camelCase), normalized + summed.
        # nil for chat calls (no modelUsage). A cross-check on `usage` above.
        model_usage: model_usage_totals(Map.get(meta, :model_usage))
      })

    File.mkdir_p!(Path.dirname(state.usage_log))
    File.write!(state.usage_log, [line, "\n"], [:append])
  rescue
    e -> Logger.debug("[Budget] usage-log write failed: #{Exception.message(e)}")
  end

  # ── Classification ──────────────────────────────────────────────────

  defp do_classify({:http, status, _body}, state) when status in [401, 402, 403] do
    {:fatal, state}
  end

  defp do_classify({:http, 429, _body}, state) do
    streak = state.consecutive_429 + 1
    state = %{state | consecutive_429: streak}
    if streak >= state.max_429, do: {:fatal, state}, else: {:transient, state}
  end

  defp do_classify({:http, status, _body}, state) when status >= 500 do
    {:transient, state}
  end

  defp do_classify({:network, _reason}, state), do: {:transient, state}
  defp do_classify({:http, _status, _body}, state), do: {:fatal, state}
  defp do_classify(_other, state), do: {:transient, state}
end
