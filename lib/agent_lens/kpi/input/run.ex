defmodule AgentLens.Kpi.Input.Run do
  @moduledoc """
  A single LangSmith run: the flattened columns, the retained `jsonb` payload,
  and any feedback scores attached to it.

  Feeds `:extracted` and `:imported` KPIs, which are computed on run arrival.
  """

  alias AgentLens.Kpi.FieldManifest

  defstruct [
    :langsmith_run_id,
    :agent_id,
    :trace_id,
    :parent_run_id,
    :name,
    :run_type,
    :start_time,
    :end_time,
    :latency_ms,
    :status,
    :error,
    :model,
    :prompt_tokens,
    :completion_tokens,
    :cost_usd,
    payload: %{},
    feedback: %{}
  ]

  @type t :: %__MODULE__{
          langsmith_run_id: String.t() | nil,
          agent_id: String.t() | nil,
          trace_id: String.t() | nil,
          parent_run_id: String.t() | nil,
          name: String.t() | nil,
          run_type: String.t() | nil,
          start_time: DateTime.t() | nil,
          end_time: DateTime.t() | nil,
          latency_ms: non_neg_integer() | nil,
          status: String.t() | nil,
          error: String.t() | nil,
          model: String.t() | nil,
          prompt_tokens: non_neg_integer() | nil,
          completion_tokens: non_neg_integer() | nil,
          cost_usd: float() | nil,
          payload: map(),
          feedback: %{optional(String.t()) => number()}
        }

  @doc """
  Reads a field using the same path vocabulary `c:AgentLens.Kpi.requires/0`
  declares and `AgentLens.Kpi.FieldManifest` validates.

  Returns `:error` rather than `nil` for anything absent, so a KPI has to decide
  explicitly what a missing value means instead of silently doing arithmetic on
  `nil`.
  """
  @spec fetch(t(), FieldManifest.path()) :: {:ok, term()} | :error
  def fetch(%__MODULE__{} = run, column) when is_atom(column) do
    case Map.fetch(run, column) do
      {:ok, nil} -> :error
      {:ok, value} -> {:ok, value}
      :error -> :error
    end
  end

  def fetch(%__MODULE__{payload: payload}, {:payload, segments}) when is_list(segments) do
    dig(payload, segments)
  end

  def fetch(%__MODULE__{feedback: feedback}, {:feedback, key}) when is_binary(key) do
    case Map.fetch(feedback, key) do
      {:ok, nil} -> :error
      {:ok, value} -> {:ok, value}
      :error -> :error
    end
  end

  defp dig(value, []), do: {:ok, value}

  defp dig(map, [segment | rest]) when is_map(map) do
    case Map.fetch(map, segment) do
      {:ok, nil} -> :error
      {:ok, value} -> dig(value, rest)
      :error -> :error
    end
  end

  defp dig(_not_a_map, _segments), do: :error
end
