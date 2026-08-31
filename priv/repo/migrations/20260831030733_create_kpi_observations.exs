defmodule AgentLens.Repo.Migrations.CreateKpiObservations do
  @moduledoc """
  Individual KPI values, partitioned monthly.

  ## Why the partition key is `occurred_at`, not `computed_at`

  Section 7 asks for a unique constraint on `(run_id, kpi_slug, kpi_version)`,
  and PostgreSQL requires the partition key to be part of any unique index on a
  partitioned table. Partitioning by `computed_at` would therefore admit
  duplicates: recomputing a KPI produces a new `computed_at`, so the same
  observation would be inserted twice rather than conflicting.

  `occurred_at` is the run's `start_time` — fixed for the life of the
  observation — so partitioning on it keeps the dedupe semantics intact while
  still grouping rows by the period they describe. `computed_at` is retained as
  ordinary provenance.

  ## Why there is no foreign key to `runs`

  Retention is `DROP PARTITION` on independent clocks: payloads are kept ~30
  days and flattened rows ~90. A foreign key would make dropping a `runs`
  partition fail whenever observations outlived it, which is precisely the
  intended arrangement.
  """

  use Ecto.Migration

  def up do
    execute("""
    CREATE TABLE kpi_observations (
      id bigserial NOT NULL,
      run_id bigint,
      agent_id text NOT NULL,
      kpi_slug text NOT NULL,
      value double precision NOT NULL,
      source text NOT NULL,
      kpi_version integer NOT NULL DEFAULT 1,
      judge_model text,
      metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
      occurred_at timestamptz NOT NULL,
      computed_at timestamptz NOT NULL DEFAULT now(),
      PRIMARY KEY (id, occurred_at),
      CONSTRAINT kpi_observations_source_check
        CHECK (source IN ('extracted', 'judged', 'imported'))
    ) PARTITION BY RANGE (occurred_at)
    """)

    execute("""
    CREATE UNIQUE INDEX kpi_observations_dedupe_index
      ON kpi_observations (run_id, kpi_slug, kpi_version, occurred_at)
      WHERE run_id IS NOT NULL
    """)

    # The rollup pass reads one agent's one KPI across a bucket.
    execute("""
    CREATE INDEX kpi_observations_rollup_index
      ON kpi_observations (agent_id, kpi_slug, occurred_at)
    """)
  end

  def down do
    execute("DROP TABLE IF EXISTS kpi_observations")
  end
end
