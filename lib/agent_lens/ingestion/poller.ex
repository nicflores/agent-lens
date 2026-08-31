defmodule AgentLens.Ingestion.Poller do
  @moduledoc """
  One polling process per `(workspace, stream)`.

  The process only schedules; `AgentLens.Ingestion.Job` does the ingestion. That
  split keeps the interesting logic testable without timers, and keeps this
  module small enough to reason about.

  ## Load on LangSmith is a function of the poll interval alone

  Nothing user-facing triggers a poll. Twenty people opening the dashboard cost
  LangSmith nothing, because the read path only ever touches our own rollups.
  That is the whole reason ingestion is a process on a timer rather than
  something the UI drives.

  A failing poll backs off exponentially instead of hammering a service that is
  already unhappy, and never advances the cursor, so the window is retried
  rather than skipped.
  """

  use GenServer

  require Logger

  alias AgentLens.Ingestion.Job
  alias AgentLens.LangSmith.Client

  @default_interval :timer.minutes(1)
  @default_limit 500
  @max_backoff :timer.minutes(15)

  @typedoc "How a poller can be addressed: by pid, or by workspace and stream."
  @type ref :: pid() | {String.t(), atom()}

  @doc """
  Starts a poller.

  ## Options

    * `:workspace` and `:stream` — required; together they name the process
    * `:interval` — milliseconds between polls
    * `:limit` — page size
    * `:client`, `:registry`, `:repo`, `:now`
    * `:start_polling` — set false to leave it idle, for tests
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    workspace = Keyword.fetch!(opts, :workspace)
    stream = Keyword.fetch!(opts, :stream)

    GenServer.start_link(__MODULE__, opts, name: via(workspace, stream))
  end

  @doc """
  Child spec keyed by workspace and stream.

  The default spec ids every poller as `AgentLens.Ingestion.Poller`, which
  collides the moment a second one starts. There is one process per workspace
  per stream, so the identity has to include both.
  """
  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :workspace), Keyword.fetch!(opts, :stream)},
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent,
      type: :worker
    }
  end

  @doc "The `:via` tuple naming a poller, so it can be found without a pid."
  @spec via(String.t(), atom()) :: GenServer.name()
  def via(workspace, stream),
    do: {:via, Registry, {AgentLens.Ingestion.Registry, {workspace, stream}}}

  @doc "Runs one poll immediately and returns its result."
  @spec poll_now(ref()) :: {:ok, Job.page_result()} | {:error, term()}
  def poll_now(ref), do: GenServer.call(server(ref), :poll_now, :timer.minutes(5))

  @doc "Drains the whole window, for backfill."
  @spec drain(ref()) :: {:ok, map()} | {:error, term()}
  def drain(ref), do: GenServer.call(server(ref), :drain, :timer.minutes(30))

  @doc "Inspects the poller's counters."
  @spec state(ref()) :: map()
  def state(ref), do: GenServer.call(server(ref), :state)

  @doc "Swaps the client at runtime, used in tests and to recover from a bad config."
  @spec set_client(ref(), module()) :: :ok
  def set_client(ref, client), do: GenServer.call(server(ref), {:set_client, client})

  defp server({workspace, stream}), do: via(workspace, stream)
  defp server(pid), do: pid

  @impl GenServer
  def init(opts) do
    state = %{
      workspace: Keyword.fetch!(opts, :workspace),
      stream: Keyword.fetch!(opts, :stream),
      interval: Keyword.get(opts, :interval, @default_interval),
      job_opts: job_opts(opts),
      polls: 0,
      failures: 0
    }

    _timer = if Keyword.get(opts, :start_polling, false), do: schedule(state, 0)

    {:ok, state}
  end

  @impl GenServer
  def handle_call(:poll_now, _from, state) do
    {result, state} = poll(state)
    {:reply, result, state}
  end

  def handle_call(:drain, _from, state) do
    result = Job.drain(state.workspace, state.stream, state.job_opts)
    {:reply, result, %{state | polls: state.polls + 1}}
  end

  def handle_call(:state, _from, state) do
    {:reply, Map.take(state, [:workspace, :stream, :interval, :polls, :failures]), state}
  end

  def handle_call({:set_client, client}, _from, state) do
    {:reply, :ok, %{state | job_opts: Keyword.put(state.job_opts, :client, client)}}
  end

  @impl GenServer
  def handle_info(:poll, state) do
    {result, state} = poll(state)

    # A full page means there is more waiting, so read again promptly rather
    # than idling a whole interval while falling further behind.
    delay =
      case result do
        {:ok, %{has_more?: true}} -> 0
        {:ok, _result} -> state.interval
        {:error, _reason} -> backoff(state)
      end

    _timer = schedule(state, delay)

    {:noreply, state}
  end

  defp poll(state) do
    case Job.run_once(state.workspace, state.stream, state.job_opts) do
      {:ok, result} ->
        {{:ok, result}, %{state | polls: state.polls + 1, failures: 0}}

      {:error, reason} ->
        {{:error, reason}, %{state | polls: state.polls + 1, failures: state.failures + 1}}
    end
  end

  # Exponential, capped. A service that is struggling should not also have to
  # absorb a poller retrying every second.
  defp backoff(%{failures: failures, interval: interval}) do
    min(interval * Integer.pow(2, min(failures, 10)), @max_backoff)
  end

  defp schedule(_state, delay), do: Process.send_after(self(), :poll, delay)

  defp job_opts(opts) do
    opts
    |> Keyword.take([:client, :registry, :repo, :now, :limit, :overlap_seconds, :backfill_days])
    |> Keyword.put_new(:limit, @default_limit)
    |> Keyword.put_new_lazy(:client, &Client.impl/0)
  end
end
