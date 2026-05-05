defmodule Tunex.LLM do
  @moduledoc """
  Calls a local LLM server (llama.cpp / vLLM compatible API).

  Configuration via application env:
    config :tunex, llm_url: "...", llm_model: "..."
  """

  require Logger

  def call(user_prompt, system_prompt, opts \\ []) do
    url = Keyword.get(opts, :url, Application.get_env(:tunex, :llm_url))
    authorization = Keyword.get(opts, :authorization, Application.get_env(:tunex, :authorization))
    model = Keyword.get(opts, :model, Application.get_env(:tunex, :llm_model))
    timeout = Keyword.get(opts, :timeout, 600_000)
    headers = %{Authorization: authorization}

    Logger.debug("""
    [LLM.call] ── REQUEST ──────────────────────────────────────
      url:        #{url}
      model:      #{model}
      timeout:    #{timeout}ms
    [LLM.call] ── SYSTEM PROMPT ────────────────────────────────
    #{system_prompt}
    [LLM.call] ── USER PROMPT ──────────────────────────────────
    #{user_prompt}
    [LLM.call] ─────────────────────────────────────────────────
    """)

    body = %{
      messages: [
        %{role: "system", content: system_prompt},
        %{role: "user", content: user_prompt}
      ],
      model: model,
      temperature: 1.0,
      stream: false
    }

    t0 = System.monotonic_time(:millisecond)

    result =
      case Req.post(url, json: body, receive_timeout: timeout, headers: headers) do
        {:ok, %{status: 200, body: resp}} ->
          choice = resp["choices"] |> List.first()
          content = (choice["message"]["content"] || "") |> String.trim()
          finish = choice["finish_reason"]

          Logger.info(
            "[LLM.call] HTTP 200 — finish_reason=#{finish}, content_length=#{String.length(content)}"
          )

          Logger.debug("""
          [LLM.call] ── RESPONSE ─────────────────────────────────
          #{content}
          [LLM.call] ── END RESPONSE ─────────────────────────────
          """)

          cond do
            String.length(content) > 0 -> {:ok, content}
            finish == "length" -> {:empty, "token limit reached"}
            true -> {:empty, "empty content, finish=#{finish}"}
          end

        {:ok, %{status: s, body: resp_body}} ->
          Logger.error("[LLM.call] HTTP #{s} — body: #{inspect(resp_body, limit: 500)}")
          {:error, "HTTP #{s}"}

        {:error, err} ->
          Logger.error("[LLM.call] request error: #{inspect(err, limit: 200)}")
          {:error, inspect(err, limit: 100)}
      end

    elapsed = System.monotonic_time(:millisecond) - t0
    Logger.info("[LLM.call] completed in #{elapsed}ms — result: #{elem(result, 0)}")
    result
  end
end
