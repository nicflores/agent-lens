defmodule AgentLens.Ingestion.Supervisor do
  @moduledoc """
  Supervises the ingestion pollers.

  A `Registry` for lookup and a `DynamicSupervisor` to hold the pollers, so
  workspaces can be added or removed at runtime without a redeploy — the set of
  agents is configuration, not code.

  Started with no pollers unless ingestion is enabled. Automatic polling is off
  by default so that `mix run`, `mix test`, and a plain `iex -S mix` stay fast
  and quiet; `mix agent_lens.seed` performs a backfill on demand.
  """

  use Supervisor

  require Logger

  alias AgentLens.Ingestion.Cursor
  alias AgentLens.Ingestion.Poller
  alias AgentLens.LangSmith.Client

  @registry AgentLens.Ingestion.Registry
  @pollers AgentLens.Ingestion.PollerSupervisor

  @doc false
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl Supervisor
  def init(_opts) do
    children = [
      {Registry, keys: :unique, name: @registry},
      {DynamicSupervisor, name: @pollers, strategy: :one_for_one}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  @doc "Starts one poller."
  @spec start_poller(keyword()) :: DynamicSupervisor.on_start_child()
  def start_poller(opts), do: DynamicSupervisor.start_child(@pollers, {Poller, opts})

  @doc """
  Starts a poller for every configured workspace and stream.

  Two streams per workspace, with independent cursors: feedback lands after the
  run it attaches to, and a slow evaluator must not stall run ingestion.
  """
  @spec start_configured_pollers(keyword()) :: [DynamicSupervisor.on_start_child()]
  def start_configured_pollers(opts \\ []) do
    for workspace <- Client.workspaces(), stream <- Cursor.streams() do
      start_poller(Keyword.merge(opts, workspace: workspace, stream: stream))
    end
  end

  @doc "Every running poller, as `{{workspace, stream}, pid}`."
  @spec pollers() :: [{{String.t(), atom()}, pid()}]
  def pollers do
    Registry.select(@registry, [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
  end

  @doc "Whether pollers should start automatically."
  @spec enabled?() :: boolean()
  def enabled? do
    :agent_lens
    |> Application.get_env(AgentLens.Ingestion, [])
    |> Keyword.get(:enabled, false)
  end
end
