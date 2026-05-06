defmodule Tunex.LLM do
  require Logger

  defp provider_config(provider) do
    base = Application.get_env(:tunex, :providers, %{})
    secrets = Application.get_env(:tunex, :secret_providers, %{})

    base_cfg = Map.get(base, provider, %{})
    secret_cfg = Map.get(secrets, provider, %{})

    Map.merge(base_cfg, secret_cfg)
  end

  def call(user_prompt, system_prompt, opts \\ []) do
    active = Keyword.get(opts, :active_provider,
               Application.get_env(:tunex, :active_provider))
    config = provider_config(active)

    url = Keyword.get(opts, :url, Map.fetch!(config, :url))
    headers = Keyword.get(opts, :headers, Map.get(config, :headers, %{}))
    timeout = Keyword.get(opts, :timeout, 600_000)

    body_params = Map.drop(config, [:url, :headers])

    body = Map.put(body_params, :messages, [
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

    elapsed = System.monotonic_time(:millisecond) - t0
    Logger.info("[LLM.call] #{active} completed in #{elapsed}ms — #{elem(result, 0)}")
    result
  end

  defp handle_response({:ok, %{status: 200, body: %{"choices" => [choice | _]}}}) do
    content = (choice["message"]["content"] || "") |> String.trim()
    finish = choice["finish_reason"]

    Logger.debug("[LLM.call] finish=#{finish} len=#{String.length(content)}")

    cond do
      content != "" -> {:ok, content}
      finish == "length" -> {:empty, "token limit reached"}
      true -> {:empty, "empty content, finish=#{finish}"}
    end
  end

  defp handle_response({:ok, %{status: status, body: body}}) do
    Logger.error("[LLM.call] HTTP #{status} — #{inspect(body, limit: 500)}")
    {:error, "HTTP #{status}"}
  end

  defp handle_response({:error, err}) do
    Logger.error("[LLM.call] request error: #{inspect(err, limit: 200)}")
    {:error, inspect(err, limit: 100)}
  end
end
