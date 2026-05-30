defmodule Tunex.Pipeline.Solve do
  @moduledoc """
  Solve an Elixir exercise with the local Qwen model — **Python-blind**.

  The prompt contains ONLY the Elixir instruction, the (round-trip-validated)
  Elixir tests, and the canonical function name. Qwen never sees Python source,
  the Python instruction, or the reference solution — so its non-idiomatic
  output is the rule-discovery feedstock, free of source-language interference.

  Modeled on v1's `ConvertLoop.attempt` retry skeleton: single-shot generation,
  the `Validator` runs the full pipeline, failures feed back into a retry prompt
  until `Config.max_retries`. There is no Refine stage.

  Truncation here is a normal failed attempt (same-ceiling re-roll, NOT a raised
  ceiling — a stuck solve is wandering, not budget-starved); empty likewise
  retries; an API `{:error, _}` bubbles up for Budget classification.
  """

  require Logger

  alias Tunex.{Config, LLM, Parser, Report, Validator}

  @system ~S"""
  You write idiomatic Elixir. Given an Elixir problem statement and its ExUnit
  test suite, implement a module that passes the tests.

  Requirements:
  - The module MUST be named `Solution`.
  - Implement the function using the exact canonical name given (already
    idiomatic — boolean predicates end with `?`, never the `is_` prefix).
  - Idiomatic Elixir: pattern matching, multi-clause functions, pipes, guards,
    @doc/@spec, descriptive parameter names (never single letters), and prefix
    unused params with `_` independently per clause.
  - Keep `use ExUnit.Case, async: false` in the test module; tests call
    `Solution.<fn>`.

  OUTPUT (nothing else, no markdown fences):
  ---MODULE---
  <elixir Solution module>
  ---TEST---
  <the ExUnit test module>
  ---END---
  """

  @doc "The Solve system prompt (Python-free)."
  def system_prompt, do: @system

  @doc """
  Build the initial user prompt. Python-free: instruction + tests + canonical
  function name only.
  """
  def build_initial(instruction, test, fn_name) do
    """
    Implement this Elixir exercise.

    ## Problem
    #{instruction}

    ## Tests (your module must pass these)
    ```elixir
    #{test}
    ```

    Module: `Solution`. Function: `#{fn_name}`.
    Output the `Solution` module and the test suite.
    Output: ---MODULE--- / ---TEST--- / ---END---
    """
  end

  @doc "Build the retry prompt from the previous attempt + validator errors."
  def build_retry(previous_output, failures, fn_name) do
    """
    Your previous Elixir solution failed validation. Fix it.

    ## Previous Output (ERRORS)
    #{previous_output}

    ## Errors
    #{Report.format_errors(failures)}

    Reminder: module `Solution`, function `#{fn_name}` (boolean predicates use the
    `?` suffix, never the `is_` prefix). Idiomatic Elixir, descriptive names,
    prefix unused params with `_` per clause.
    Output: ---MODULE--- / ---TEST--- / ---END---
    """
  end

  @doc """
  Run the Solve loop. `entry_point` is the original (Python) name — used only to
  derive the canonical Elixir name and to drive `Parser.fix_is_prefix`; it never
  enters a prompt as Python source.

  Returns:
    * `{:ok, %{instruction, elixir_code, elixir_test, entry_point, attempts}}`
    * `{:failed, %{reason, attempts, last}}`
    * `{:error, reason}` — bubbled API error
  """
  def run(instruction, test, entry_point, workspace, opts \\ []) do
    fn_name = Parser.elixir_name(entry_point)
    user = build_initial(instruction, test, fn_name)
    attempt(instruction, entry_point, fn_name, user, workspace, opts, 1, nil)
  end

  # ── Attempt loop ────────────────────────────────────────────────────

  defp attempt(instruction, ep, fn_name, user, ws, opts, n, last) do
    if n > Config.max_retries() do
      Logger.warning("[Solve] giving up after #{n - 1} attempts")
      {:failed, %{reason: "exceeded retries", attempts: n - 1, last: last}}
    else
      do_attempt(instruction, ep, fn_name, user, ws, opts, n, last)
    end
  end

  defp do_attempt(instruction, ep, fn_name, user, ws, opts, n, last) do
    Logger.info("[Solve attempt #{n}] generating (fn=#{fn_name})")

    case LLM.for_stage(:solve, user, system_prompt(), opts) do
      {:ok, content, _usage} ->
        handle_content(content, instruction, ep, fn_name, user, ws, opts, n, last)

      {:truncated, _content, _usage} ->
        Logger.warning("[Solve attempt #{n}] truncated — same-ceiling re-roll")
        attempt(instruction, ep, fn_name, user, ws, opts, n + 1, last)

      {:empty, reason} ->
        Logger.warning("[Solve attempt #{n}] empty (#{reason}) — retry")
        attempt(instruction, ep, fn_name, user, ws, opts, n + 1, last)

      {:error, reason} ->
        Logger.error("[Solve attempt #{n}] API error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp handle_content(content, instruction, ep, fn_name, user, ws, opts, n, last) do
    case Parser.parse_module_test(content) do
      {:ok, mod, test} ->
        {mod, test, renamed?} = Parser.fix_is_prefix(mod, test, ep)
        if renamed?, do: Logger.warning("[Solve attempt #{n}] applied is_ → ? rename")

        {fails, final_mod, final_test} = Validator.run(mod, test, ws)

        current = %{
          instruction: instruction,
          elixir_code: final_mod,
          elixir_test: final_test,
          validation_failures: fails
        }

        if fails == [] do
          Logger.info("[Solve attempt #{n}] validation PASSED")

          {:ok,
           %{
             instruction: instruction,
             elixir_code: final_mod,
             elixir_test: final_test,
             entry_point: fn_name,
             attempts: n
           }}
        else
          Logger.warning(
            "[Solve attempt #{n}] validation FAILED: #{inspect(Enum.map(fails, &elem(&1, 0)))}"
          )

          retry = build_retry(content, fails, fn_name)
          attempt(instruction, ep, fn_name, retry, ws, opts, n + 1, current)
        end

      :error ->
        Logger.warning("[Solve attempt #{n}] parse failed — re-roll")
        attempt(instruction, ep, fn_name, user, ws, opts, n + 1, last)
    end
  end
end
