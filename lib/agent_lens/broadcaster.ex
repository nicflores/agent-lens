defmodule AgentLens.Broadcaster do
  @moduledoc """
  The single writer of dashboard state.

  ## One writer, N readers

  One process computes the overview on a timer, caches it, and publishes it over
  `Phoenix.PubSub`. Every open dashboard subscribes and is pushed the same
  result, so twenty of them cost what one costs.

  The naive alternative — each LiveView polling on its own timer — is what kills
  you: load scales with how many people happen to be looking, which is exactly
  the moment you least want extra database work. Here, nothing a user does
  causes a query.

  Reads (`overview/0`, `agent_summary/1`) come from the ETS cache and fall back
  to querying only when nothing has been computed yet, so a dashboard mounted
  seconds after boot still renders.
  """

  use GenServer

  require Logger

  alias AgentLens.Cache
  alias AgentLens.Query

  @default_interval :timer.seconds(15)
  @pubsub AgentLens.PubSub

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  The PubSub topic for a subscription target.

  ## Examples

      iex> AgentLens.Broadcaster.topic(:overview)
      "dashboard:overview"

      iex> AgentLens.Broadcaster.topic({:agent, "ws-support"})
      "dashboard:agent:ws-support"

  """
  @spec topic(:overview | {:agent, String.t()}) :: String.t()
  def topic(:overview), do: "dashboard:overview"
  def topic({:agent, agent_id}), do: "dashboard:agent:#{agent_id}"

  @doc "Subscribes the calling process to updates."
  @spec subscribe(:overview | {:agent, String.t()}) :: :ok | {:error, term()}
  def subscribe(target), do: Phoenix.PubSub.subscribe(@pubsub, topic(target))

  @doc "Unsubscribes the calling process."
  @spec unsubscribe(:overview | {:agent, String.t()}) :: :ok
  def unsubscribe(target), do: Phoenix.PubSub.unsubscribe(@pubsub, topic(target))

  @doc """
  The current overview, from cache.

  Falls back to a direct query only if nothing has been cached yet — a mount
  moments after boot should render rather than show an empty dashboard.
  """
  @spec overview() :: map()
  def overview do
    case Cache.fetch(:overview) do
      {:ok, overview} -> overview
      :error -> Query.overview()
    end
  end

  @doc "One agent's summary, from cache."
  @spec agent_summary(String.t()) :: map()
  def agent_summary(agent_id) do
    case Cache.fetch({:agent, agent_id}) do
      {:ok, summary} -> summary
      :error -> Query.agent_summary(agent_id)
    end
  end

  @doc "How stale the cached overview is, in seconds, or `nil` if never computed."
  @spec age_seconds() :: non_neg_integer() | nil
  def age_seconds, do: Cache.age_seconds(:overview)

  @doc "Recomputes and publishes immediately."
  @spec refresh() :: {:ok, map()} | {:error, term()}
  def refresh, do: GenServer.call(__MODULE__, :refresh, :timer.minutes(2))

  @doc "Inspects the broadcaster's counters."
  @spec state() :: map()
  def state, do: GenServer.call(__MODULE__, :state)

  @doc """
  Whether the periodic refresh should run.

  Off in test, where each test drives `refresh/0` explicitly against the
  sandboxed connection it owns.
  """
  @spec timer_enabled?() :: boolean()
  def timer_enabled? do
    :agent_lens
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:enabled, true)
  end

  @impl GenServer
  def init(opts) do
    state = %{
      interval: Keyword.get(opts, :interval, @default_interval),
      refreshes: 0,
      failures: 0,
      last_refresh_at: nil
    }

    _timer = if Keyword.get(opts, :start_timer, false), do: schedule(state)

    {:ok, state}
  end

  @impl GenServer
  def handle_call(:refresh, _from, state) do
    case compute_and_publish() do
      {:ok, overview} ->
        {:reply, {:ok, overview}, bump(state)}

      {:error, _reason} = error ->
        {:reply, error, %{state | failures: state.failures + 1}}
    end
  end

  def handle_call(:state, _from, state), do: {:reply, state, state}

  @impl GenServer
  def handle_info(:refresh, state) do
    state =
      case compute_and_publish() do
        {:ok, _overview} ->
          bump(state)

        {:error, reason} ->
          Logger.warning("dashboard refresh failed: #{inspect(reason)}")
          %{state | failures: state.failures + 1}
      end

    _timer = schedule(state)

    {:noreply, state}
  end

  defp compute_and_publish do
    overview = Query.overview()

    :ok = Cache.put(:overview, overview)
    :ok = Phoenix.PubSub.broadcast(@pubsub, topic(:overview), {:overview_updated, overview})

    Enum.each(overview.agents, fn summary ->
      :ok = Cache.put({:agent, summary.agent_id}, summary)

      :ok =
        Phoenix.PubSub.broadcast(
          @pubsub,
          topic({:agent, summary.agent_id}),
          {:agent_updated, summary}
        )
    end)

    {:ok, overview}
  rescue
    exception -> {:error, exception}
  end

  defp bump(state),
    do: %{state | refreshes: state.refreshes + 1, last_refresh_at: DateTime.utc_now()}

  defp schedule(state), do: Process.send_after(self(), :refresh, state.interval)
end
