defmodule AgentLens.Repo.Migrations.CreateKpiDefinitions do
  @moduledoc """
  The KPI catalog, upserted by `AgentLens.Kpi.Registry` at boot.

  Everything downstream reads definitions from this table rather than from the
  modules, which is why a new KPI module reaches the rollup layer and the UI
  without either being modified.

  `first_observed_at` records where a series legitimately begins. A KPI added
  today has no history before today, and the chart must start there rather than
  plotting zeros for a period that was never measured.
  """

  use Ecto.Migration

  def change do
    create table(:kpi_definitions, primary_key: false) do
      add :slug, :string, primary_key: true
      add :name, :string, null: false
      add :short_description, :string, null: false
      add :methodology, :text
      add :kind, :string, null: false
      add :unit, :string, null: false
      add :range_min, :float
      add :range_max, :float
      add :direction, :string, null: false
      add :aggregation, :string, null: false
      add :thresholds, :map, null: false
      add :health_contribution, :string, null: false
      add :min_sample_n, :integer, null: false, default: 0
      add :sample_rate, :float, null: false, default: 1.0
      add :version, :integer, null: false, default: 1
      add :first_observed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:kpi_definitions, [:kind])
  end
end
