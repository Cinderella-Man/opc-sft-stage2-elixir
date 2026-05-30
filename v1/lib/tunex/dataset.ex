defmodule Tunex.Dataset do
  @moduledoc """
  Download and load HuggingFace parquet datasets.
  """

  @doc "Ensure the parquet file for a subset is downloaded. Returns the filename."
  def ensure_downloaded(subset) do
    base = Application.get_env(:tunex, :dataset_base)
    filename = "#{subset}_train.parquet"

    if File.exists?(filename) do
      size = File.stat!(filename).size
      IO.puts("Dataset #{filename} exists (#{Float.round(size / 1_048_576, 1)} MB)")
    else
      url = "#{base}/#{subset}/train/0000.parquet"
      IO.puts("Downloading #{subset} parquet...")

      case Req.get(url, into: File.stream!(filename), receive_timeout: 300_000) do
        {:ok, %{status: 200}} ->
          size = File.stat!(filename).size
          IO.puts("  ✓ Downloaded #{Float.round(size / 1_048_576, 1)} MB")

        {:ok, %{status: s}} ->
          File.rm(filename)
          raise "Download failed: HTTP #{s}"

        {:error, e} ->
          File.rm(filename)
          raise "Download failed: #{inspect(e)}"
      end
    end

    filename
  end

  @doc "Load all rows from a parquet file."
  def load_rows(path) do
    df = Explorer.DataFrame.from_parquet!(path)
    rows = Explorer.DataFrame.to_rows(df)
    total = Explorer.DataFrame.n_rows(df)
    {rows, total}
  end
end
