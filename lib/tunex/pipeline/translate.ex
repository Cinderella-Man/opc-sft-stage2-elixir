defmodule Tunex.Pipeline.Translate do
  @moduledoc """
  Translate a Python SFT row into an Elixir exercise via remote Mimo.

  This is the **only** stage that sees Python. It produces:
    * an Elixir **instruction** (problem only, never implementation),
    * Elixir **ExUnit tests** targeting the canonical `Solution.<fn>`,
    * an Elixir **reference solution** (validation-only — used by the round-trip
      check; never emitted or trained).

  Canonical names are injected and trusted: module `Solution`, function =
  `Parser.elixir_name(entry_point)`.

  Truncation is handled entirely here (see plan #1): on `{:truncated, _}` retry
  **once** with a raised ceiling (≤ Mimo's 131k); if it still truncates, or the
  output is empty/unparseable, return `:untranslatable`. Callers therefore only
  ever see a complete translation, a terminal `:untranslatable`, or a bubbled
  API `{:error, _}`. **Nothing is cached here** — `RoundTrip` writes the single
  `Cache.put` after the round-trip verdict resolves.
  """

  require Logger

  alias Tunex.{Cache, Config, LLM, Parser}

  @system ~S"""
  You translate Python coding exercises into Elixir coding exercises. You produce
  THREE things: an Elixir instruction, Elixir ExUnit tests, and an Elixir
  reference solution.

  INSTRUCTION rules: describe the PROBLEM, not the SOLUTION. Never mention
  specific Elixir functions, data structures, or recursion styles. State the
  function name, input/output contract, complexity, and edge-case behavior.

  CANONICAL NAMES (already chosen for you — use them verbatim everywhere):
  - The module MUST be named `Solution`.
  - The function MUST use the exact name given in the prompt (it already follows
    Elixir convention — e.g. boolean predicates end with `?`, never `is_` prefix).
  - Tests AND the reference solution must both call this exact name.

  TEST rules: the test module MUST include `use ExUnit.Case, async: false` right
  after `defmodule`. Translate the Python test cases faithfully — same inputs,
  same expected outputs — as ExUnit assertions on `Solution.<fn>`.

  REFERENCE rules: a correct, idiomatic Elixir implementation of `Solution` that
  passes the tests. It is used only to validate the tests; quality is secondary
  to correctness.

  OUTPUT FORMAT (nothing else, no markdown fences):
  ---INSTRUCTION---
  <elixir problem statement>
  ---TEST---
  <elixir ExUnit test module>
  ---REFERENCE---
  <elixir Solution module>
  ---END---
  """

  @doc "The system prompt (stable; part of the cache key)."
  def system_prompt, do: @system

  @doc "Resolved model string for the translate stage (part of the cache key)."
  def model do
    provider = Config.provider_for(:translate)
    Application.get_env(:tunex, :providers, %{}) |> get_in([provider, :model])
  end

  @doc "Rendered user prompt for a row (part of the cache key)."
  def build_user(row) do
    fn_name = Parser.elixir_name(row.entry_point)
    tests = if is_list(row.tests), do: Enum.join(row.tests, "\n"), else: to_string(row.tests)

    """
    Translate this Python exercise to Elixir.

    ## Python Instruction
    #{row.instruction}

    ## Python Solution
    ```python
    #{row.code}
    ```

    ## Python Tests
    #{tests}

    ## Canonical Elixir names (use verbatim)
    - Module: `Solution`
    - Function: `#{fn_name}`

    Output: ---INSTRUCTION--- / ---TEST--- / ---REFERENCE--- / ---END---
    """
  end

  @doc "Cache key for a row's translation."
  def cache_key(row), do: Cache.key(system_prompt(), build_user(row), model())

  @doc """
  Produce a complete translation, handling truncation internally.

  Returns `{:ok, %{instruction, test, reference}}`, `:untranslatable`, or a
  bubbled `{:error, reason}` (HTTP/network — for Budget classification).
  """
  def translate(row) do
    user = build_user(row)
    do_translate(user, Config.stage_max_tokens(:translate), false)
  end

  # ── Internal ────────────────────────────────────────────────────────

  defp do_translate(user, max_tokens, retried?) do
    case LLM.for_stage(:translate, user, system_prompt(), max_tokens: max_tokens) do
      {:ok, content, _usage} ->
        parse(content)

      {:truncated, _content, _usage} when not retried? ->
        ceiling = Config.translate_ceiling()
        Logger.warning("[Translate] truncated at #{max_tokens} — retrying with ceiling #{ceiling}")
        do_translate(user, ceiling, true)

      {:truncated, _content, _usage} ->
        Logger.error("[Translate] still truncated at ceiling — :untranslatable")
        :untranslatable

      {:empty, reason} ->
        Logger.error("[Translate] empty response (#{reason}) — :untranslatable")
        :untranslatable

      {:error, reason} ->
        Logger.error("[Translate] API error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp parse(content) do
    case Parser.parse_translate(content) do
      {:ok, instruction, test, reference} ->
        {:ok, %{instruction: instruction, test: test, reference: reference}}

      :error ->
        Logger.error("[Translate] unparseable output — :untranslatable")
        :untranslatable
    end
  end
end
