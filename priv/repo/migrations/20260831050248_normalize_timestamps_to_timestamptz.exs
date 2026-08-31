defmodule AgentLens.Repo.Migrations.NormalizeTimestampsToTimestamptz do
  @moduledoc """
  Makes every timestamp column `timestamptz`.

  The tables built with raw SQL — `runs`, `kpi_observations` — already used
  `timestamptz`, while the ones built through Ecto's `:utc_datetime_usec` got
  `timestamp without time zone`. That split is not merely untidy; it is a
  correctness trap.

  The rollup pass matches `kpi_rollups.bucket_start` against
  `date_trunc(..., runs.start_time)`. With one side `timestamp` and the other
  `timestamptz`, PostgreSQL reconciles them using the **session** time zone, so
  `population_n` would attach to the wrong buckets on any connection not set to
  UTC. The values would look plausible and be wrong, which is the worst kind of
  wrong.

  Existing values were written as UTC, so `AT TIME ZONE 'UTC'` reinterprets them
  without shifting anything.
  """

  use Ecto.Migration

  @columns [
    {"kpi_rollups", ~w(bucket_start inserted_at updated_at)},
    {"kpi_definitions", ~w(first_observed_at inserted_at updated_at)},
    {"kpi_thresholds", ~w(inserted_at updated_at)},
    {"ingestion_cursors", ~w(watermark last_polled_at inserted_at updated_at)}
  ]

  def up do
    for {table, columns} <- @columns, column <- columns do
      execute("""
      ALTER TABLE #{table}
        ALTER COLUMN #{column} TYPE timestamptz
        USING #{column} AT TIME ZONE 'UTC'
      """)
    end
  end

  def down do
    for {table, columns} <- @columns, column <- columns do
      execute("""
      ALTER TABLE #{table}
        ALTER COLUMN #{column} TYPE timestamp
        USING #{column} AT TIME ZONE 'UTC'
      """)
    end
  end
end
