defmodule Tunex.ClaudeCode do
  @moduledoc """
  Thin subprocess wrapper around the Claude Code CLI, pointed at **Mimo** via
  the Anthropic-compatible endpoint.

  "Claude Code" (the harness) ≠ "Claude" (the model): `ANTHROPIC_MODEL` is Mimo,
  so this does not reintroduce an Anthropic dependency. The agent runs sandboxed
  in the credence clone (`cwd`), may Read/Grep/Glob/Edit/Write and run
  `mix test`, but **cannot run git** (disallowed) and has no git creds.

  The prompt is fed via **stdin** (a row's raw log can exceed the 128KB single-
  argument limit), through a temp file + `bash -c "claude … < file"` so each
  variadic tool arg is shell-escaped exactly once.

  Returns `{:ok, result}` where result has `:result_text`, `:usage`,
  `:num_turns`, `:subtype`, `:is_error`, `:decision`, and `:raw`; or
  `{:error, reason}`. `:decision` is the parsed three-way verb (see
  `parse_decision/3`); a max-turns-without-finish run is reported as
  `{:gave_up, "max turns reached"}`.
  """

  require Logger

  alias Tunex.Config

  @allowed_tools ~w(Read Grep Glob Edit Write) ++ ["Bash(mix test:*)"]
  @disallowed_tools ["Bash(git:*)"]

  @doc "Run the agent with `prompt`. `opts`: `:cwd`, `:max_turns`."
  def run(prompt, opts \\ []) do
    clone = Keyword.get(opts, :cwd, Config.credence_clone())
    max_turns = Keyword.get(opts, :max_turns, Config.cc_max_turns())

    prompt_file =
      Path.join(System.tmp_dir!(), "tunex_cc_prompt_#{System.unique_integer([:positive])}.txt")

    File.write!(prompt_file, prompt)

    args =
      ["-p", "--output-format", "json", "--add-dir", clone] ++
        ["--allowedTools"] ++ @allowed_tools ++
        ["--disallowedTools"] ++ @disallowed_tools ++
        ["--max-turns", to_string(max_turns)]

    script = "claude " <> Enum.map_join(args, " ", &shq/1) <> " < " <> shq(prompt_file)

    env = [
      {"ANTHROPIC_BASE_URL", Config.cc_base_url()},
      {"ANTHROPIC_AUTH_TOKEN", Config.cc_auth_token()},
      {"ANTHROPIC_MODEL", Config.cc_model()}
    ]

    Logger.info("[ClaudeCode] running agent (cwd=#{clone}, max_turns=#{max_turns})")

    result =
      try do
        {out, code} = System.cmd("bash", ["-c", script], cd: clone, env: env)
        parse(out, code, max_turns)
      after
        File.rm(prompt_file)
      end

    result
  end

  # ── Parsing ─────────────────────────────────────────────────────────

  defp parse(out, exit_code, max_turns) do
    case Jason.decode(out) do
      {:ok, json} ->
        result_text = json["result"] || ""
        subtype = json["subtype"]
        num_turns = json["num_turns"] || 0
        is_error = json["is_error"] || false

        # Feed CC usage to Budget (ignore CC's total_cost_usd — wrong for Mimo).
        if is_map(json["usage"]), do: Tunex.Budget.record(json["usage"], :cc)

        {:ok,
         %{
           result_text: result_text,
           usage: json["usage"],
           num_turns: num_turns,
           subtype: subtype,
           is_error: is_error,
           exit_code: exit_code,
           decision: parse_decision(result_text, subtype, num_turns >= max_turns),
           raw: json
         }}

      {:error, reason} ->
        Logger.error("[ClaudeCode] non-JSON output (exit #{exit_code}): #{String.slice(out, 0, 400)}")
        {:error, {:bad_json, reason, out}}
    end
  end

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
            detail = rest |> String.replace_prefix("gave_up", "") |> String.trim_leading(":") |> String.trim()
            {:gave_up, detail}

          true ->
            {:rule_proposal, rest}
        end

      nil ->
        {:gave_up, "no DECISION line"}
    end
  end

  # Single-quote a shell token.
  defp shq(s), do: "'" <> String.replace(to_string(s), "'", "'\\''") <> "'"
end
