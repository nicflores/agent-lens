defmodule AgentLens do
  @moduledoc """
  AgentLens is an AI agent observability toolkit.

  It provides a small API for capturing normalized trace events from agent
  runtimes: LLM calls, tool calls, planning steps, memory operations, errors,
  and evaluations.
  """

  alias AgentLens.Event
  alias AgentLens.Store

  @typedoc "Supported high-level event categories."
  @type event_type ::
          :trace
          | :span
          | :llm_call
          | :tool_call
          | :planning_step
          | :memory_operation
          | :evaluation
          | :error

  @doc """
  Records an agent observability event.

  A `trace_id` will be generated if one is not supplied.

  ## Examples

      iex> event = AgentLens.record(:tool_call, name: "web_search", attributes: %{query: "elixir telemetry"})
      iex> event.type
      :tool_call

  """
  @spec record(event_type(), keyword()) :: Event.t()
  def record(type, opts \\ []) when is_atom(type) do
    event = %Event{
      id: Keyword.get_lazy(opts, :id, &id/0),
      trace_id: Keyword.get_lazy(opts, :trace_id, &id/0),
      span_id: Keyword.get(opts, :span_id),
      parent_span_id: Keyword.get(opts, :parent_span_id),
      type: type,
      name: Keyword.get(opts, :name),
      timestamp: Keyword.get_lazy(opts, :timestamp, &DateTime.utc_now/0),
      duration_ms: Keyword.get(opts, :duration_ms),
      status: Keyword.get(opts, :status, :unknown),
      attributes: Keyword.get(opts, :attributes, %{}),
      metadata: Keyword.get(opts, :metadata, %{})
    }

    Store.put(event)
  end

  @doc """
  Starts a logical trace and returns its generated trace id.
  """
  @spec start_trace(String.t(), keyword()) :: String.t()
  def start_trace(name, opts \\ []) when is_binary(name) do
    trace_id = Keyword.get_lazy(opts, :trace_id, &id/0)

    record(:trace,
      trace_id: trace_id,
      name: name,
      status: :ok,
      attributes: Keyword.get(opts, :attributes, %{})
    )

    trace_id
  end

  @doc "Returns recent events, newest first."
  @spec recent_events(keyword()) :: [Event.t()]
  def recent_events(opts \\ []), do: Store.recent(opts)

  defp id do
    16
    |> :crypto.strong_rand_bytes()
    |> Base.encode16(case: :lower)
  end
end
