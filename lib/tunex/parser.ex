defmodule Tunex.Parser do
  @moduledoc """
  Parses structured LLM output delimited by `---SECTION---` markers.

  Supports these output formats:
  - Full: `---INSTRUCTION--- / ---MODULE--- / ---TEST--- / ---END---` (v1 tangled)
  - Translate: `---INSTRUCTION--- / ---TEST--- / ---REFERENCE--- / ---END---` (v2)
  - Module+Test only: `---MODULE--- / ---TEST--- / ---END---`
  - Instruction only: `---INSTRUCTION--- / ---END---`
  """

  @doc "Parse full output with instruction, module, and test sections."
  def parse_full(content) do
    content = strip_outer_fences(content)

    if String.contains?(content, "---INSTRUCTION---") do
      with [_, rest] <- String.split(content, "---INSTRUCTION---", parts: 2),
           [instruction, rest] <- String.split(rest, "---MODULE---", parts: 2),
           [module_code, rest] <- String.split(rest, "---TEST---", parts: 2) do
        test_code = rest |> String.split("---END---", parts: 2) |> List.first() |> strip_fences()
        module_code = strip_fences(module_code)
        instruction = String.trim(instruction)

        if instruction != "" and module_code != "" and test_code != "" do
          {:ok, instruction, module_code, test_code}
        else
          :error
        end
      else
        _ -> :error
      end
    else
      # Fallback: no instruction section, try module+test
      case parse_module_test(content) do
        {:ok, module_code, test_code} -> {:ok, nil, module_code, test_code}
        :error -> :error
      end
    end
  end

  @doc """
  Parse a v2 Translate output: Elixir instruction + tests + reference solution.

  Format: `---INSTRUCTION--- / ---TEST--- / ---REFERENCE--- / ---END---`.
  The reference is validation-only (round-trip check) — never emitted/trained,
  hence its own marker distinct from `parse_full`'s `---MODULE---`.

  Returns `{:ok, instruction, test_code, reference_code}` or `:error`.
  """
  def parse_translate(content) do
    content = strip_outer_fences(content)

    with [_, rest] <- String.split(content, "---INSTRUCTION---", parts: 2),
         [instruction, rest] <- String.split(rest, "---TEST---", parts: 2),
         [test_code, rest] <- String.split(rest, "---REFERENCE---", parts: 2) do
      reference = rest |> String.split("---END---", parts: 2) |> List.first() |> strip_fences()
      test_code = strip_fences(test_code)
      instruction = String.trim(instruction)

      if instruction != "" and test_code != "" and reference != "" do
        {:ok, instruction, test_code, reference}
      else
        :error
      end
    else
      _ -> :error
    end
  end

  @doc "Parse output with module and test sections only (no instruction)."
  def parse_module_test(content) do
    content = strip_outer_fences(content)

    case split_markers(content) do
      {:ok, module_code, test_code} -> {:ok, module_code, test_code}
      :error -> split_bare_modules(content)
    end
  end

  defp split_markers(content) do
    with [_, rest] <- String.split(content, "---MODULE---", parts: 2),
         [module_code, rest] <- String.split(rest, "---TEST---", parts: 2) do
      test_code = rest |> String.split("---END---", parts: 2) |> List.first() |> strip_fences()
      module_code = strip_fences(module_code)

      if module_code != "" and test_code != "" do
        {:ok, module_code, test_code}
      else
        :error
      end
    else
      _ -> :error
    end
  end

  # Fallback: the model dropped the markers and emitted two bare modules (common
  # on retries). Split at the test module — `defmodule …Test do`, which is also
  # the block carrying `use ExUnit.Case`. Everything before it is the solution.
  defp split_bare_modules(content) do
    case Regex.split(~r/\n(?=defmodule\s+[\w.]*Test\b)/, content, parts: 2) do
      [module_code, test_code] ->
        module_code = String.trim(module_code)
        test_code = String.trim(test_code)

        if String.contains?(module_code, "defmodule") and
             String.contains?(test_code, "use ExUnit.Case") do
          {:ok, module_code, test_code}
        else
          :error
        end

      _ ->
        :error
    end
  end

  @doc "Parse output with instruction section only."
  def parse_instruction(content) do
    content = strip_outer_fences(content)

    with [_, rest] <- String.split(content, "---INSTRUCTION---", parts: 2) do
      instruction = rest |> String.split("---END---", parts: 2) |> List.first() |> String.trim()
      if instruction != "", do: {:ok, instruction}, else: :error
    else
      _ -> :error
    end
  end

  @doc "Convert Python entry point name to Elixir snake_case."
  def snake_name(name), do: name |> String.downcase() |> String.replace(~r/[^a-z0-9_]/, "_")

  @doc """
  Convert Python entry point name to idiomatic Elixir function name.

  Applies snake_case conversion and then transforms `is_foo` → `foo?`
  to follow the Elixir convention of using `?` suffix for boolean functions
  instead of the Python `is_` prefix.

  ## Examples

      iex> Tunex.Parser.elixir_name("is_palindrome")
      "palindrome?"

      iex> Tunex.Parser.elixir_name("is_binary_search_tree")
      "binary_search_tree?"

      iex> Tunex.Parser.elixir_name("missing_number")
      "missing_number"

  Only the snake_case `is_` prefix is transformed (Python entry points are
  snake_case); CamelCase is merely downcased:

      iex> Tunex.Parser.elixir_name("IsValid")
      "isvalid"
  """
  def elixir_name(name) do
    snake = snake_name(name)

    case snake do
      "is_" <> rest when rest != "" -> rest <> "?"
      _ -> snake
    end
  end

  @doc """
  Programmatic naming safety-net (folded in from v1's `NamingFixup`).

  If the canonical Elixir name is a `?` predicate but the model still emitted
  the `is_` form (e.g. `def is_palindrome` instead of `def palindrome?`),
  rename `is_foo` → `foo?` everywhere in both module and test code. This is the
  *only* programmatic naming enforcement; canonical names are otherwise trusted.

  Returns `{module_code, test_code, renamed?}`.
  """
  def fix_is_prefix(module_code, test_code, original_entry_point) do
    require Logger

    expected_elixir = elixir_name(original_entry_point)
    snake_python = snake_name(original_entry_point)

    if String.ends_with?(expected_elixir, "?") do
      is_form = snake_python

      has_is_def =
        String.contains?(module_code, "def #{is_form}(") or
          String.contains?(module_code, "def #{is_form}\n") or
          String.contains?(module_code, "defp #{is_form}(")

      if has_is_def do
        Logger.warning(
          "[Parser.fix_is_prefix] model used '#{is_form}' instead of '#{expected_elixir}' — renaming"
        )

        {rename_in_code(module_code, is_form, expected_elixir),
         rename_in_code(test_code, is_form, expected_elixir), true}
      else
        {module_code, test_code, false}
      end
    else
      {module_code, test_code, false}
    end
  end

  defp rename_in_code(code, is_form, question_form) do
    code
    |> String.replace("def #{is_form}(", "def #{question_form}(")
    |> String.replace("defp #{is_form}(", "defp #{question_form}(")
    |> String.replace("def #{is_form}\n", "def #{question_form}\n")
    |> String.replace(".#{is_form}(", ".#{question_form}(")
    |> String.replace(".#{is_form} ", ".#{question_form} ")
    |> String.replace("&#{is_form}/", "&#{question_form}/")
    |> String.replace("#{is_form}(", "#{question_form}(")
    |> String.replace("\"#{is_form}\"", "\"#{question_form}\"")
    |> String.replace("#{is_form} ", "#{question_form} ")
  end

  # ── Internal ───────────────────────────────────────────────────────

  defp strip_outer_fences(s) do
    s
    |> String.replace(~r/^```\w*\n?/, "")
    |> String.replace(~r/\n?```$/, "")
    |> String.trim()
  end

  defp strip_fences(s) do
    s
    |> String.replace(~r/^```\w*\n?/m, "")
    |> String.replace(~r/\n?```\s*$/m, "")
    |> String.trim()
  end
end
