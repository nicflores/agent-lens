defmodule AgentLens.LangSmith.RateLimiter do
  @moduledoc """
  A token bucket in front of the LangSmith API.

  Rate limits are an org-wide budget, not a per-process one, so this is a single
  shared bucket rather than a limit each poller enforces for itself. With one
  poller per workspace per stream, per-process limits would multiply by the
  number of agents and the ceiling would drift upward every time one was added.

  Backfill is what makes this necessary. Steady-state polling is slow by
  construction — load is a function of the poll interval — but a cold start
  drains ninety days as fast as the API will answer, and that is exactly when a
  shared budget matters.

  `acquire/2` blocks the caller. The pollers are independent processes with
  nothing else to do while waiting, so blocking is simpler and more honest than
  a queue that would need its own backpressure.
  """

  use GenServer

  @default_capacity 10
  @default_refill_per_second 5.0

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Takes one token, waiting if the bucket is empty.

  Returns how long it waited, which the caller can log when a backfill is being
  throttled.
  """
  @spec acquire(GenServer.server(), timeout()) :: {:ok, non_neg_integer()}
  def acquire(server \\ __MODULE__, timeout \\ :timer.minutes(2)) do
    GenServer.call(server, :acquire, timeout)
  end

  @doc "The tokens currently available, for tests and introspection."
  @spec available(GenServer.server()) :: float()
  def available(server \\ __MODULE__), do: GenServer.call(server, :available)

  @impl GenServer
  def init(opts) do
    capacity = Keyword.get(opts, :capacity, @default_capacity)

    {:ok,
     %{
       capacity: capacity * 1.0,
       tokens: capacity * 1.0,
       refill_per_second: Keyword.get(opts, :refill_per_second, @default_refill_per_second),
       last_refill: now_ms()
     }}
  end

  @impl GenServer
  def handle_call(:acquire, _from, state) do
    state = refill(state)

    if state.tokens >= 1.0 do
      {:reply, {:ok, 0}, %{state | tokens: state.tokens - 1.0}}
    else
      # Sleeping inside the server serialises waiters, which is the point: they
      # are queued fairly and nobody can jump the budget.
      wait = wait_ms(state)
      Process.sleep(wait)

      state = refill(state)
      {:reply, {:ok, wait}, %{state | tokens: max(state.tokens - 1.0, 0.0)}}
    end
  end

  def handle_call(:available, _from, state) do
    state = refill(state)
    {:reply, state.tokens, state}
  end

  defp refill(state) do
    now = now_ms()
    elapsed = (now - state.last_refill) / 1_000
    tokens = min(state.capacity, state.tokens + elapsed * state.refill_per_second)

    %{state | tokens: tokens, last_refill: now}
  end

  defp wait_ms(state) do
    needed = 1.0 - state.tokens
    ceil(needed / state.refill_per_second * 1_000) |> max(1)
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
