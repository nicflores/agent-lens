defmodule AgentLens.Kpis.LatencyP95 do
  @moduledoc """
  End-to-end run latency, aggregated at the 95th percentile.

  The percentile lives in the definition's `aggregation` field rather than in
  this module, which is why the rollup layer needs no knowledge of this KPI.
  """

  use AgentLens.Kpi

  alias AgentLens.Kpi.Definition
  alias AgentLens.Kpi.Input

  @impl true
  def definition do
    %Definition{
      slug: :latency_p95,
      name: "Latency p95",
      short_description: "95th percentile end-to-end run latency.",
      methodology: """
      Each run contributes its wall-clock duration in milliseconds. The bucket
      value is the 95th percentile rather than the mean, because tail latency is
      what users actually experience and a mean hides it.
      """,
      kind: :extracted,
      unit: :ms,
      range: nil,
      direction: :lower_is_better,
      aggregation: :p95,
      thresholds: %{warning: 5_000, critical: 15_000},
      health_contribution: :normal,
      min_sample_n: 20
    }
  end

  @impl true
  def requires, do: [:latency_ms]

  @impl true
  def compute(%Input.Run{latency_ms: latency}) when is_number(latency), do: {:ok, latency * 1.0}
  def compute(%Input.Run{}), do: :skip
end
