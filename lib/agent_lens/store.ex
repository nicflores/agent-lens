defmodule AgentLens.Store do
  @moduledoc """
  In-memory store for recent agent observability events.

  This is the first storage backend for AgentLens. It keeps the project useful
  during early development while leaving room for persistent backends later.
  """

  use GenServer

  alias AgentLens.Event

  @default_limit 1_000

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    limit = Keyword.get(opts, :limit, @default_limit)

    GenServer.start_link(__MODULE__, %{events: [], limit: limit}, name: name)
  end

  @doc "Stores an event and returns it."
  @spec put(Event.t(), GenServer.server()) :: Event.t()
  def put(%Event{} = event, server \\ __MODULE__) do
    GenServer.call(server, {:put, event})
  end

  @doc "Returns recent events, newest first."
  @spec recent(keyword(), GenServer.server()) :: [Event.t()]
  def recent(opts \\ [], server \\ __MODULE__) do
    limit = Keyword.get(opts, :limit, 100)
    trace_id = Keyword.get(opts, :trace_id)

    GenServer.call(server, {:recent, limit, trace_id})
  end

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:put, event}, _from, state) do
    events = [event | state.events] |> Enum.take(state.limit)
    {:reply, event, %{state | events: events}}
  end

  def handle_call({:recent, limit, nil}, _from, state) do
    {:reply, Enum.take(state.events, limit), state}
  end

  def handle_call({:recent, limit, trace_id}, _from, state) do
    events =
      state.events
      |> Enum.filter(&(&1.trace_id == trace_id))
      |> Enum.take(limit)

    {:reply, events, state}
  end
end
