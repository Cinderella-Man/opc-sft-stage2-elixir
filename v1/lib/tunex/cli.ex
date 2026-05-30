defmodule Tunex.CLI do
  @moduledoc """
  Shared CLI argument parsing for all scripts.
  """

  @doc "Parse --indices 1,2,3 from argv. Returns {indices | nil, remaining_args}."
  def parse_indices(args) do
    case Enum.find_index(args, &(&1 == "--indices")) do
      nil ->
        {nil, args}

      i ->
        indices =
          args
          |> Enum.at(i + 1)
          |> String.split(",")
          |> Enum.map(&(&1 |> String.trim() |> String.to_integer()))

        remaining = args |> List.delete_at(i) |> List.delete_at(i)
        {indices, remaining}
    end
  end

  @doc "Parse --start N from argv. Returns {indices | nil, remaining_args}."
  def parse_start(args, jsonl_path) do
    case Enum.find_index(args, &(&1 == "--start")) do
      nil ->
        {nil, args}

      i ->
        start_n = args |> Enum.at(i + 1) |> String.to_integer()
        remaining = args |> List.delete_at(i) |> List.delete_at(i)

        indices =
          if File.exists?(jsonl_path) do
            jsonl_path
            |> File.stream!()
            |> Stream.map(&String.trim/1)
            |> Stream.reject(&(&1 == ""))
            |> Stream.map(fn line ->
              case Jason.decode(line) do
                {:ok, %{"index" => idx}} when is_integer(idx) and idx >= start_n -> idx
                _ -> nil
              end
            end)
            |> Stream.reject(&is_nil/1)
            |> Enum.to_list()
          else
            []
          end

        {indices, remaining}
    end
  end

  @doc "Parse --workers N from argv. Returns {count, remaining_args}."
  def parse_workers(args) do
    case Enum.find_index(args, &(&1 == "--workers")) do
      nil ->
        {1, args}

      i ->
        n = args |> Enum.at(i + 1) |> String.to_integer()
        remaining = args |> List.delete_at(i) |> List.delete_at(i)
        {n, remaining}
    end
  end

  @doc "Format scope description for display."
  def scope_label(nil), do: "ALL entries"

  def scope_label(indices) when length(indices) > 10,
    do: "#{length(indices)} entries"

  def scope_label(indices),
    do: "indices: #{Enum.join(indices, ", ")}"

  @doc "Get the JSONL path from remaining args or use default."
  def jsonl_path(args, default \\ "elixir_sft_educational_instruct.jsonl") do
    case args do
      [path] -> path
      [] -> default
      _ -> nil
    end
  end

  @doc "Derive error file path from output path."
  def errors_path(jsonl_path) do
    String.replace(jsonl_path, ".jsonl", "_errors.jsonl")
  end
end
