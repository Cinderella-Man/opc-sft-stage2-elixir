defmodule Tunex.Orchestrator do
  @moduledoc """
  The single seeded-shuffle forward pass (plan #9, flow per row).

  Boot: preflight (fail fast) → reconciliation → load-or-generate the shuffle
  seed → derive the permutation → resume from the explicit `Progress` file.

  Per row over the permutation: skip + `mark_done` if cache-blacklisted; else
  translate → round-trip → solve (+ validate, folded into Solve) → rule-gen →
  route (delete / escalate / Gate→commit) → append the SFT success/error record
  (synced, based on solve, independent of rule-gen) → `Progress.mark_done`
  **LAST**. A throwing row is logged, the clone discarded, and the row skipped —
  never crashing the loop. Advances until killed or the permutation is
  exhausted.
  """

  use GenServer, restart: :transient
  require Logger

  alias Tunex.{Budget, Config, Dataset, Preflight, Progress, RowLog, Workspace}
  alias Tunex.Pipeline.{RoundTrip, Solve}
  alias Tunex.Evolve.Router

  # ── Lifecycle ───────────────────────────────────────────────────────

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts), do: {:ok, %{opts: opts}, {:continue, :boot}}

  @impl true
  def handle_continue(:boot, %{opts: _opts}) do
    Preflight.run!()

    seed = load_or_create_seed()
    subset = Config.subset()
    {rows, total} = load_dataset(subset)
    permutation = permutation(seed, total)

    progress_path = Config.run_path("progress")
    completed = Progress.load(progress_path)
    pending = Enum.reject(permutation, &MapSet.member?(completed, &1))

    Logger.info(
      "[Orchestrator] seed=#{seed} total=#{total} done=#{MapSet.size(completed)} pending=#{length(pending)}"
    )

    out = open_synced(Config.run_path("elixir_sft_#{subset}.jsonl"))
    err = open_synced(Config.run_path("elixir_sft_#{subset}_errors.jsonl"))
    rowstat = open_synced(Config.run_path("rows.jsonl"))
    :persistent_term.put({Tunex, :sft_out}, out)
    :persistent_term.put({Tunex, :sft_err}, err)

    RowLog.ensure_ready()
    budget = Config.budget()

    state = %{
      pending: pending,
      rows: List.to_tuple(rows),
      total: total,
      workspace: Workspace.default_path(),
      progress_path: progress_path,
      out: out,
      err: err,
      rowstat: rowstat,
      transient_retries: Map.get(budget, :transient_retries, 5),
      transient_backoff_ms: Map.get(budget, :transient_backoff_ms, 2_000),
      transient_storm_limit: Config.transient_storm_limit(),
      consecutive_transient: 0,
      started_mono: System.monotonic_time(:millisecond),
      done: 0
    }

    send(self(), :next)
    {:noreply, state}
  end

  @impl true
  def handle_info(:next, %{pending: []} = state) do
    Logger.info("[Orchestrator] permutation exhausted — exiting cleanly")
    :file.sync(state.out)
    :file.sync(state.err)
    System.halt(0)
    {:stop, :normal, state}
  end

  def handle_info(:next, %{pending: [idx | rest]} = state) do
    outcome = run_row(idx, state)
    state = apply_breaker(state, outcome, idx)
    state = %{state | pending: rest, done: state.done + 1}
    log_progress(state)
    send(self(), :next)
    {:noreply, state}
  end

  # Consecutive-:transient_abort circuit breaker (docs/10 Fix 1): a real Mimo
  # outage halts cleanly instead of churning the pending list. A blacklisted row
  # carries no Mimo signal (left unchanged); any real outcome resets the streak.
  defp apply_breaker(state, outcome, idx) do
    case breaker_step(state.consecutive_transient, state.transient_storm_limit, outcome) do
      :halt ->
        Tunex.shutdown({:transient_storm, idx})
        state

      {:cont, n} ->
        if n > 0, do: Logger.warning("[Orchestrator] transient_abort streak #{n}/#{state.transient_storm_limit}")
        %{state | consecutive_transient: n}
    end
  end

  @doc false
  # Pure breaker decision (exposed for tests): `:halt` at the limit, else the new
  # consecutive count. Blacklist holds; any non-abort real outcome resets to 0.
  def breaker_step(consecutive, limit, outcome) do
    case outcome do
      :transient_abort -> if consecutive + 1 >= limit, do: :halt, else: {:cont, consecutive + 1}
      :blacklist -> {:cont, consecutive}
      _ -> {:cont, 0}
    end
  end

  # Live trajectory line after every row: throughput + projected daily burn.
  defp log_progress(state) do
    hrs = max((System.monotonic_time(:millisecond) - state.started_mono) / 3_600_000, 1.0e-9)
    spent = Budget.spent()
    rate = state.done / hrs

    Logger.info(
      "[progress] session_rows=#{state.done} (#{length(state.pending)} pending) " <>
        "elapsed=#{Float.round(hrs, 2)}h rate=#{Float.round(rate, 1)} rows/hr " <>
        "est=$#{Float.round(spent, 4)} → ~$#{Float.round(spent / hrs * 24, 2)}/day"
    )
  end

  # ── Per-row ─────────────────────────────────────────────────────────

  # Returns the breaker-relevant outcome (`:transient_abort` / `:blacklist` /
  # a real rule-gen outcome / `:exception`) for the consecutive-abort breaker.
  defp run_row(idx, state) do
    do_row(idx, state)
  rescue
    e ->
      Logger.error("[idx=#{idx}] EXCEPTION: #{Exception.format(:error, e, __STACKTRACE__)}")
      discard_clone()
      safe_close_log(idx)
      append_error(state, %{index: idx, failure_reason: "exception: #{Exception.message(e)}"})
      write_row_stat(state, %{index: idx, ts: System.os_time(:second), outcome: :exception})
      Progress.mark_done(state.progress_path, idx)
      :exception
  end

  defp do_row(idx, state) do
    t0 = System.monotonic_time(:millisecond)
    spent0 = Budget.spent()
    Budget.set_row(idx)
    RowLog.open(idx)
    row = build_row(elem(state.rows, idx))
    Logger.info("[idx=#{idx}] entry_point=#{row.entry_point}")

    stat =
      case stage(fn -> RoundTrip.ensure(row, state.workspace) end, state) do
        {:ok, payload, src} ->
          Logger.info("[idx=#{idx}] translation #{src} — solving")
          solve_and_finish(idx, row, payload, src, state)

        {:blacklist, reason} ->
          Logger.info("[idx=#{idx}] blacklisted (#{reason}) — skipping")
          append_error(state, %{index: idx, original_entry_point: row.entry_point, failure_reason: "blacklist:#{reason}"})
          RowLog.close(idx)
          Progress.mark_done(state.progress_path, idx)
          %{translate: :blacklist, blacklist: reason}
      end

    elapsed = Float.round((System.monotonic_time(:millisecond) - t0) / 1000, 1)
    cost_est = Float.round(Budget.spent() - spent0, 6)

    write_row_stat(
      state,
      Map.merge(%{index: idx, ts: System.os_time(:second), elapsed_s: elapsed, cost_est: cost_est}, stat)
    )

    Logger.info("[idx=#{idx}] finished in #{elapsed}s (est $#{cost_est})")
    breaker_outcome(stat)
  end

  # The breaker watches the rule-gen outcome; a blacklisted row never reached
  # Mimo (own signal); anything else is a real outcome (resets the streak).
  defp breaker_outcome(%{rulegen: o}), do: o
  defp breaker_outcome(%{blacklist: _}), do: :blacklist
  defp breaker_outcome(_), do: nil

  defp solve_and_finish(idx, row, payload, src, state) do
    # Distillation boundary (T2.1): the classifier drops everything ABOVE this
    # sentinel (Python / translate / round-trip / reference) and keeps the solve
    # attempts + fix traces below it. Emitted unconditionally on every row,
    # immediately before the solve stage — a dedicated line so the cut decouples
    # from Solve's own log wording (07 §7).
    Logger.info("===SOLVE_BOUNDARY===")

    solve =
      stage(
        fn -> Solve.run(payload.instruction, payload.test, row.entry_point, state.workspace) end,
        state
      )

    record =
      case solve do
        {:ok, sr} ->
          {:success, success_record(idx, row, payload, sr)}

        {:failed, info} ->
          {:error, error_record(idx, row, payload, info)}
      end

    # Rule-gen runs on EVERY row that reached Solve (success or failed); the
    # Router reads the row log and routes its fate (move to an outcome dir /
    # commit) itself. The solve outcome forks the classifier lens (07 §3.3).
    rg = safe_rule_gen(idx, router_outcome(solve))

    if rg_outcome(rg) == :transient_abort do
      # Don't-consume (docs/10 Fix 1): a recoverable rule-gen timeout — skip BOTH
      # the SFT append and mark_done so the row re-runs cleanly next pass (and
      # appends exactly once then). The log already moved to transient/.
      Logger.info("[idx=#{idx}] transient_abort — NOT consuming (re-runs next pass)")
    else
      # SFT append is based on Solve (step 5), independent of rule-gen (step 6).
      case record do
        {:success, r} -> append_success(state, r)
        {:error, r} -> append_error(state, r)
      end

      Progress.mark_done(state.progress_path, idx)
    end

    %{
      translate: src,
      solve: solve_tag(solve),
      solve_attempts: solve_attempts(solve),
      rulegen: rg_outcome(rg),
      decision: rg_decision(rg)
    }
  end

  defp safe_rule_gen(idx, solve_outcome) do
    Router.run(idx, solve_outcome)
  rescue
    e ->
      Logger.error("[idx=#{idx}] router raised: #{Exception.message(e)} — discarding clone")
      discard_clone()
      safe_close_log(idx)
      %{outcome: :raised, decision: nil}
  end

  # The classifier lens forks on solve outcome (07 §3.3): :solved judges the
  # clean final for idiomatic residual; :failed judges the attempts for an
  # unfixed issue.
  defp router_outcome({:ok, _}), do: :solved
  defp router_outcome(_), do: :failed

  defp solve_tag({:ok, _}), do: :ok
  defp solve_tag({:failed, _}), do: :failed
  defp solve_tag(_), do: :unknown

  defp solve_attempts({:ok, sr}), do: sr[:attempts]
  defp solve_attempts({:failed, info}), do: info[:attempts]
  defp solve_attempts(_), do: nil

  defp rg_outcome(%{outcome: o}), do: o
  defp rg_outcome(_), do: nil

  defp rg_decision(%{decision: d}) when not is_nil(d), do: inspect(d)
  defp rg_decision(_), do: nil

  defp write_row_stat(state, map), do: append_synced(state.rowstat, map)

  # ── API-error retry / backoff / shutdown ────────────────────────────

  defp stage(fun, state, attempt \\ 1) do
    case fun.() do
      {:error, reason} ->
        Logger.error("[stage] API error (attempt #{attempt}): #{inspect(reason)}")

        case Budget.classify_error(reason) do
          :fatal ->
            Tunex.shutdown({:fatal_api, reason})

          :transient ->
            if attempt > state.transient_retries do
              Tunex.shutdown({:transient_exhausted, reason})
            else
              Process.sleep(backoff(state, attempt))
              stage(fun, state, attempt + 1)
            end
        end

      other ->
        Budget.note_success()
        other
    end
  end

  defp backoff(state, attempt), do: state.transient_backoff_ms * Integer.pow(2, attempt - 1)

  # ── Records ─────────────────────────────────────────────────────────

  defp build_row(raw) do
    %{
      instruction: raw["instruction"],
      code: raw["code"],
      entry_point: raw["entry_point"],
      tests: raw["testcase"] || []
    }
  end

  defp success_record(idx, row, payload, sr) do
    %{
      index: idx,
      instruction: payload.instruction,
      elixir_code: sr.elixir_code,
      elixir_test: sr.elixir_test,
      entry_point: sr.entry_point,
      original_entry_point: row.entry_point,
      attempts: sr.attempts
    }
  end

  defp error_record(idx, row, payload, info) do
    last = info[:last] || %{}

    %{
      index: idx,
      original_entry_point: row.entry_point,
      entry_point: Tunex.Parser.elixir_name(row.entry_point),
      failure_reason: info.reason,
      attempts: info[:attempts],
      instruction: payload.instruction,
      elixir_code: last[:elixir_code],
      elixir_test: last[:elixir_test]
    }
  end

  defp append_success(state, record), do: append_synced(state.out, record)
  defp append_error(state, record), do: append_synced(state.err, record)

  # ── Boot helpers ────────────────────────────────────────────────────

  defp load_or_create_seed do
    path = Config.run_path("seed")

    if File.exists?(path) do
      path |> File.read!() |> String.trim() |> String.to_integer()
    else
      :rand.seed(:exsss)
      seed = :rand.uniform(1_000_000_000)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, Integer.to_string(seed))
      seed
    end
  end

  defp permutation(seed, n) do
    :rand.seed(:exsss, {seed, seed, seed})
    Enum.shuffle(0..(n - 1))
  end

  defp load_dataset(subset) do
    parquet = Dataset.ensure_downloaded(subset)
    Dataset.load_rows(parquet)
  end

  # ── Low-level ───────────────────────────────────────────────────────

  defp open_synced(path) do
    File.mkdir_p!(Path.dirname(path))
    {:ok, handle} = :file.open(String.to_charlist(path), [:append, :raw, :binary])
    handle
  end

  defp append_synced(handle, map) do
    :ok = :file.write(handle, [Jason.encode!(map), "\n"])
    :file.sync(handle)
  end

  defp discard_clone do
    clone = Config.credence_clone()
    System.cmd("git", ["checkout", "--", "."], cd: clone, stderr_to_stdout: true)
    System.cmd("git", ["clean", "-fd"], cd: clone, stderr_to_stdout: true)
  end

  defp safe_close_log(idx) do
    RowLog.close(idx)
  rescue
    _ -> :ok
  end
end
