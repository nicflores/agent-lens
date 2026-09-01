defmodule AgentLens.LLM.Client do
  @moduledoc """
  The tool's own model access, as a behaviour.

  Pointed at the **LiteLLM proxy** rather than a provider SDK. Model routing,
  keys and cost accounting already live there, and reaching past it would mean
  reimplementing all three and having them drift.

  Used for the local judge tier, and later for explaining what changed in a
  window. Mockable, because dev and test must cost nothing.
  """

  @typedoc "What the model returned."
  @type completion :: %{text: String.t(), model: String.t()}

  @doc """
  Completes a prompt.

  ## Options

    * `:model` — overrides the configured default
    * `:temperature` — defaults to 0, since a judge that disagrees with itself
      between runs produces drift that is entirely its own
    * `:max_tokens`
  """
  @callback complete(prompt :: String.t(), opts :: keyword()) ::
              {:ok, completion()} | {:error, term()}

  @doc "The configured implementation."
  @spec impl() :: module()
  def impl do
    :agent_lens
    |> Application.get_env(:llm, [])
    |> Keyword.get(:client, AgentLens.LLM.Mock)
  end

  @doc "The model the judge tier should use unless told otherwise."
  @spec default_model() :: String.t()
  def default_model do
    :agent_lens
    |> Application.get_env(:llm, [])
    |> Keyword.get(:model, "gpt-4o-mini")
  end

  @doc "Delegates to the configured implementation."
  @spec complete(String.t(), keyword()) :: {:ok, completion()} | {:error, term()}
  def complete(prompt, opts \\ []), do: impl().complete(prompt, opts)
end
