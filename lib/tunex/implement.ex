defmodule Tunex.Implement do
  @moduledoc """
  The solver-style implementer loop (07 §5; 08 T5.3). Same shape as solve: LLM
  emits whole files → we write them into the clone → focused `mix test` →
  trimmed failures fed back → flat (non-accumulating) retry ≤ `rule_gen_max_retries`.
  No tools, no harness, no token breaker — a local input/output size ceiling
  kills the oversize-row pathology.

  Returns `{:ok, %{module, paths}}` (the Gate runs next, Phase 6) or
  `{:gave_up, reason}` (the router discards the clone + escalates).

  `ctx` (built by the router, Phase 6) carries: `:mode`, `:phase`, `:spec`,
  `:scaffold` (new) / `:bugfix` (bugfix), `:clone`, plus the seed ingredients
  (`:scaffold_files`, `:ast_before/after`, `:real_diagnostic`, `:minimal_set`,
  `:repair?`).
  """

  require Logger

  alias Tunex.{Config, LLM, Pi}
  alias Tunex.Implement.{Output, Seed}

  @doc """
  Implement the rule for `ctx`. Two drivers (docs/10), chosen by
  `opts[:driver]` (defaults to `Config.implement_driver/0`):

    * `:llm` — the single-shot emit→write→test→retry loop below.
    * `:pi` — hand the SAME context to the `pi` coding agent, which fills the
      already-on-disk stubs, runs `mix test`, and loops itself; we then verify
      with the same `focused_test/1` (never trust the agent's word).

  Both return `{:ok, %{module, paths}}` or `{:gave_up, reason}` — the Gate runs next.
  """
  def run(ctx, opts \\ []) do
    case Keyword.get(opts, :driver, Config.implement_driver()) do
      :pi -> run_pi(ctx, opts)
      _ -> run_llm(ctx, opts)
    end
  end

  defp run_llm(ctx, opts) do
    emit = Keyword.get(opts, :emit, &default_emit/2)
    seed = Seed.build(ctx)
    loop(ctx, seed, seed, 1, 0, emit)
  end

  # Agentic driver: the router already wrote the scaffold stubs into the clone
  # (new mode) or the rule+tests are already there (bugfix), so pi edits them in
  # place. After it finishes we re-run the focused tests ourselves — a green
  # claim from the agent is not trusted.
  defp run_pi(ctx, opts) do
    pi = Keyword.get(opts, :pi, &Pi.run/2)
    prompt = Seed.build(ctx, driver: :pi)

    case pi.(prompt, cwd: ctx.clone, row: ctx[:row]) do
      {:ok, _result} ->
        canonicalize_fix_tests(ctx)
        normalize_test_heredocs(ctx)

        case focused_test(ctx) do
          :pass -> {:ok, result(ctx)}
          {:fail, failures} -> {:gave_up, {:pi_tests_red, String.slice(failures, 0, 400)}}
        end

      {:gave_up, reason} ->
        {:gave_up, {:pi, reason}}
    end
  end

  # Deterministic cleanup before the Gate (docs/10): the agent can't byte-predict
  # the rule's exact output, so its `expected =` heredocs are often wrong → the
  # fix test fails → the (often correct) rule is rejected. `mix credence.fix_tests`
  # rewrites `expected` to the rule's REAL output (the project's own convention),
  # for free, no agent turns. Best-effort: a rule that doesn't compile is skipped
  # there and caught by focused_test/the Gate as before.
  defp canonicalize_fix_tests(ctx) do
    fix_tests = ctx |> test_paths() |> Enum.filter(&String.ends_with?(&1, "_fix_test.exs"))

    if fix_tests != [] do
      System.cmd("mix", ["credence.fix_tests" | fix_tests],
        cd: ctx.clone,
        stderr_to_stdout: true,
        env: [{"MIX_ENV", "test"}]
      )
    end
  rescue
    _ -> :ok
  end

  # Strip gratuitous heredoc trailing `\` from the rule's test files before the
  # Gate (docs/10). Verified-safe per file (it re-runs each test, reverts on red),
  # so it can only tidy — never break a green suite.
  defp normalize_test_heredocs(ctx) do
    tests = ctx |> test_paths() |> Enum.filter(&String.ends_with?(&1, "_test.exs"))

    if tests != [] do
      System.cmd("mix", ["credence.normalize_tests" | tests],
        cd: ctx.clone,
        stderr_to_stdout: true,
        env: [{"MIX_ENV", "test"}]
      )
    end
  rescue
    _ -> :ok
  end

  defp loop(ctx, seed, user, attempt, out_total, emit) do
    cond do
      String.length(user) > Config.rule_gen_input_ceiling() ->
        {:gave_up, {:input_ceiling, String.length(user)}}

      out_total > Config.rule_gen_output_ceiling() ->
        {:gave_up, {:output_ceiling, out_total}}

      true ->
        do_attempt(ctx, seed, user, attempt, out_total, emit)
    end
  end

  defp do_attempt(ctx, seed, user, attempt, out_total, emit) do
    case emit.(user, Seed.system()) do
      {tag, content, _usage} when tag in [:ok, :truncated] ->
        out_total = out_total + String.length(content)

        case Output.parse(content, output_opts(ctx)) do
          {:ok, files} ->
            write_files(ctx, files)

            case focused_test(ctx) do
              :pass ->
                {:ok, result(ctx)}

              {:fail, failures} ->
                retry(ctx, seed, content, failures, attempt, out_total, emit)
            end

          {:error, reason} ->
            retry(ctx, seed, content, "INVALID EMIT: #{inspect(reason)}", attempt, out_total, emit)
        end

      {:error, reason} ->
        {:gave_up, {:llm_error, reason}}
    end
  end

  defp retry(ctx, seed, last, failures, attempt, out_total, emit) do
    if attempt >= Config.rule_gen_max_retries() do
      {:gave_up, {:retries_exhausted, String.slice(failures, 0, 400)}}
    else
      # Flat retry: seed + the LAST attempt + the LAST failures (not the whole
      # history) — keeps per-retry size flat, not quadratic (§5.5).
      user = "#{seed}\n\n## YOUR LAST ATTEMPT (FAILED)\n#{last}\n\n## FAILURES (fix these)\n#{trim(failures)}"
      loop(ctx, seed, user, attempt + 1, out_total, emit)
    end
  end

  # ── Output → opts ─────────────────────────────────────────────────────────

  defp output_opts(%{mode: :new, phase: phase} = ctx) do
    [mode: :new, phase: phase, assumptions?: ctx[:minimal_set] not in [nil, []]]
  end

  defp output_opts(%{mode: :bugfix, bugfix: bf}) do
    [mode: :bugfix, test_glob: Map.keys(bf.test_files)]
  end

  # ── Write ─────────────────────────────────────────────────────────────────

  defp write_files(%{mode: :new, scaffold: sc, clone: clone}, %{rule: rule, tests: tests}) do
    roles = role_paths(sc.paths, sc.snake, sc.phase)
    write(clone, roles["RULE"], rule)

    Enum.each(tests, fn {role, content} ->
      case roles[role] do
        nil ->
          # PROPERTY_TEST has no scaffold file; derive its path by convention.
          if role == "PROPERTY_TEST",
            do: write(clone, "test/#{sc.phase}/#{sc.snake}_property_test.exs", content)

        path ->
          write(clone, path, content)
      end
    end)
  end

  defp write_files(%{mode: :bugfix, bugfix: bf, clone: clone}, %{rule: rule, tests: tests}) do
    write(clone, bf.rule_path, rule)
    Enum.each(tests, fn {path, content} -> write(clone, path, content) end)
  end

  # Map scaffold paths to role markers by filename suffix.
  defp role_paths(paths, _snake, _phase) do
    Enum.reduce(paths, %{}, fn rel, acc ->
      cond do
        String.starts_with?(rel, "lib/") -> Map.put(acc, "RULE", rel)
        String.ends_with?(rel, "_check_test.exs") -> Map.put(acc, "CHECK_TEST", rel)
        String.ends_with?(rel, "_analyze_test.exs") -> Map.put(acc, "CHECK_TEST", rel)
        String.ends_with?(rel, "_fix_test.exs") -> Map.put(acc, "FIX_TEST", rel)
        String.ends_with?(rel, "_equivalence_test.exs") -> Map.put(acc, "EQUIVALENCE_TEST", rel)
        true -> acc
      end
    end)
  end

  defp write(clone, rel, content) do
    path = Path.join(clone, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
  end

  # ── Focused test ──────────────────────────────────────────────────────────

  defp focused_test(%{clone: clone} = ctx) do
    paths = test_paths(ctx)

    {out, code} =
      System.cmd("mix", ["test" | paths], cd: clone, stderr_to_stdout: true, env: [{"MIX_ENV", "test"}])

    if code == 0, do: :pass, else: {:fail, out}
  end

  defp test_paths(%{mode: :new, scaffold: sc, clone: clone}) do
    Path.wildcard(Path.join(clone, "test/#{sc.phase}/#{sc.snake}*_test.exs"))
    |> Enum.map(&Path.relative_to(&1, clone))
  end

  defp test_paths(%{mode: :bugfix, bugfix: bf}), do: Map.keys(bf.test_files)

  # ── Result ────────────────────────────────────────────────────────────────

  defp result(%{mode: :new, scaffold: sc}), do: %{module: sc.module, paths: sc.paths}
  defp result(%{mode: :bugfix, bugfix: bf}), do: %{module: bf.module, paths: [bf.rule_path | Map.keys(bf.test_files)]}

  defp trim(failures), do: failures |> String.slice(-3000, 3000) || failures

  defp default_emit(user, system), do: LLM.for_stage(:implement, user, system)
end
