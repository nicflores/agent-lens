defmodule AgentLens.Store.KpiRollup do
  @moduledoc """
  A KPI aggregated into one time bucket at one granularity.

  This is the only table the read path queries. LiveViews never compute on read,
  which is what keeps twenty open dashboards as cheap as one.

  `sample_n` and `population_n` are both carried because they answer different
  questions: how many observations produced this number, and how many runs it
  could have drawn from. A toxicity score from 3 judged runs must not render
  like one from 400.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @granularities ~w(minute hour day)

  @castable [
    :agent_id,
    :kpi_slug,
    :granularity,
    :bucket_start,
    :count,
    :sum,
    :min,
    :max,
    :p50,
    :p95,
    :p99,
    :sample_n,
    :population_n
  ]

  @primary_key false
  schema "kpi_rollups" do
    field :agent_id, :string, primary_key: true
    field :kpi_slug, :string, primary_key: true
    field :granularity, :string, primary_key: true
    field :bucket_start, :utc_datetime_usec, primary_key: true

    field :count, :integer, default: 0
    field :sum, :float
    field :min, :float
    field :max, :float
    field :p50, :float
    field :p95, :float
    field :p99, :float

    field :sample_n, :integer, default: 0
    field :population_n, :integer, default: 0

    timestamps(type: :utc_datetime_usec)
  end

  @doc "The supported rollup grains, coarsest last."
  @spec granularities() :: [String.t()]
  def granularities, do: @granularities

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(rollup, attrs) do
    rollup
    |> cast(attrs, @castable)
    |> validate_required([:agent_id, :kpi_slug, :granularity, :bucket_start])
    |> validate_inclusion(:granularity, @granularities)
    |> validate_number(:sample_n, greater_than_or_equal_to: 0)
    |> validate_number(:population_n, greater_than_or_equal_to: 0)
  end
end
