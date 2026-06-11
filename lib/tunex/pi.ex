defmodule Tunex.Pi do
  @moduledoc """
  Subprocess wrapper around the `pi` coding-agent CLI (@earendil-works/
  pi-coding-agent), pointed at **Mimo** via the custom-provider extension
  `pi/mimo_provider.ts` (so this is still the Mimo token plan, not a new dep).

  pi runs an AGENT loop — many small turns (read / edit / write / run `mix test`)
  — so a rule is built across fast turns instead of one huge slow generation that
  blows the chat timeout (docs/10 Fix-1 follow-up). It runs in the credence clone
  (`cwd`) and may read/bash/edit/write; the orchestrator still owns git (the
  agent has no creds, and the clone is reset on any abort).

  Uses `--mode json` over a **Port** so tool-uses are logged live and a
  **wall-clock timeout** kills a hung session. The prompt is fed via **stdin**
  (`exec pi … < file`): a row's prompt can be large, and — critically — the EOF
  is what lets pi exit in `-p` mode (without it pi blocks on stdin forever, which
  was every early hang in testing).

  Returns `{:ok, %{result_text, usage, num_turns, stop_reason, exit_code}}` or
  `{:gave_up, reason}` (timeout / non-zero exit / model error).
  """

  require Logger

  alias Tunex.Config

  @doc "Run the agent on `prompt`. `opts`: `:cwd`, `:timeout_ms`, `:row`."
  def run(prompt, opts \\ []) do
    clone = Keyword.get(opts, :cwd, Config.credence_clone())
    timeout_ms = Keyword.get(opts, :timeout_ms, Config.pi_timeout_ms())
    row = Keyword.get(opts, :row)

    prompt_file =
      Path.join(System.tmp_dir!(), "tunex_pi_prompt_#{System.unique_integer([:positive])}.txt")

    File.write!(prompt_file, prompt)

    pi = System.find_executable("pi") || "pi"

    args =
      ["-p", "--mode", "json", "-e", Config.pi_extension(),
       "--provider", Config.pi_provider(), "--model", Config.pi_model(),
       "--thinking", Config.pi_thinking(), "--no-session", "--no-context-files",
       "-t", Config.pi_tools(), "-a"]

    # exec pi with stdin from the prompt file → feeds the prompt AND the EOF pi
    # needs to exit in -p mode.
    script = "exec " <> shq(pi) <> " " <> Enum.map_join(args, " ", &shq/1) <> " < " <> shq(prompt_file)

    Logger.info(
      "[Pi] running agent (cwd=#{clone}, model=#{Config.pi_model()}, " <>
        "thinking=#{Config.pi_thinking()}, timeout=#{div(timeout_ms, 1000)}s)"
    )

    try do
      run_port(script, clone, timeout_ms, row)
    after
      File.rm(prompt_file)
    end
  end

  # ── Port: spawn, stream, timeout ────────────────────────────────────

  defp run_port(script, clone, timeout_ms, row) do
    bash = System.find_executable("bash") || "/bin/bash"

    port =
      Port.open({:spawn_executable, bash}, [
        :binary,
        :exit_status,
        :hide,
        args: ["-c", script],
        cd: String.to_charlist(clone),
        env: [{~c"TUNEX_MIMO_KEY", String.to_charlist(Config.pi_mimo_key())}]
      ])

    t0 = System.monotonic_time(:millisecond)
    deadline = t0 + timeout_ms

    acc = %{
      buffer: "",
      steps: 0,
      result_text: "",
      usage: zero_usage(),
      stop: nil,
      error: nil,
      row: row,
      t0: t0,
      last_ms: t0
    }

    collect(port, acc, deadline, Config.pi_idle_ms())
  end

  defp zero_usage,
    do: %{
      "input_tokens" => 0,
      "output_tokens" => 0,
      "cache_read_input_tokens" => 0,
      "cache_creation_input_tokens" => 0
    }

  defp collect(port, acc, deadline, idle_ms) do
    now = System.monotonic_time(:millisecond)
    wall_left = deadline - now
    idle_left = acc.last_ms + idle_ms - now

    cond do
      wall_left <= 0 ->
        timeout(port, acc, :wall)

      idle_left <= 0 ->
        timeout(port, acc, :idle)

      true ->
        receive do
          {^port, {:data, chunk}} ->
            acc = handle_chunk(%{acc | last_ms: System.monotonic_time(:millisecond)}, chunk)
            collect(port, acc, deadline, idle_ms)

          {^port, {:exit_status, code}} ->
            finalize(acc, code)
        after
          # wake at whichever cutoff is sooner, then re-evaluate which expired.
          min(wall_left, idle_left) -> collect(port, acc, deadline, idle_ms)
        end
    end
  end

  # :wall = total budget exhausted; :idle = no event for idle_ms (a stalled Mimo
  # stream — caught in minutes instead of burning the whole wall-clock budget).
  defp timeout(port, acc, kind) do
    kill(port)
    reason = if kind == :idle, do: "idle_timeout", else: "timeout"
    Logger.warning("[Pi] #{String.upcase(reason)} — killing agent (treated as gave_up)")
    record_diag(acc, nil, reason)
    {:gave_up, reason}
  end

  # ── Event handling ──────────────────────────────────────────────────

  defp handle_chunk(acc, chunk) do
    {lines, rest} = split_lines(acc.buffer <> chunk)
    acc = %{acc | buffer: rest}

    Enum.reduce(lines, acc, fn line, acc ->
      case Jason.decode(line) do
        {:ok, event} -> handle_event(acc, event)
        {:error, _} -> acc
      end
    end)
  end

  # Live tool-use logging (the agent's read/edit/write/bash steps).
  defp handle_event(acc, %{"type" => "tool_execution_start", "toolName" => name, "args" => args}) do
    steps = acc.steps + 1
    Logger.info("[Pi] step #{steps}: #{name}\n#{format_args(args)}")
    %{acc | steps: steps}
  end

  # Each finished assistant message carries the round-trip `usage` — SUM them
  # (a token-bucket plan debits every turn, not just the last).
  defp handle_event(acc, %{"type" => "message_end", "message" => %{"role" => "assistant"} = m}) do
    text =
      (m["content"] || []) |> List.wrap() |> Enum.map(& &1["text"]) |> Enum.reject(&is_nil/1) |> Enum.join()

    %{
      acc
      | result_text: if(text != "", do: text, else: acc.result_text),
        usage: add_usage(acc.usage, m["usage"]),
        stop: m["stopReason"] || acc.stop,
        error: m["errorMessage"] || acc.error
    }
  end

  defp handle_event(acc, _event), do: acc

  defp add_usage(u, %{} = pu) do
    %{
      u
      | "input_tokens" => u["input_tokens"] + num(pu, "input"),
        "output_tokens" => u["output_tokens"] + num(pu, "output"),
        "cache_read_input_tokens" => u["cache_read_input_tokens"] + num(pu, "cacheRead"),
        "cache_creation_input_tokens" => u["cache_creation_input_tokens"] + num(pu, "cacheWrite")
    }
  end

  defp add_usage(u, _), do: u

  defp num(map, key) do
    case Map.get(map, key) do
      n when is_number(n) -> n
      _ -> 0
    end
  end

  # ── Finalize ────────────────────────────────────────────────────────

  defp finalize(acc, exit_code) do
    # Feed summed usage to Budget (Mimo-pro prices via the :cc bucket).
    if usage_nonzero?(acc.usage),
      do: Tunex.Budget.record(acc.usage, :cc, %{model: Config.pi_model()})

    record_diag(acc, exit_code, acc.stop)

    Logger.info("[Pi] agent done — exit=#{exit_code} steps=#{acc.steps} stop=#{acc.stop}")

    cond do
      exit_code != 0 ->
        {:gave_up, {:exit, exit_code}}

      acc.stop == "error" ->
        {:gave_up, {:model_error, acc.error}}

      true ->
        {:ok,
         %{
           result_text: acc.result_text,
           usage: acc.usage,
           num_turns: acc.steps,
           stop_reason: acc.stop,
           exit_code: exit_code
         }}
    end
  end

  defp usage_nonzero?(u), do: Enum.any?(Map.values(u), &(&1 > 0))

  defp record_diag(acc, exit_code, stop) do
    Tunex.Diag.record(%{
      kind: "pi_session",
      row: acc.row,
      exit_code: exit_code,
      num_turns: acc.steps,
      stop: stop,
      error: acc.error,
      wall_ms: System.monotonic_time(:millisecond) - acc.t0,
      usage: acc.usage
    })
  end

  # ── Helpers ─────────────────────────────────────────────────────────

  defp format_args(args) when is_map(args) do
    Enum.map_join(args, "\n", fn {k, v} -> "    #{k}: #{render(v)}" end)
  end

  defp format_args(other), do: inspect(other, limit: :infinity, printable_limit: :infinity)

  defp render(v) when is_binary(v), do: v
  defp render(v), do: inspect(v, limit: :infinity, printable_limit: :infinity)

  defp split_lines(data) do
    parts = String.split(data, "\n")
    {complete, [rest]} = Enum.split(parts, -1)
    {complete, rest}
  end

  defp kill(port) do
    info = Port.info(port)
    Port.close(port)
    if info && info[:os_pid], do: System.cmd("kill", ["-9", to_string(info[:os_pid])], stderr_to_stdout: true)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp shq(s), do: "'" <> String.replace(to_string(s), "'", "'\\''") <> "'"
end
