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

  # ── Public API ──────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, @name))
  end

  @doc "Record token usage. `kind` is `:chat` (Mimo) or `:cc` (Claude Code)."
  def record(usage, kind, server \\ @name), do: GenServer.cast(server, {:record, usage, kind})

  @doc "Cumulative spend in USD."
  def spent(server \\ @name), do: GenServer.call(server, :spent)

  @doc """
  Classify an API error tuple as `:fatal | :transient`. Stateful: tracks the
  consecutive-429 streak.
  """
  def classify_error(error, server \\ @name), do: GenServer.call(server, {:classify, error})

  @doc "Reset the consecutive-429 streak (call after any successful request)."
  def note_success(server \\ @name), do: GenServer.cast(server, :note_success)

  # ── GenServer ───────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    budget = Config.budget()

    state = %{
      spent_usd: 0.0,
      sessions_without_usage: 0,
      consecutive_429: 0,
      ceiling: Map.get(budget, :runaway_ceiling_usd, 500.0),
      max_429: Map.get(budget, :max_consecutive_429, @default_max_consecutive_429),
      price_in: Map.get(budget, :price_in_per_token, 1.0 / 1_000_000),
      price_out: Map.get(budget, :price_out_per_token, 3.0 / 1_000_000),
      price_cache_read: Map.get(budget, :price_cache_read_per_token, 0.3 / 1_000_000),
      on_runaway: Keyword.get(opts, :on_runaway, &Tunex.shutdown/1)
    }

    {:ok, state}
  end

  @impl true
  def handle_cast({:record, usage, kind}, state) do
    state =
      case cost(usage, kind, state) do
        nil ->
          %{state | sessions_without_usage: state.sessions_without_usage + 1}

        c ->
          %{state | spent_usd: state.spent_usd + c}
      end

    Logger.debug("[Budget] spent so far: $#{Float.round(state.spent_usd, 4)}")

    if state.spent_usd > state.ceiling do
      Logger.error("[Budget] RUNAWAY: $#{Float.round(state.spent_usd, 2)} > ceiling $#{state.ceiling}")
      state.on_runaway.({:runaway_budget, state.spent_usd})
    end

    {:noreply, state}
  end

  def handle_cast(:note_success, state), do: {:noreply, %{state | consecutive_429: 0}}

  @impl true
  def handle_call(:spent, _from, state), do: {:reply, state.spent_usd, state}

  def handle_call({:classify, error}, _from, state) do
    {verdict, state} = do_classify(error, state)
    {:reply, verdict, state}
  end

  # ── Cost ────────────────────────────────────────────────────────────

  # Mimo chat usage: prompt_tokens / completion_tokens.
  defp cost(%{} = usage, :chat, state) do
    p = num(usage, "prompt_tokens")
    c = num(usage, "completion_tokens")
    if p == 0 and c == 0, do: nil, else: p * state.price_in + c * state.price_out
  end

  # Claude Code usage: input_tokens / output_tokens + cache fields.
  defp cost(%{} = usage, :cc, state) do
    input = num(usage, "input_tokens")
    output = num(usage, "output_tokens")
    cache_create = num(usage, "cache_creation_input_tokens")
    cache_read = num(usage, "cache_read_input_tokens")

    if input == 0 and output == 0 and cache_create == 0 and cache_read == 0 do
      nil
    else
      input * state.price_in + output * state.price_out +
        cache_create * state.price_in + cache_read * state.price_cache_read
    end
  end

  defp cost(_nil_or_other, _kind, _state), do: nil

  defp num(map, key) do
    case Map.get(map, key) do
      n when is_number(n) -> n
      _ -> 0
    end
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
