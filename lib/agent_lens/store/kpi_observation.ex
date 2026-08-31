defmodule AgentLens.Store.KpiObservation do
  @moduledoc """
  One KPI value for one run.

  `source` records where the number came from — computed inline from the
  payload, produced by our own judge, or imported from a LangSmith evaluator.
  All three flow through the same rollup path, but they are not interchangeable
  provenance and the methodology drawer shows the difference.

  `occurred_at` is the run's `start_time`, not the time we computed the value.
  It is the partition key, and being stable is what lets recomputation conflict
  and dedupe rather than insert a second row.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @sources ~w(extracted judged imported)

  @castable [
    :run_id,
    :agent_id,
    :kpi_slug,
    :value,
    :source,
    :kpi_version,
    :judge_model,
    :metadata,
    :occurred_at
  ]

  @primary_key false
  schema "kpi_observations" do
    field :id, :id, read_after_writes: true
    field :run_id, :integer
    field :agent_id, :string
    field :kpi_slug, :string, primary_key: true
    field :value, :float
    field :source, :string
    field :kpi_version, :integer, default: 1
    field :judge_model, :string
    field :metadata, :map, default: %{}
    field :occurred_at, :utc_datetime_usec, primary_key: true
    field :computed_at, :utc_datetime_usec, read_after_writes: true
  end

  @doc "The permitted `source` values."
  @spec sources() :: [String.t()]
  def sources, do: @sources

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(observation, attrs) do
    observation
    |> cast(attrs, @castable)
    |> validate_required([:agent_id, :kpi_slug, :value, :source, :occurred_at])
    |> validate_inclusion(:source, @sources)
    |> validate_number(:kpi_version, greater_than: 0)
  end
end
