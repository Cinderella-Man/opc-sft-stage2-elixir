defmodule Tunex.SwitchProposal do
  @moduledoc """
  Switch-discovery lane (07 §3.12 Tier 2, HUMAN-gated; 08 T4.4).

  A `SWITCH_PROPOSAL` decision (or an equiv "diverges under all switches" +
  a clean rare-text class) writes a record to `switch_proposals/` — a would-be
  rule pending a new assumption switch, NEVER built. The harness never touches
  `lib/assumptions.ex`; a human reads the demand ranking and authors the switch.
  """

  alias Tunex.Config

  @spec record(non_neg_integer(), map(), String.t()) :: String.t()
  def record(idx, spec, dir \\ Config.run_path("switch_proposals")) do
    File.mkdir_p!(dir)
    path = Path.join(dir, "#{idx}.json")

    data = %{
      index: idx,
      proposed_switch: spec.proposed_switch,
      before: spec.before,
      rationale: spec.rationale,
      ts: System.os_time(:second)
    }

    File.write!(path, Jason.encode!(data))
    path
  end
end
