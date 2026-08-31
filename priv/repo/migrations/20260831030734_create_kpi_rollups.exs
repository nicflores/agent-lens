defmodule AgentLens.Repo.Migrations.CreateKpiRollups do
  @moduledoc """
  Tiered rollup buckets. This is the only table the read path ever queries —
  LiveViews never compute on read.

  `sample_n` and `population_n` are separate on purpose. A toxicity score drawn
  from 3 judged runs must not render identically to one drawn from 400, and the
  UI needs both numbers to say so.
  """

  use Ecto.Migration

  def change do
    create table(:kpi_rollups, primary_key: false) do
      add :agent_id, :string, primary_key: true
      add :kpi_slug, :string, primary_key: true
      add :granularity, :string, primary_key: true
      add :bucket_start, :utc_datetime_usec, primary_key: true

      add :count, :integer, null: false, default: 0
      add :sum, :float
      add :min, :float
      add :max, :float
      add :p50, :float
      add :p95, :float
      add :p99, :float

      # How many observations backed this bucket, versus how many runs it could
      # in principle have drawn from.
      add :sample_n, :integer, null: false, default: 0
      add :population_n, :integer, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    # Serving a chart: one KPI for one agent over a time range at one grain.
    create index(:kpi_rollups, [:agent_id, :kpi_slug, :granularity, :bucket_start])

    # Comparing one KPI across every agent, for the agent grid.
    create index(:kpi_rollups, [:kpi_slug, :granularity, :bucket_start])

    # Retention sweeps delete whole grains by age.
    create index(:kpi_rollups, [:granularity, :bucket_start])
  end
end
