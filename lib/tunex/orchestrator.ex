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
  alias Tunex.Evolve.CredenceRuleGenerator

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
    run_row(idx, state)
    state = %{state | pending: rest, done: state.done + 1}
    log_progress(state)
    send(self(), :next)
    {:noreply, state}
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
  end

  defp solve_and_finish(idx, row, payload, src, state) do
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

    # Rule-gen runs on EVERY row that reached Solve (success or failed); it reads
    # the row log and routes its fate (delete / escalate / commit) itself.
    rg = safe_rule_gen(idx)

    # SFT append is based on Solve (step 5), independent of rule-gen (step 6).
    case record do
      {:success, r} -> append_success(state, r)
      {:error, r} -> append_error(state, r)
    end

    Progress.mark_done(state.progress_path, idx)

    %{
      translate: src,
      solve: solve_tag(solve),
      solve_attempts: solve_attempts(solve),
      rulegen: rg_outcome(rg),
      decision: rg_decision(rg)
    }
  end

  defp safe_rule_gen(idx) do
    CredenceRuleGenerator.run(idx)
  rescue
    e ->
      Logger.error("[idx=#{idx}] rule-gen raised: #{Exception.message(e)} — discarding clone")
      discard_clone()
      safe_close_log(idx)
      %{outcome: :raised, decision: nil}
  end

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
