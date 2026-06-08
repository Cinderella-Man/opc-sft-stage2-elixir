defmodule Tunex.Classify.Spec do
  @moduledoc """
  The classifier's structured "thick spec" (07 §4.1).

  `decision` ∈ `:no_action | :bugfix_rule | :potential_new_rule | :switch_proposal`.
  Fields are populated per decision (see §4.1):

    * `:rule_name`      — `BUGFIX_RULE` only (a module atom ∈ APPLIED_RULES).
    * `:proposed_name`  — `POTENTIAL_NEW_RULE` only (semantic snake_case).
    * `:phase`          — `:pattern | :syntax | :semantic` when a rule is proposed.
    * `:before`/`:after`— the offending / idiomatic snippets (full defmodules).
    * `:assumptions`    — existing switch names (§3.12 Tier 1); `[]` = no-promise.
    * `:proposed_switch`— `SWITCH_PROPOSAL` only (a proposed promise, §3.12 Tier 2).
    * `:rationale`      — one line.
  """

  @enforce_keys [:decision]
  defstruct [
    :decision,
    :rule_name,
    :proposed_name,
    :phase,
    :before,
    :after,
    :proposed_switch,
    :rationale,
    assumptions: []
  ]

  @type decision :: :no_action | :bugfix_rule | :potential_new_rule | :switch_proposal
  @type t :: %__MODULE__{decision: decision()}
end
