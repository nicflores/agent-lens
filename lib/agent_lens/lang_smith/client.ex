defmodule AgentLens.LangSmith.Client do
  @moduledoc """
  The LangSmith read API, as a behaviour with a selectable implementation.

  Two implementations: `AgentLens.LangSmith.Mock` in dev and test, and the real
  HTTP client in production. Which one is used is decided in `runtime.exs`, not
  at compile time, so dev and test run with no API key and no network.

  Agent identity is the **workspace**: each agent traces into its own, so every
  call is scoped to one and the workspace id is what everything downstream
  slices by.
  """

  @typedoc "A LangSmith workspace id, which is also our agent identity."
  @type workspace :: String.t()

  @typedoc """
  One page of results.

  `has_more?` tells the poller to keep reading the same window rather than
  advancing its cursor past records it has not seen.
  """
  @type page :: %{items: [map()], has_more?: boolean()}

  @typedoc """
  Read options.

    * `:since` — return records strictly newer than this
    * `:limit` — maximum records to return
    * `:now` — injectable clock, for deterministic tests against the mock
  """
  @type opts :: keyword()

  @doc "Runs in a workspace, oldest first, newer than `:since`."
  @callback list_runs(workspace(), opts()) :: {:ok, page()} | {:error, term()}

  @doc """
  Feedback in a workspace, oldest first, newer than `:since`.

  Filtered by feedback key on the caller's side. Model-generated and human
  feedback map to different KPI slugs and are never averaged together.
  """
  @callback list_feedback(workspace(), opts()) :: {:ok, page()} | {:error, term()}

  @doc "The configured implementation."
  @spec impl() :: module()
  def impl do
    :agent_lens
    |> Application.get_env(:langsmith, [])
    |> Keyword.get(:client, AgentLens.LangSmith.Mock)
  end

  @doc "The workspaces to poll, one per agent."
  @spec workspaces() :: [workspace()]
  def workspaces do
    :agent_lens
    |> Application.get_env(:langsmith, [])
    |> Keyword.get(:workspaces, [])
  end

  @doc "Delegates to the configured implementation."
  @spec list_runs(workspace(), opts()) :: {:ok, page()} | {:error, term()}
  def list_runs(workspace, opts \\ []), do: impl().list_runs(workspace, opts)

  @spec list_feedback(workspace(), opts()) :: {:ok, page()} | {:error, term()}
  def list_feedback(workspace, opts \\ []), do: impl().list_feedback(workspace, opts)
end
