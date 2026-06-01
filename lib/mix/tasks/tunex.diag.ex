defmodule Mix.Tasks.Tunex.Diag do
  @shortdoc "Run ONE rule-gen session to measure the ledger-vs-console token undercount"
  @moduledoc """
  Console-delta diagnostic (see docs/04). Runs a single, representative
  Claude-Code rule-gen session against the Credence clone and prints, for that
  one session:

    * `num_turns` (Claude Code's own turn count) and round-trips with usage,
    * the **result-event** total tokens — what `Tunex.Budget` currently records,
    * the **summed per-round-trip** total tokens — closer to what a TOKEN-BUCKET
      plan actually debits (each turn re-sends the whole growing prefix).

  Procedure:

      1. Note your MiMo console token balance.       # BEFORE
      2. mix tunex.diag                               # one session
      3. Note your MiMo console token balance again.  # AFTER
      4. Compare (BEFORE - AFTER) to the two printed numbers.

  Interpretation:
    * console-delta ≈ summed-per-round-trip  → the burn is RE-SENDS; lever #1 is
      `max_turns` (slash 80 → ~12) + a token-count circuit breaker.
    * console-delta ≈ result-event           → the ledger is fine; the burn is
      something else (throughput / per-turn context size).
    * summed/result ratio ≈ your turn count  → confirms the undercount mechanism.

  Pass a custom non-idiomatic snippet file as the first arg; otherwise a built-in
  representative snippet is used.
  """
  use Mix.Task

  alias Tunex.{Config, Evolve.CredenceRuleGenerator}

  @sample_snippet ~S"""
  defmodule Stats do
    def sum_all([a, b, c, d]), do: a + b + c + d

    def evens(list) do
      Enum.filter(list, fn x -> rem(x, 2) == 0 end)
      |> Enum.map(fn x -> x * 2 end)
    end

    def total(list) do
      Enum.reduce(list, 0, fn x, acc -> acc + x end)
    end
  end
  """

  @impl true
  def run(["--report" | _]) do
    Mix.Task.run("app.start")
    report_diag(Config.run_path("diag.jsonl"))
  end

  def run(args) do
    Mix.Task.run("app.start")

    snippet =
      case args do
        [path | _] -> File.read!(path)
        _ -> @sample_snippet
      end

    clone = Config.credence_clone()
    prompt = CredenceRuleGenerator.build_prompt(row_log(snippet), "none", CredenceRuleGenerator.rule_index(clone))

    Mix.shell().info("""
    === tunex.diag — single rule-gen session ===
    clone:     #{clone}
    max_turns: #{Config.cc_max_turns()}   (this is what we suspect is the burn)
    diag log:  #{Config.run_path("diag.jsonl")}

    >>> NOTE YOUR MIMO CONSOLE TOKEN BALANCE NOW, then wait for the session. <<<
    """)

    chat_header_probe()

    before = console_used()

    case Tunex.ClaudeCode.run(prompt, cwd: clone, row: -1) do
      {:ok, r} ->
        report(r, before, console_used())

      {:error, reason} ->
        Mix.shell().error("session error: #{inspect(reason)}")
    end
  end

  # Read the authoritative console `used` counter (nil if no cookie configured).
  defp console_used do
    case Tunex.MimoConsole.usage() do
      {:ok, u} -> u.used
      _ -> nil
    end
  end

  # One cheap chat call to surface what the Mimo chat endpoint returns: the full
  # usage object (reasoning/cached token details) AND every response header — a
  # per-request quota/rate-limit gauge, if one exists, lives here.
  defp chat_header_probe do
    Mix.shell().info("--- chat header/usage probe (translate provider) ---")

    case Tunex.LLM.for_stage(:translate, "reply with exactly: OK", "", max_tokens: 16) do
      {tag, _content, usage} when tag in [:ok, :truncated] ->
        Mix.shell().info("chat usage object: #{inspect(usage)}")
        Mix.shell().info("(full headers written to diag.jsonl — look for any 'ratelimit'/'quota'/'token' key)")

      other ->
        Mix.shell().info("chat probe returned: #{inspect(other)}")
    end
  end

  defp report(r, before_used, after_used) do
    tot = fn u ->
      (num(u, "input_tokens") + num(u, "output_tokens") +
         num(u, "cache_read_input_tokens") + num(u, "cache_creation_input_tokens"))
    end

    result_total = if is_map(r.usage), do: tot.(r.usage), else: 0
    summed_total = tot.(r.summed_usage)
    ratio = if result_total > 0, do: Float.round(summed_total / result_total, 1), else: 0.0

    Mix.shell().info("""

    === RESULT ===
    decision:               #{inspect(r.decision)}
    num_turns:              #{r.num_turns}
    round-trips w/ usage:   #{r.roundtrips}

    result-event tokens     (what Budget records today): #{result_total}
      #{inspect(r.usage)}
    summed round-trip tokens (token-bucket basis):       #{summed_total}
      #{inspect(r.summed_usage)}
    summed / result ratio:  #{ratio}x
    """)

    console_recon(before_used, after_used, result_total, summed_total)
  end

  # The whole point: compare the REAL console debit for this one session against
  # the in-band figures. Whichever the console matches is the one to trust.
  defp console_recon(before_used, after_used, result_total, summed_total) do
    if is_integer(before_used) and is_integer(after_used) do
      delta = after_used - before_used

      Mix.shell().info("""
      === CONSOLE RECONCILIATION (automatic) ===
      console used before: #{before_used}
      console used after:  #{after_used}
      Δ console (REAL debit this session): #{delta} tokens
        vs result-event tokens: #{ratio_str(delta, result_total)}
        vs summed round-trip:   #{ratio_str(delta, summed_total)}
      => the in-band figure CLOSEST to Δ console is the one to trust for the breaker.
         If Δ console ≫ both, MiMo bills more than it reports (Credits ≠ reported tokens)
         and only this console poll can meter spend.
      """)
    else
      Mix.shell().info("""
      (no console cookie configured → set TUNEX_MIMO_COOKIE or secrets.mimo_console_cookie
       to auto-reconcile; otherwise read your console balance manually before/after.)
      """)
    end
  end

  defp ratio_str(_delta, 0), do: "n/a (in-band was 0)"
  defp ratio_str(delta, base), do: "#{Float.round(delta / base, 1)}x"

  # ── Report over a populated diag.jsonl ──────────────────────────────

  defp report_diag(path) do
    unless File.exists?(path) do
      Mix.shell().info("no diag log at #{path} — run `mix tunex.diag` or the loop first.")
    else
      recs =
        path |> File.stream!() |> Stream.map(&Jason.decode!/1) |> Enum.to_list()

      {chat, cc} = Enum.split_with(recs, &(&1["kind"] == "chat"))

      header_report(chat)
      chat_usage_report(chat)
      cc_session_report(cc)
    end
  end

  # Surface EVERY response-header key seen — a quota/rate-limit/balance gauge
  # would appear here. Flag the suspicious ones loudly.
  defp header_report(chat) do
    keys =
      chat
      |> Enum.flat_map(fn r -> Map.keys(r["headers"] || %{}) end)
      |> Enum.uniq()
      |> Enum.sort()

    header("RESPONSE HEADER KEYS (#{length(keys)} distinct across #{length(chat)} chat calls)")
    Enum.each(keys, fn k -> Mix.shell().info("  #{flag_header(k)}#{k}") end)

    sample = Enum.find(chat, &(map_size(&1["headers"] || %{}) > 0))
    if sample, do: Mix.shell().info("\nsample headers:\n  #{inspect(sample["headers"])}")
  end

  defp flag_header(k) do
    if String.match?(String.downcase(k), ~r/(ratelimit|quota|token|balance|credit|usage|remain|limit)/),
      do: "★ ",
      else: "  "
  end

  defp chat_usage_report(chat) do
    header("CHAT usage objects (look for reasoning_tokens / cached_tokens the bucket may bill)")

    chat
    |> Enum.reject(&is_nil(&1["usage"]))
    |> Enum.take(5)
    |> Enum.each(fn r -> Mix.shell().info("  #{r["provider"]}: #{inspect(r["usage"])}") end)
  end

  # For each agent session, line up the three competing token totals so the
  # console delta can be matched against the right one.
  defp cc_session_report(cc) do
    header("CC SESSIONS — result.usage vs modelUsage vs summed-per-round-trip (tokens)")
    Mix.shell().info(String.pad_trailing("row", 10) <> String.pad_trailing("turns", 8) <>
      String.pad_trailing("result", 12) <> String.pad_trailing("modelUsage", 14) <>
      String.pad_trailing("summed", 12) <> "subtype")

    Enum.each(cc, fn r ->
      Mix.shell().info(
        String.pad_trailing(to_string(r["row"]), 10) <>
          String.pad_trailing(to_string(r["num_turns"]), 8) <>
          String.pad_trailing(to_string(usage_total(r["usage"])), 12) <>
          String.pad_trailing(to_string(model_usage_total(r["model_usage"])), 14) <>
          String.pad_trailing(to_string(usage_total(r["summed_usage"])), 12) <>
          to_string(r["subtype"])
      )
    end)
  end

  defp usage_total(nil), do: 0

  defp usage_total(u) when is_map(u) do
    num(u, "input_tokens") + num(u, "output_tokens") +
      num(u, "cache_read_input_tokens") + num(u, "cache_creation_input_tokens")
  end

  defp model_usage_total(nil), do: 0

  defp model_usage_total(mu) when is_map(mu) do
    mu
    |> Map.values()
    |> Enum.map(fn m ->
      num(m, "inputTokens") + num(m, "outputTokens") +
        num(m, "cacheReadInputTokens") + num(m, "cacheCreationInputTokens")
    end)
    |> Enum.sum()
  end

  defp header(title), do: Mix.shell().info("\n## #{title}")

  defp num(map, key) do
    case Map.get(map, key) do
      n when is_number(n) -> n
      _ -> 0
    end
  end

  # A minimal but representative "Row log" section: clean, passing, non-idiomatic
  # Elixir + a fix trace — the exact shape the agent normally studies.
  defp row_log(snippet) do
    """
    ## SOLVE CODE (local model output — clean, passing, possibly non-idiomatic)
    ```elixir
    #{snippet}
    ```

    ## CREDENCE FIX TRACE
    applied_rules: []
    issues: []
    valid: true
    (Credence made no changes; this is the highest-value rule-discovery signal.)
    """
  end
end
