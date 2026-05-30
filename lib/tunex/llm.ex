defmodule Tunex.LLM do
  @moduledoc """
  Chat-completions client for the two chat stages (Translate + Solve).

  `call/3` returns a three-way content classification plus token `usage`:

    * `{:ok, content, usage}`        — non-empty content, finish_reason ≠ "length"
    * `{:truncated, content, usage}` — finish_reason == "length" (any content, incl "")
    * `{:empty, reason}`             — empty content, not truncated
    * `{:error, {:http, status, body}}`
    * `{:error, {:network, reason}}`

  The `{:truncated, _}` case fixes the v1 bug where non-empty-but-truncated
  output was silently accepted (the `content != ""` branch won before the
  length check). Per-stage handling of truncation differs — see the pipeline
  modules; Translate raises the ceiling, Solve re-rolls at the same ceiling.
  """

  require Logger

  alias Tunex.Config

  @doc """
  Resolve the provider + token floor for a chat stage and call the model.

  `opts` overrides win over the stage defaults (e.g. Translate's raised-ceiling
  retry passes `max_tokens:` to lift the floor).
  """
  def for_stage(stage, user_prompt, system_prompt, opts \\ []) do
    provider = Config.provider_for(stage)
    floor = Config.stage_max_tokens(stage)

    opts =
      opts
      |> Keyword.put_new(:active_provider, provider)
      |> Keyword.put_new(:max_tokens, floor)

    call(user_prompt, system_prompt, opts)
  end

  @doc """
  Low-level call. Honors `opts[:active_provider]`, `opts[:max_tokens]`,
  `opts[:temperature]`, `opts[:url]`, `opts[:headers]`, `opts[:timeout]`.
  """
  def call(user_prompt, system_prompt, opts \\ []) do
    active =
      Keyword.get(opts, :active_provider, Application.get_env(:tunex, :active_provider))

    config = provider_config(active)

    url = Keyword.get(opts, :url, Map.fetch!(config, :url))
    headers = Keyword.get(opts, :headers, Map.get(config, :headers, %{}))
    timeout = Keyword.get(opts, :timeout, 600_000)

    body_params =
      config
      |> Map.drop([:url, :headers, :token_param])
      |> apply_overrides(config, opts)

    body =
      Map.put(body_params, :messages, [
        %{role: "system", content: system_prompt},
        %{role: "user", content: user_prompt}
      ])

    Logger.debug("""
    [LLM.call] provider=#{active} url=#{url} model=#{body_params[:model]} timeout=#{timeout}ms
    [LLM.call] system: #{String.slice(system_prompt, 0..120)}…
    [LLM.call] user: #{String.slice(user_prompt, 0..120)}…
    """)

    t0 = System.monotonic_time(:millisecond)

    result =
      Req.post(url, json: body, receive_timeout: timeout, headers: headers)
      |> handle_response()

    maybe_record_usage(result)

    elapsed = System.monotonic_time(:millisecond) - t0
    Logger.info("[LLM.call] #{active} completed in #{elapsed}ms — #{elem(result, 0)}")
    result
  end

  # Feed Mimo chat `usage` to Budget. A cast to an unstarted Budget is a no-op,
  # so this is safe in tests and on the free local-Qwen path (usage may be nil).
  defp maybe_record_usage({tag, _content, usage}) when tag in [:ok, :truncated] and is_map(usage),
    do: Tunex.Budget.record(usage, :chat)

  defp maybe_record_usage(_), do: :ok

  # ── Body assembly ───────────────────────────────────────────────────

  # Merge per-call overrides into the request body. `max_tokens` is written
  # under the provider's `token_param` (Mimo: max_completion_tokens; Qwen:
  # max_tokens), dropping any stale provider-level value first.
  defp apply_overrides(body_params, config, opts) do
    token_param = Map.get(config, :token_param, :max_tokens)

    body_params =
      case Keyword.fetch(opts, :max_tokens) do
        {:ok, n} ->
          body_params
          |> Map.drop([:max_tokens, :max_completion_tokens])
          |> Map.put(token_param, n)

        :error ->
          body_params
      end

    case Keyword.fetch(opts, :temperature) do
      {:ok, t} -> Map.put(body_params, :temperature, t)
      :error -> body_params
    end
  end

  # ── Response handling (three-way mapping + usage) ───────────────────

  defp handle_response({:ok, %{status: 200, body: %{"choices" => [choice | _]} = body}}) do
    content = (choice["message"]["content"] || "") |> String.trim()
    finish = choice["finish_reason"]
    usage = body["usage"]

    Logger.debug(
      "[LLM.call] finish=#{finish} len=#{String.length(content)} usage=#{inspect(usage)}"
    )

    cond do
      finish == "length" -> {:truncated, content, usage}
      content != "" -> {:ok, content, usage}
      true -> {:empty, "empty content, finish=#{finish}"}
    end
  end

  defp handle_response({:ok, %{status: status, body: body}}) do
    Logger.error("[LLM.call] HTTP #{status} — #{inspect(body, limit: 500)}")
    {:error, {:http, status, body}}
  end

  defp handle_response({:error, reason}) do
    Logger.error("[LLM.call] request error: #{inspect(reason, limit: 200)}")
    {:error, {:network, reason}}
  end

  # ── Internal ────────────────────────────────────────────────────────

  defp provider_config(provider) do
    base = Application.get_env(:tunex, :providers, %{})
    secrets = Application.get_env(:tunex, :secret_providers, %{})
    Map.merge(Map.get(base, provider, %{}), Map.get(secrets, provider, %{}))
  end
end
