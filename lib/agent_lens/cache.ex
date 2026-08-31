defmodule AgentLens.Cache do
  @moduledoc """
  A read cache for dashboard state, held in ETS.

  ## Why ETS rather than the process holding the state

  Mounting a LiveView has to be a table lookup, not a message to a process.
  Twenty dashboards mounting at once would queue behind a single GenServer, and
  the read would be serialised through it for no reason — the data is already
  computed and never changes on read.

  So the table is `:public` with `read_concurrency`, one process owns it purely
  for lifecycle, and readers touch ETS directly. Writes go through
  `AgentLens.Broadcaster`, which is the only writer.

  Entries carry the time they were written, so the UI can say how fresh what it
  is showing actually is rather than implying it is live.
  """

  use GenServer

  @table :agent_lens_cache

  @typedoc "What a cached entry is keyed by."
  @type key :: :overview | {:agent, String.t()} | term()

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The ETS table name, for direct reads."
  @spec table() :: atom()
  def table, do: @table

  @doc "Fetches a value, or `:error` if absent."
  @spec fetch(key()) :: {:ok, term()} | :error
  def fetch(key) do
    case :ets.lookup(@table, key) do
      [{^key, value, _stored_at}] -> {:ok, value}
      [] -> :error
    end
  rescue
    ArgumentError -> :error
  end

  @doc "Fetches a value, falling back to `default`."
  @spec get(key(), term()) :: term()
  def get(key, default \\ nil) do
    case fetch(key) do
      {:ok, value} -> value
      :error -> default
    end
  end

  @doc "Writes a value, stamping it with the current time."
  @spec put(key(), term()) :: :ok
  def put(key, value) do
    true = :ets.insert(@table, {key, value, DateTime.utc_now()})
    :ok
  end

  @doc "Removes an entry."
  @spec delete(key()) :: :ok
  def delete(key) do
    true = :ets.delete(@table, key)
    :ok
  end

  @doc "Empties the cache."
  @spec clear() :: :ok
  def clear do
    true = :ets.delete_all_objects(@table)
    :ok
  end

  @doc "When an entry was written, or `nil` if absent."
  @spec stored_at(key()) :: {:ok, DateTime.t()} | :error
  def stored_at(key) do
    case :ets.lookup(@table, key) do
      [{^key, _value, stored_at}] -> {:ok, stored_at}
      [] -> :error
    end
  rescue
    ArgumentError -> :error
  end

  @doc """
  How many seconds ago an entry was written, or `nil` if absent.

  The UI shows this rather than implying the numbers are live: a dashboard that
  silently displays stale data is the same failure as one that shows a
  confident zero.
  """
  @spec age_seconds(key()) :: non_neg_integer() | nil
  def age_seconds(key) do
    case stored_at(key) do
      {:ok, at} -> DateTime.utc_now() |> DateTime.diff(at) |> max(0)
      :error -> nil
    end
  end

  @impl GenServer
  def init(_opts) do
    _table = :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end
end
