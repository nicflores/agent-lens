defmodule AgentLens.Kpis.Sentiment do
  @moduledoc """
  Polarity of agent responses, scored by a LangSmith evaluator.

  This is the KPI that justifies `:target_band`. An agent producing maximum
  positive sentiment on every single response is not excelling — it is
  malfunctioning, and probably placating users instead of answering them.
  Strongly negative output is equally wrong. Both extremes are unhealthy, which
  a two-direction system renders green at exactly the wrong values.
  """

  use AgentLens.Kpi

  alias AgentLens.Kpi.Definition
  alias AgentLens.Kpi.Input

  @feedback_key "kpi.polarity"

  @impl true
  def definition do
    %Definition{
      slug: :sentiment,
      name: "Response Sentiment",
      short_description:
        "Average response polarity, which should sit in a band rather than max out.",
      methodology: """
      Scored by a LangSmith evaluator publishing the `#{@feedback_key}` feedback
      key on a -1.0 (strongly negative) to 1.0 (strongly positive) scale, and
      averaged over the bucket.

      Evaluated as a target band: mildly positive is healthy, while both
      relentless positivity and persistent negativity are signals worth
      investigating.
      """,
      kind: :judged,
      unit: :score,
      range: {-1.0, 1.0},
      direction: :target_band,
      aggregation: :mean,
      thresholds: %{good: {-0.1, 0.7}, warning: {-0.4, 0.9}},
      health_contribution: :normal,
      min_sample_n: 30,
      sample_rate: 0.2
    }
  end

  @impl true
  def requires, do: [{:feedback, @feedback_key}]

  @impl true
  def compute(%Input.Run{} = run) do
    case Input.Run.fetch(run, {:feedback, @feedback_key}) do
      {:ok, score} when is_number(score) -> {:ok, score * 1.0}
      _other -> :skip
    end
  end
end
