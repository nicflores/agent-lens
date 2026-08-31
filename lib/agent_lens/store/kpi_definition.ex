defmodule AgentLens.Store.KpiDefinition do
  @moduledoc """
  The persisted form of an `AgentLens.Kpi.Definition`.

  Kept deliberately separate from the domain struct: the struct is what KPI
  modules declare and what status evaluation reads, while this is the row the
  rollup layer and the UI resolve against. `AgentLens.Kpi.Catalog` converts
  between them.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @castable [
    :slug,
    :name,
    :short_description,
    :methodology,
    :kind,
    :unit,
    :range_min,
    :range_max,
    :direction,
    :aggregation,
    :thresholds,
    :health_contribution,
    :min_sample_n,
    :sample_rate,
    :version,
    :first_observed_at
  ]

  @primary_key false
  schema "kpi_definitions" do
    field :slug, :string, primary_key: true
    field :name, :string
    field :short_description, :string
    field :methodology, :string
    field :kind, :string
    field :unit, :string
    field :range_min, :float
    field :range_max, :float
    field :direction, :string
    field :aggregation, :string
    field :thresholds, :map
    field :health_contribution, :string
    field :min_sample_n, :integer
    field :sample_rate, :float
    field :version, :integer

    # Where the series legitimately starts. A KPI added today has no history
    # before today, and the chart must begin here rather than plotting zeros.
    field :first_observed_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(definition, attrs) do
    definition
    |> cast(attrs, @castable)
    |> validate_required([
      :slug,
      :name,
      :short_description,
      :kind,
      :unit,
      :direction,
      :aggregation,
      :thresholds,
      :health_contribution
    ])
  end
end
