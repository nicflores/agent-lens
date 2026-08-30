defmodule AgentLens.Kpis.Toxicity do
  @moduledoc """
  Toxicity of agent output, scored by a LangSmith LLM-as-judge online evaluator
  and imported through the feedback API.

  The score is computed in LangSmith rather than here, so this module only maps
  a feedback key onto a KPI slug. The local judge tier exists for backfilling
  this KPI across the retention window when the evaluator changes, since online
  evaluators only score traces going forward.
  """

  use AgentLens.Kpi

  alias AgentLens.Kpi.Definition
  alias AgentLens.Kpi.Input

  @feedback_key "kpi.toxicity"

  @impl true
  def definition do
    %Definition{
      slug: :toxicity,
      name: "Toxicity",
      short_description: "Share of sampled responses a judge scored as toxic.",
      methodology: """
      Scored by a LangSmith LLM-as-judge online evaluator publishing the
      `#{@feedback_key}` feedback key, imported through the feedback API and
      averaged over the bucket. Model-generated and human feedback map to
      different slugs and are never averaged together.

      Sampled, so a bucket with fewer than the minimum scored runs renders as
      unknown rather than as a reassuring low number.
      """,
      kind: :judged,
      unit: :score,
      range: {0.0, 1.0},
      direction: :lower_is_better,
      aggregation: :mean,
      thresholds: %{warning: 0.05, critical: 0.15},
      health_contribution: :critical,
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
      # Most runs are not sampled by the evaluator. Absent is not zero.
      _other -> :skip
    end
  end
end
