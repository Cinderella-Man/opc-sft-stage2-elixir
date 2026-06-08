defmodule Tunex.Novelty do
  @moduledoc """
  The deterministic novelty pre-check (07 §3.7, 08 T4.2): for a
  `POTENTIAL_NEW_RULE`, run the `before` snippet through `mix credence.covers` in
  the clone. `:covered` ⇒ a real existing rule engaged ⇒ duplicate ⇒ skip the
  implementer (`duplicate/`). `:novel` ⇒ proceed. Behavioural, names no rule,
  phase-agnostic (accepts non-parsing input).
  """

  alias Tunex.Credence

  @spec check(String.t(), String.t()) :: :covered | :novel
  def check(before_module, clone \\ Tunex.Config.credence_clone()) do
    Credence.covers?(before_module, clone)
  end
end
