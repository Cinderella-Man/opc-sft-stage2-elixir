defmodule Tunex.Progress do
  @moduledoc """
  Tracks which indices have been processed via simple text files.

  Each progress file contains one index per line. Loading returns a MapSet
  for O(1) membership checks. Supports both per-script progress files
  and cross-file smart resume (scanning output + error JSONL files).
  """

  @doc "Load completed indices from a progress file into a MapSet."
  def load(path) do
    if File.exists?(path) do
      path
      |> File.read!()
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&String.to_integer/1)
      |> MapSet.new()
    else
      MapSet.new()
    end
  end

  @doc "Append a completed index to the progress file."
  def mark_done(path, idx) do
    File.write!(path, "#{idx}\n", [:append])
  end

  @doc "Delete the progress file to allow full re-processing."
  def clear(path) do
    File.rm(path)
  end

  @doc """
  Scan JSONL output and error files to build a MapSet of all indices
  that have already been processed (successfully or with errors).
  """
  def load_completed_indices(output_path, errors_path) do
    output_set = collect_indices_from_jsonl(output_path)
    error_set = collect_indices_from_jsonl(errors_path)
    MapSet.union(output_set, error_set)
  end

  defp collect_indices_from_jsonl(path) do
    if File.exists?(path) do
      path
      |> File.stream!()
      |> Stream.map(&String.trim/1)
      |> Stream.reject(&(&1 == ""))
      |> Stream.map(fn line ->
        case Jason.decode(line) do
          {:ok, %{"index" => idx}} when is_integer(idx) -> idx
          _ -> nil
        end
      end)
      |> Stream.reject(&is_nil/1)
      |> MapSet.new()
    else
      MapSet.new()
    end
  end
end
