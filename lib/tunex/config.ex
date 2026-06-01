defmodule Tunex.Config do
  @moduledoc """
  Resolves per-stage providers (with env overrides), Claude Code settings,
  storage paths, and Budget knobs from application config.

  Only the two chat stages (`:translate`, `:solve`) are configurable; the
  rule-gen stage is hardcoded in `Tunex.Evolve.CredenceRuleGenerator`.
  """

  @doc """
  Provider atom for a chat stage. `TUNEX_<STAGE>_PROVIDER` env wins over the
  configured `stages[stage]`.
  """
  def provider_for(stage) when stage in [:translate, :solve] do
    case env_provider(stage) do
      nil -> Map.fetch!(stages(), stage)
      provider -> provider
    end
  end

  @doc "Output-token floor for a chat stage (translate 32k, solve 8k)."
  def stage_max_tokens(stage) when stage in [:translate, :solve] do
    Application.get_env(:tunex, :stage_max_tokens, %{}) |> Map.fetch!(stage)
  end

  @doc "Raised translate ceiling (≤ Mimo 131k) used on a truncation retry."
  def translate_ceiling, do: Application.get_env(:tunex, :translate_ceiling, 131_072)

  @doc "Max solve/translate validation retries."
  def max_retries, do: Application.get_env(:tunex, :max_retries, 5)

  def subset, do: Application.get_env(:tunex, :subset, "educational_instruct")

  # ── Claude Code (rule-gen) ──────────────────────────────────────────

  def claude_code, do: Application.get_env(:tunex, :claude_code, %{})
  def cc_base_url, do: Map.fetch!(claude_code(), :base_url)
  def cc_model, do: Map.fetch!(claude_code(), :model)
  def cc_max_turns, do: Map.get(claude_code(), :max_turns, 30)
  def cc_timeout_ms, do: Map.get(claude_code(), :timeout_ms, 1_200_000)
  def cc_auth_token, do: Application.fetch_env!(:tunex, :claude_code_auth_token)

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
