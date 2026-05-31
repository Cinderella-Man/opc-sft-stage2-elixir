defmodule Tunex.ClaudeCode do
  @moduledoc """
  Thin subprocess wrapper around the Claude Code CLI, pointed at **Mimo** via
  the Anthropic-compatible endpoint.

  "Claude Code" (the harness) ≠ "Claude" (the model): `ANTHROPIC_MODEL` is Mimo,
  so this does not reintroduce an Anthropic dependency. The agent runs sandboxed
  in the credence clone (`cwd`), may Read/Grep/Glob/Edit/Write and run
  `mix test`, but **cannot run git** (disallowed) and has no git creds.

  Uses `--output-format stream-json` over a **Port** so the agent's steps/tool
  uses are logged **live** (a long session against slow Mimo can run many minutes
  with no other visible output), and a **wall-clock timeout** kills a hung
  session → reported as `gave_up` rather than blocking the loop forever.

  NOTE: the logged `step N` counts streamed assistant messages — it is NOT Claude
  Code's `num_turns` (which `--max-turns` caps). Mimo emits several messages per
  turn, so `step` runs well ahead of the real turn count.

  The prompt is fed via **stdin** (a row's raw log can exceed the 128KB single-
  argument limit), through a temp file + `bash -c "exec claude … < file"`.

  Returns `{:ok, result}` (`:result_text`, `:usage`, `:num_turns`, `:subtype`,
  `:is_error`, `:decision`, `:raw`) or `{:error, reason}`. A timeout or a
  max-turns-without-finish run yields `decision: {:gave_up, …}`.
  """

  require Logger

  alias Tunex.Config

  @allowed_tools ~w(Read Grep Glob Edit Write) ++ ["Bash(mix test:*)"]
  @disallowed_tools ["Bash(git:*)"]

  @doc "Run the agent with `prompt`. `opts`: `:cwd`, `:max_turns`, `:timeout_ms`."
  def run(prompt, opts \\ []) do
    clone = Keyword.get(opts, :cwd, Config.credence_clone())
    max_turns = Keyword.get(opts, :max_turns, Config.cc_max_turns())
    timeout_ms = Keyword.get(opts, :timeout_ms, Config.cc_timeout_ms())

    prompt_file =
      Path.join(System.tmp_dir!(), "tunex_cc_prompt_#{System.unique_integer([:positive])}.txt")

    File.write!(prompt_file, prompt)

    args =
      ["-p", "--output-format", "stream-json", "--verbose", "--add-dir", clone] ++
        ["--allowedTools"] ++ @allowed_tools ++
        ["--disallowedTools"] ++ @disallowed_tools ++
        ["--max-turns", to_string(max_turns)]

    script = "exec claude " <> Enum.map_join(args, " ", &shq/1) <> " < " <> shq(prompt_file)

    Logger.info("[ClaudeCode] running agent (cwd=#{clone}, max_turns=#{max_turns}, timeout=#{div(timeout_ms, 1000)}s)")

    result =
      try do
        run_port(script, clone, timeout_ms, max_turns)
      after
        File.rm(prompt_file)
      end

    result
  end

  # ── Port: spawn, stream, timeout ────────────────────────────────────

  defp run_port(script, clone, timeout_ms, max_turns) do
    bash = System.find_executable("bash") || "/bin/bash"

    port =
      Port.open({:spawn_executable, bash}, [
        :binary,
        :exit_status,
        :hide,
        args: ["-c", script],
        cd: String.to_charlist(clone),
        env: cc_env()
      ])

    deadline = System.monotonic_time(:millisecond) + timeout_ms
    collect(port, %{buffer: "", result: nil, steps: 0}, deadline, max_turns)
  end

  defp collect(port, acc, deadline, max_turns) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      kill(port)
      Logger.warning("[ClaudeCode] TIMEOUT — killing agent (treated as gave_up)")
      {:ok, timeout_result(acc.steps)}
    else
      receive do
        {^port, {:data, chunk}} ->
          acc = handle_chunk(acc, chunk)
          collect(port, acc, deadline, max_turns)

        {^port, {:exit_status, code}} ->
          finalize(acc, code, max_turns)
      after
        remaining ->
          kill(port)
          Logger.warning("[ClaudeCode] TIMEOUT — killing agent (treated as gave_up)")
          {:ok, timeout_result(acc.steps)}
      end
    end
  end

  # Accumulate stdout, split complete NDJSON lines, log progress, capture the
  # final `result` event.
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

  defp handle_event(acc, %{"type" => "result"} = event), do: %{acc | result: event}

  defp handle_event(acc, %{"type" => "assistant", "message" => %{"content" => content}})
       when is_list(content) do
    # `steps` counts streamed assistant MESSAGES (for progress logging only) —
    # this is NOT Claude Code's `num_turns` that `--max-turns` caps (Mimo emits
    # several messages per turn). The authoritative count is in the result event.
    steps = acc.steps + 1
    Enum.each(content, &log_block(&1, steps))
    %{acc | steps: steps}
  end

  defp handle_event(acc, %{"type" => "system", "subtype" => "init"}) do
    Logger.info("[ClaudeCode] agent session started")
    acc
  end

  defp handle_event(acc, _event), do: acc

  # Full, untruncated logging — the whole point is to see exactly what the agent
  # did (including the full rule code it Writes/Edits).
  defp log_block(%{"type" => "tool_use", "name" => name, "input" => input}, step) do
    Logger.info("[ClaudeCode] step #{step}: #{name}\n#{format_tool_input(input)}")
  end

  defp log_block(%{"type" => "text", "text" => text}, step) do
    text = String.trim(text)
    if text != "", do: Logger.info("[ClaudeCode] step #{step} says:\n#{text}")
  end

  defp log_block(_, _), do: :ok

  defp format_tool_input(input) when is_map(input) do
    Enum.map_join(input, "\n", fn {k, v} -> "    #{k}: #{render(v)}" end)
  end

  defp format_tool_input(other), do: inspect(other, limit: :infinity, printable_limit: :infinity)

  defp render(v) when is_binary(v), do: v
  defp render(v), do: inspect(v, limit: :infinity, printable_limit: :infinity)

  # ── Finalize ────────────────────────────────────────────────────────

  defp finalize(%{result: nil} = acc, code, _max_turns) do
    Logger.error("[ClaudeCode] process exited #{code} with no result event")
    {:error, {:no_result, code, acc.steps}}
  end

  defp finalize(%{result: event}, exit_code, max_turns) do
    result_text = event["result"] || ""
    subtype = event["subtype"]
    num_turns = event["num_turns"] || 0
    is_error = event["is_error"] || false

    # Feed CC usage to Budget (ignore CC's total_cost_usd — wrong for Mimo).
    if is_map(event["usage"]),
      do: Tunex.Budget.record(event["usage"], :cc, %{model: Config.cc_model()})

    Logger.info("[ClaudeCode] agent done — subtype=#{subtype} turns=#{num_turns}")

    {:ok,
     %{
       result_text: result_text,
       usage: event["usage"],
       num_turns: num_turns,
       subtype: subtype,
       is_error: is_error,
       exit_code: exit_code,
       decision: parse_decision(result_text, subtype, num_turns >= max_turns),
       raw: event
     }}
  end

  defp timeout_result(steps) do
    %{
      result_text: "",
      usage: nil,
      num_turns: steps,
      subtype: "error_timeout",
      is_error: true,
      exit_code: nil,
      decision: {:gave_up, "timeout"},
      raw: %{"subtype" => "error_timeout"}
    }
  end

  # ── DECISION parsing ────────────────────────────────────────────────

  @doc """
  Parse the agent's three-way `DECISION:` verb.

  Returns `:no_opportunity`, `{:gave_up, detail}`, or `{:rule_proposal, line}`.
  A max-turns-without-finish run, or a missing DECISION line, is `gave_up`.
  """
  def parse_decision(_result_text, subtype, _max_hit) when subtype == "error_max_turns",
    do: {:gave_up, "max turns reached"}

  def parse_decision(_result_text, _subtype, true = _max_hit),
    do: {:gave_up, "max turns reached"}

  def parse_decision(result_text, _subtype, _max_hit) do
    case Regex.run(~r/^\s*DECISION:\s*(.+)$/m, result_text) do
      [_, rest] ->
        rest = String.trim(rest)

        cond do
          String.starts_with?(rest, "no_opportunity") ->
            :no_opportunity

          String.starts_with?(rest, "gave_up") ->
            detail =
              rest |> String.replace_prefix("gave_up", "") |> String.trim_leading(":") |> String.trim()

            {:gave_up, detail}

          true ->
            {:rule_proposal, rest}
        end

      nil ->
        {:gave_up, "no DECISION line"}
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────

  defp cc_env do
    [
      {~c"ANTHROPIC_BASE_URL", String.to_charlist(Config.cc_base_url())},
      {~c"ANTHROPIC_AUTH_TOKEN", String.to_charlist(Config.cc_auth_token())},
      {~c"ANTHROPIC_MODEL", String.to_charlist(Config.cc_model())}
    ]
  end

  defp split_lines(data) do
    parts = String.split(data, "\n")
    {complete, [rest]} = Enum.split(parts, -1)
    {complete, rest}
  end

  defp kill(port) do
    # Close the port (SIGKILLs the spawned bash/claude). `exec` in the script
    # means the port's process IS claude, so this stops the agent directly.
    try do
      info = Port.info(port)
      Port.close(port)
      if info && info[:os_pid], do: System.cmd("kill", ["-9", to_string(info[:os_pid])], stderr_to_stdout: true)
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end
  end

  # Single-quote a shell token.
  defp shq(s), do: "'" <> String.replace(to_string(s), "'", "'\\''") <> "'"
end
