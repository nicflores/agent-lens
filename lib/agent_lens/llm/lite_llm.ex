defmodule AgentLens.LLM.LiteLLM do
  @moduledoc """
  Talks to a LiteLLM proxy over its OpenAI-compatible chat completions API.

  Deliberately thin. The proxy already handles routing, keys, retries against
  the upstream provider, and cost accounting; duplicating any of that here
  would only create a second place for it to be wrong.
  """

  @behaviour AgentLens.LLM.Client

  alias AgentLens.LLM.Client

  @impl Client
  def complete(prompt, opts \\ []) do
    config = Keyword.get(opts, :config, llm_config())
    model = Keyword.get(opts, :model, Client.default_model())

    body = %{
      model: model,
      temperature: Keyword.get(opts, :temperature, 0),
      max_tokens: Keyword.get(opts, :max_tokens, 256),
      messages: [%{role: "user", content: prompt}]
    }

    request =
      [
        method: :post,
        url: "/chat/completions",
        base_url: Keyword.fetch!(config, :endpoint),
        json: body,
        headers: headers(config),
        receive_timeout: Keyword.get(opts, :receive_timeout, 60_000)
      ]
      |> maybe_put_plug(opts)

    case request |> Req.new() |> Req.request() do
      {:ok, %{status: status, body: payload}} when status in 200..299 ->
        parse(payload, model)

      {:ok, %{status: status, body: payload}} ->
        {:error, {:http_status, status, payload}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The model that actually served the request is recorded, not the one we
  # asked for: a proxy is free to route elsewhere, and a judged score is only
  # interpretable if you know what judged it.
  defp parse(%{"choices" => [%{"message" => %{"content" => text}} | _rest]} = payload, requested) do
    {:ok, %{text: text, model: Map.get(payload, "model", requested)}}
  end

  defp parse(payload, _requested), do: {:error, {:unexpected_response, payload}}

  defp headers(config) do
    case Keyword.get(config, :api_key) do
      nil -> [{"content-type", "application/json"}]
      key -> [{"authorization", "Bearer " <> key}, {"content-type", "application/json"}]
    end
  end

  defp maybe_put_plug(request, opts) do
    case Keyword.get(opts, :plug) do
      nil -> request
      plug -> Keyword.put(request, :plug, plug)
    end
  end

  defp llm_config, do: Application.get_env(:agent_lens, :llm, [])
end
