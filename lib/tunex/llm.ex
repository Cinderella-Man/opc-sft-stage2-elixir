defmodule Tunex.LLM do
  @moduledoc """
  Calls a local LLM server (llama.cpp / vLLM compatible API).

  Configuration via application env:
    config :tunex, llm_url: "...", llm_model: "..."
  """

  def call(user_prompt, system_prompt, opts \\ []) do
    url = Keyword.get(opts, :url, Application.get_env(:tunex, :llm_url))
    model = Keyword.get(opts, :model, Application.get_env(:tunex, :llm_model))
    max_tokens = Keyword.get(opts, :max_tokens, Application.get_env(:tunex, :max_tokens, 12_288))
    timeout = Keyword.get(opts, :timeout, 600_000)

    body = %{
      messages: [
        %{role: "system", content: system_prompt},
        %{role: "user", content: user_prompt}
      ],
      model: model,
      max_tokens: max_tokens
    }

    case Req.post(url, json: body, receive_timeout: timeout) do
      {:ok, %{status: 200, body: resp}} ->
        choice = resp["choices"] |> List.first()
        content = (choice["message"]["content"] || "") |> String.trim()
        finish = choice["finish_reason"]

        cond do
          String.length(content) > 0 -> {:ok, content}
          finish == "length" -> {:empty, "token limit reached"}
          true -> {:empty, "empty content, finish=#{finish}"}
        end

      {:ok, %{status: s}} -> {:error, "HTTP #{s}"}
      {:error, err} -> {:error, inspect(err, limit: 100)}
    end
  end
end
