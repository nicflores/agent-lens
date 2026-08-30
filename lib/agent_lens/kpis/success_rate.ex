defmodule AgentLens.Kpis.SuccessRate do
  @moduledoc """
  The share of runs that completed without error.

  Extracted: free from the run payload, so it is computed inline on every run
  rather than sampled.
  """

  use AgentLens.Kpi

  alias AgentLens.Kpi.Definition
  alias AgentLens.Kpi.Input

  @impl true
  def definition do
    %Definition{
      slug: :success_rate,
      name: "Success Rate",
      short_description: "Share of runs that completed without an error.",
      methodology: """
      Each finished run scores 1.0 when its status is `success` and 0.0 when it
      is `error`. Runs still in flight are skipped rather than scored zero, so
      the rate reflects completed work only. Aggregated as a rate over the
      bucket.
      """,
      kind: :extracted,
      unit: :ratio,
      range: {0.0, 1.0},
      direction: :higher_is_better,
      aggregation: :rate,
      thresholds: %{warning: 0.95, critical: 0.9},
      health_contribution: :critical,
      min_sample_n: 20
    }
  end

  @impl true
  def requires, do: [:status]

  @impl true
  def compute(%Input.Run{status: "success"}), do: {:ok, 1.0}
  def compute(%Input.Run{status: "error"}), do: {:ok, 0.0}

  # A run with no terminal status has no outcome yet. Scoring it zero would
  # depress the rate using data that does not exist.
  def compute(%Input.Run{}), do: :skip
end
