defmodule Tunex.Parser do
  @moduledoc """
  Parses structured LLM output delimited by `---SECTION---` markers.

  Supports three output formats:
  - Full: `---INSTRUCTION--- / ---MODULE--- / ---TEST--- / ---END---`
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

  @doc "Parse output with module and test sections only (no instruction)."
  def parse_module_test(content) do
    content = strip_outer_fences(content)

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
