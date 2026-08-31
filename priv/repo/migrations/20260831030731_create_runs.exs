defmodule AgentLens.Repo.Migrations.CreateRuns do
  @moduledoc """
  The retained LangSmith runs, partitioned weekly by `start_time`.

  ## Why the unique index is on two columns

  Section 7 asks for a unique constraint on `langsmith_run_id` so re-reads are
  idempotent. PostgreSQL requires every unique index on a partitioned table to
  include the partition key, so it is `(langsmith_run_id, start_time)`.

  This preserves the intended semantics rather than weakening them: `start_time`
  is fixed when LangSmith creates the run and does not change when the run is
  later updated, so upserting on the pair dedupes exactly as upserting on the id
  alone would have.
  """

  use Ecto.Migration

  def up do
    execute("""
    CREATE TABLE runs (
      id bigserial NOT NULL,
      langsmith_run_id text NOT NULL,
      agent_id text NOT NULL,
      trace_id text,
      parent_run_id text,
      name text,
      run_type text,
      start_time timestamptz NOT NULL,
      end_time timestamptz,
      latency_ms integer,
      status text,
      error text,
      model text,
      prompt_tokens integer,
      completion_tokens integer,
      cost_usd numeric(14, 6),
      payload jsonb NOT NULL DEFAULT '{}'::jsonb,
      inserted_at timestamptz NOT NULL DEFAULT now(),
      updated_at timestamptz NOT NULL DEFAULT now(),
      PRIMARY KEY (id, start_time)
    ) PARTITION BY RANGE (start_time)
    """)

    execute("""
    CREATE UNIQUE INDEX runs_langsmith_run_id_start_time_index
      ON runs (langsmith_run_id, start_time)
    """)

    # The dimension every dashboard query slices by: one agent, newest first.
    execute("CREATE INDEX runs_agent_id_start_time_index ON runs (agent_id, start_time DESC)")

    execute("CREATE INDEX runs_trace_id_index ON runs (trace_id) WHERE trace_id IS NOT NULL")
  end

  def down do
    execute("DROP TABLE IF EXISTS runs")
  end
end
