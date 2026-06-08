defmodule Mix.Tasks.Tunex.SwitchProposals do
  @shortdoc "Rank proposed assumption switches by demand (07 §3.12 Tier 2)"
  @moduledoc """
  Aggregate `var/run/switch_proposals/` and rank proposed promises by **demand**
  — the count of distinct rule proposals each would unblock (code-pattern
  frequency, the one evidence the harness actually has; NOT runtime-data
  frequency, which it can't see).

      mix tunex.switch_proposals            # uses var/run/switch_proposals
      mix tunex.switch_proposals path/to    # custom dir

  A human reads this ranking and decides whether to author the switch (+ its
  generator + CHANGELOG) in Credence — the harness never writes `lib/assumptions.ex`.
  """
  use Mix.Task

  @impl true
  def run(args) do
    dir = List.first(args) || Path.join(Tunex.Config.run_dir(), "switch_proposals")

    records =
      Path.wildcard(Path.join(dir, "*.json"))
      |> Enum.map(&Jason.decode!(File.read!(&1)))

    if records == [] do
      Mix.shell().info("No switch proposals at #{dir}.")
    else
      records
      |> Enum.group_by(&promise_name/1)
      |> Enum.map(fn {name, rs} -> {name, length(rs), rs} end)
      |> Enum.sort_by(fn {_n, count, _rs} -> -count end)
      |> Enum.each(fn {name, count, rs} ->
        Mix.shell().info("\n#{name} — demand #{count} rule(s)")
        ex = rs |> Enum.map(& &1["index"]) |> Enum.take(5) |> Enum.join(", ")
        Mix.shell().info("  rows: #{ex}")
        summary = rs |> List.first() |> get_in(["proposed_switch", "summary"])
        if summary, do: Mix.shell().info("  summary: #{summary}")
      end)
    end
  end

  defp promise_name(record) do
    get_in(record, ["proposed_switch", "name"]) || "(unnamed)"
  end
end
