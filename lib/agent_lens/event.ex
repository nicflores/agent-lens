defmodule AgentLens.Event do
  @moduledoc """
  A normalized observability event emitted by an AI agent runtime.

  Events are intentionally small and dependency-free for now. They can model
  LLM calls, tool calls, planner steps, memory reads, evaluations, errors, or
  any other operation in an agent trace.
  """

  @enforce_keys [:id, :trace_id, :type, :timestamp]
  defstruct [
    :id,
    :trace_id,
    :span_id,
    :parent_span_id,
    :type,
    :name,
    :timestamp,
    :duration_ms,
    :status,
    attributes: %{},
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          trace_id: String.t(),
          span_id: String.t() | nil,
          parent_span_id: String.t() | nil,
          type: atom(),
          name: String.t() | nil,
          timestamp: DateTime.t(),
          duration_ms: non_neg_integer() | nil,
          status: :ok | :error | :unknown | nil,
          attributes: map(),
          metadata: map()
        }
end
