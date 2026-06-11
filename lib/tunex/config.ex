defmodule Tunex.Config do
  @moduledoc """
  Resolves per-stage providers (with env overrides), Claude Code settings,
  storage paths, and Budget knobs from application config.

  The configurable chat stages are `:translate`, `:solve`, `:classify`, and
  `:implement` (the classifier-split rebuild added the latter two — `07` §3.1,
  `08` T0.1). The deleted ClaudeCode rule-gen stage was hardcoded; it is gone.
  """

  @configurable_stages [:translate, :solve, :classify, :implement]

  @doc """
  Provider atom for a chat stage. `TUNEX_<STAGE>_PROVIDER` env wins over the
  configured `stages[stage]`.
  """
  def provider_for(stage) when stage in @configurable_stages do
    case env_provider(stage) do
      nil -> Map.fetch!(stages(), stage)
      provider -> provider
    end
  end

  @doc "Output-token floor for a chat stage (translate 32k, solve 16k, classify/implement 16k)."
  def stage_max_tokens(stage) when stage in @configurable_stages do
    Application.get_env(:tunex, :stage_max_tokens, %{}) |> Map.fetch!(stage)
  end

  @doc "Raised translate ceiling (≤ Mimo 131k) used on a truncation retry."
  def translate_ceiling, do: Application.get_env(:tunex, :translate_ceiling, 131_072)

  @doc "Max solve/translate validation retries."
  def max_retries, do: Application.get_env(:tunex, :max_retries, 5)

  # ── Implementer loop bounds (07 §5.5) ───────────────────────────────
  def rule_gen_max_retries, do: Application.get_env(:tunex, :rule_gen_max_retries, 5)
  def rule_gen_input_ceiling, do: Application.get_env(:tunex, :rule_gen_input_ceiling, 240_000)
  def rule_gen_output_ceiling, do: Application.get_env(:tunex, :rule_gen_output_ceiling, 480_000)

  def subset, do: Application.get_env(:tunex, :subset, "educational_instruct")

  # ── Claude Code (rule-gen) ──────────────────────────────────────────

  def claude_code, do: Application.get_env(:tunex, :claude_code, %{})
  def cc_base_url, do: Map.fetch!(claude_code(), :base_url)
  def cc_model, do: Map.fetch!(claude_code(), :model)
  def cc_max_turns, do: Map.get(claude_code(), :max_turns, 30)
  def cc_timeout_ms, do: Map.get(claude_code(), :timeout_ms, 1_200_000)
  def cc_auth_token, do: Application.fetch_env!(:tunex, :claude_code_auth_token)

  # ── pi agent (alternative implement driver — docs/10) ───────────────
  # pi is a coding-agent CLI (@earendil-works/pi-coding-agent) pointed at Mimo
  # via the custom-provider extension in `pi/mimo_provider.ts`. Used as the
  # agentic implement driver (`implement_driver: :pi`) — many small fast turns
  # instead of one huge slow generation that times out (docs/10 Fix-1 follow-up).
  def pi, do: Application.get_env(:tunex, :pi, %{})
  def pi_extension, do: Path.expand(Map.get(pi(), :extension, "pi/mimo_provider.ts"))
  def pi_provider, do: Map.get(pi(), :provider, "mimo")
  def pi_model, do: Map.get(pi(), :model, "mimo-v2.5-pro")
  def pi_thinking, do: Map.get(pi(), :thinking, "low")
  def pi_tools, do: Map.get(pi(), :tools, "read,bash,edit,write")
  def pi_timeout_ms, do: Map.get(pi(), :timeout_ms, 1_800_000)
  def pi_idle_ms, do: Map.get(pi(), :idle_ms, 360_000)

  @doc "Which implement driver: `:llm` (single-call, default) or `:pi` (agent)."
  def implement_driver, do: Application.get_env(:tunex, :implement_driver, :llm)

  @doc """
  Bearer key for pi's Mimo provider — reused from the existing
  `secret_providers` (no new secret). Returns the raw token (no `Bearer ` prefix)
  for injection via the `TUNEX_MIMO_KEY` env var the pi extension reads.
  """
  def pi_mimo_key do
    Application.get_env(:tunex, :secret_providers, %{})
    |> get_in([:xiaomi_mimo_2_5_pro, :headers, :Authorization])
    |> case do
      "Bearer " <> key -> key
      other -> other
    end
  end

  # ── Paths ───────────────────────────────────────────────────────────

  @doc """
  Path to the Credence clone (path-dep target + push origin).

  Optional in config: when `:credence_clone` is unset (or nil), defaults to a
  sibling `credence/` directory next to this project — i.e. `../credence`
  relative to the project root — so a fresh deploy needs no path edit.
  """
  def credence_clone do
    case Application.get_env(:tunex, :credence_clone) do
      nil -> Path.expand(Path.join(File.cwd!(), "../credence"))
      path -> path
    end
  end
  def git_identity, do: Application.get_env(:tunex, :git_identity, %{})
  def cache_dir, do: Application.get_env(:tunex, :cache_dir, "var/cache")
  def run_dir, do: Application.get_env(:tunex, :run_dir, "var/run")

  def cache_path(name), do: Path.join(cache_dir(), name)
  def run_path(name), do: Path.join(run_dir(), name)

  # ── Budget ──────────────────────────────────────────────────────────

  def budget, do: Application.get_env(:tunex, :budget, %{})

  @doc "receive_timeout (ms) for every LLM call (docs/10). Probe default 30 min."
  def llm_timeout_ms, do: Map.get(budget(), :llm_timeout_ms, 1_800_000)

  @doc "Consecutive rule-gen :transient_abort rows before a graceful halt."
  def transient_storm_limit, do: Map.get(budget(), :transient_storm_limit, 5)

  @doc "Per-row persisted :transient_abort count before giving the row up to too_slow/."
  def transient_row_limit, do: Map.get(budget(), :transient_row_limit, 3)

  # ── Internal ────────────────────────────────────────────────────────

  defp stages, do: Application.get_env(:tunex, :stages, %{})

  defp env_provider(stage) do
    case System.get_env("TUNEX_#{stage |> to_string() |> String.upcase()}_PROVIDER") do
      nil ->
        nil

      "" ->
        nil

      name ->
        # Provider atoms exist as keys in the providers map (loaded at boot),
        # so to_existing_atom is safe and rejects typos.
        try do
          String.to_existing_atom(name)
        rescue
          ArgumentError ->
            raise ArgumentError,
                  "TUNEX_#{String.upcase(to_string(stage))}_PROVIDER=#{name} is not a known provider"
        end
    end
  end
end
