defmodule Tunex.Markers do
  @moduledoc """
  Split delimited-marker output into `[{key, content}]` (08 T3.2 / T5.2).

  Both the classifier spec and the implementer's whole-file emit use the proven
  `===KEY===` fenced-section scheme (mirroring solve's `---MODULE---`/`---TEST---`,
  more reliable than JSON for code-bearing output). The key is everything between
  the `===` fences, so path-keyed markers (`===TEST:test/pattern/foo.exs===`)
  parse too — the key is `TEST:test/pattern/foo.exs`.

  Order-preserving (duplicate/path keys are kept distinct), and the terminator
  `===END===` is dropped. Content is the block between this marker and the next,
  trailing whitespace trimmed.
  """

  @marker ~r/^\s*===(?<key>[^=]+?)===\s*$/

  @type section :: {String.t(), String.t()}

  @spec split(String.t()) :: [section()]
  def split(text) when is_binary(text) do
    text
    |> String.split("\n")
    |> Enum.reduce({nil, [], []}, fn line, {key, buf, acc} ->
      case Regex.named_captures(@marker, line) do
        %{"key" => k} -> {String.trim(k), [], flush(key, buf, acc)}
        nil -> {key, [line | buf], acc}
      end
    end)
    |> flush_last()
    |> Enum.reverse()
    |> Enum.reject(fn {k, _} -> k == "END" end)
  end

  @doc "Convenience: first occurrence of each key as a map."
  @spec to_map(String.t()) :: %{optional(String.t()) => String.t()}
  def to_map(text) do
    text
    |> split()
    |> Enum.reduce(%{}, fn {k, v}, acc -> Map.put_new(acc, k, v) end)
  end

  defp flush(nil, _buf, acc), do: acc
  defp flush(key, buf, acc), do: [{key, buf |> Enum.reverse() |> Enum.join("\n") |> String.trim()} | acc]

  defp flush_last({key, buf, acc}), do: flush(key, buf, acc)
end
