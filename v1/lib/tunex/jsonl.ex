defmodule Tunex.JSONL do
  @moduledoc """
  Read and write JSONL (JSON Lines) files.

  Provides atomic writes via tmp file + rename to prevent
  corruption if the process is interrupted mid-write.
  """

  @doc "Read all entries from a JSONL file. Returns a list of decoded maps."
  def read(path) do
    if File.exists?(path) do
      path
      |> File.stream!()
      |> Stream.map(&String.trim/1)
      |> Stream.reject(&(&1 == ""))
      |> Stream.map(fn line ->
        case Jason.decode(line) do
          {:ok, entry} -> entry
          _ -> nil
        end
      end)
      |> Stream.reject(&is_nil/1)
      |> Enum.to_list()
    else
      []
    end
  end

  @doc "Write entries to a JSONL file atomically (via tmp + rename)."
  def write(path, entries) do
    tmp = path <> ".tmp"
    content = Enum.map_join(entries, "\n", &Jason.encode!/1) <> "\n"
    File.write!(tmp, content)
    File.rename!(tmp, path)
  end

  @doc "Append a single entry to a JSONL file."
  def append(path, entry) do
    line = Jason.encode!(entry) <> "\n"
    File.write!(path, line, [:append, :utf8])
  end

  @doc "Open a JSONL file for streaming appends. Returns file handle."
  def open_append(path) do
    File.open!(path, [:append, :utf8])
  end

  @doc "Append an entry via an open file handle."
  def append_to(file, entry) do
    IO.write(file, Jason.encode!(entry) <> "\n")
  end
end
