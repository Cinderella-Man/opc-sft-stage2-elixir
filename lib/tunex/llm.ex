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
      |> Keyword.put_new(:stage, stage)

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
    [LLM.call] system:
    #{system_prompt}
    [LLM.call] user:
    #{user_prompt}
    """)

    t0 = System.monotonic_time(:millisecond)

    raw = Req.post(url, json: body, receive_timeout: timeout, headers: headers)
    elapsed = System.monotonic_time(:millisecond) - t0

    record_chat_diag(raw, active, body_params[:model], elapsed)
    result = handle_response(raw)

    maybe_record_usage(result, active, body_params[:model], Keyword.get(opts, :stage))

    Logger.info("[LLM.call] #{active} completed in #{elapsed}ms — #{elem(result, 0)}")
    result
  end

  # Hoard the FULL chat response signal for token reconciliation: every header
  # (a quota/rate-limit gauge may live here, not in the body), the verbatim
  # `usage` object (incl. reasoning_tokens / cached_tokens details a reasoning
  # model emits and our normalized breakdown drops), and finish_reason/model.
  defp record_chat_diag({:ok, %{status: status, headers: hdrs, body: body}}, provider, model, elapsed) do
    usage = if is_map(body), do: body["usage"], else: nil
    choice = if is_map(body), do: List.first(body["choices"] || []), else: nil

    Tunex.Diag.record(%{
      kind: "chat",
      provider: provider,
      model: model,
      returned_model: is_map(body) && body["model"],
      http_status: status,
      elapsed_ms: elapsed,
      finish_reason: choice && choice["finish_reason"],
      usage: usage,
      headers: Tunex.Diag.headers_to_map(hdrs)
    })
  end

  defp record_chat_diag({:error, reason}, provider, model, elapsed) do
    Tunex.Diag.record(%{kind: "chat", provider: provider, model: model, elapsed_ms: elapsed, error: inspect(reason)})
  end

  # Feed Mimo chat `usage` to Budget, tagged with the stage provider + model
  # (for per-provider pricing + the per-call usage ledger). A cast to an
  # unstarted Budget is a no-op, so this is safe in tests and on the free
  # local-Qwen path (usage may be nil).
  defp maybe_record_usage({tag, _content, usage}, provider, model, stage)
       when tag in [:ok, :truncated] and is_map(usage),
       do: Tunex.Budget.record(usage, :chat, %{provider: provider, model: model, stage: stage})

  defp maybe_record_usage(_, _provider, _model, _stage), do: :ok

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
      "[LLM.call] finish=#{finish} len=#{String.length(content)} usage=#{inspect(usage)}\n" <>
        "[LLM.call] response:\n#{content}"
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
