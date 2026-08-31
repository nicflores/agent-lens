defmodule AgentLens.Ingestion.Mapper do
  @moduledoc """
  Turns a LangSmith payload into the shapes the rest of the system uses.

  Pure. The poller does the I/O; this decides what a run *is*.

  Two clients feed this: the mock hands over `DateTime` structs, the HTTP client
  hands over ISO 8601 strings. Both are accepted so the ingest path behaves
  identically in dev and production.
  """

  alias AgentLens.Kpi.Input

  @doc """
  Maps a LangSmith run payload onto `runs` column attributes.

  `agent_id` comes from the workspace that was polled, never from the payload:
  agent identity is the workspace, and trusting a payload field would let a
  misconfigured agent write into another agent's series.
  """
  @spec to_run_attrs(map(), String.t()) :: map()
  def to_run_attrs(payload, workspace) when is_map(payload) do
    start_time = timestamp(payload["start_time"])
    end_time = timestamp(payload["end_time"])

    %{
      langsmith_run_id: payload["id"],
      agent_id: workspace,
      trace_id: payload["trace_id"],
      parent_run_id: payload["parent_run_id"],
      name: payload["name"],
      run_type: payload["run_type"],
      start_time: start_time,
      end_time: end_time,
      latency_ms: latency_ms(payload, start_time, end_time),
      status: payload["status"],
      error: payload["error"],
      model: get_in(payload, ["extra", "metadata", "model"]),
      prompt_tokens: payload["prompt_tokens"],
      completion_tokens: payload["completion_tokens"],
      cost_usd: cost(payload["total_cost"]),
      payload: payload
    }
  end

  @doc "Builds the struct KPI modules compute from."
  @spec to_input(map(), %{optional(String.t()) => number()}) :: Input.Run.t()
  def to_input(attrs, feedback \\ %{}) do
    %Input.Run{
      langsmith_run_id: attrs.langsmith_run_id,
      agent_id: attrs.agent_id,
      trace_id: attrs.trace_id,
      parent_run_id: attrs.parent_run_id,
      name: attrs.name,
      run_type: attrs.run_type,
      start_time: attrs.start_time,
      end_time: attrs.end_time,
      latency_ms: attrs.latency_ms,
      status: attrs.status,
      error: attrs.error,
      model: attrs.model,
      prompt_tokens: attrs.prompt_tokens,
      completion_tokens: attrs.completion_tokens,
      cost_usd: to_float(attrs.cost_usd),
      payload: attrs.payload || %{},
      feedback: feedback
    }
  end

  @doc """
  Collapses LangSmith feedback records into a key-to-score map.

  Records with no numeric score are dropped: an evaluator that failed to
  produce a value has not produced a zero.
  """
  @spec to_feedback_scores([map()]) :: %{optional(String.t()) => number()}
  def to_feedback_scores(records) do
    for %{"key" => key, "score" => score} <- records, is_number(score), into: %{} do
      {key, score}
    end
  end

  defp latency_ms(%{"latency_ms" => latency}, _start, _end) when is_integer(latency), do: latency

  defp latency_ms(_payload, %DateTime{} = start, %DateTime{} = finish),
    do: DateTime.diff(finish, start, :millisecond)

  defp latency_ms(_payload, _start, _end), do: nil

  defp timestamp(%DateTime{} = datetime), do: datetime

  defp timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      {:error, _reason} -> nil
    end
  end

  defp timestamp(_other), do: nil

  # Money is stored as a decimal rather than a float, so repeated aggregation
  # does not accumulate binary rounding error.
  defp cost(value) when is_float(value), do: Decimal.from_float(value)
  defp cost(value) when is_integer(value), do: Decimal.new(value)
  defp cost(_other), do: nil

  defp to_float(%Decimal{} = decimal), do: Decimal.to_float(decimal)
  defp to_float(value) when is_number(value), do: value / 1
  defp to_float(_other), do: nil
end
