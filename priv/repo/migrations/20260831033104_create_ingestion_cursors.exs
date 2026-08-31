defmodule AgentLens.Repo.Migrations.CreateIngestionCursors do
  @moduledoc """
  Per-workspace ingestion watermarks, persisted so a restart resumes rather
  than re-reading history or skipping it.

  One row per `(workspace_id, stream)`. Runs and feedback advance independently
  because feedback arrives *after* the run it attaches to — a shared cursor
  would either stall run ingestion behind a slow evaluator or race ahead of
  feedback that had not been written yet.
  """

  use Ecto.Migration

  def change do
    create table(:ingestion_cursors) do
      add :workspace_id, :string, null: false
      add :stream, :string, null: false

      # Last `start_time` (runs) or `created_at` (feedback) seen. The poller
      # re-reads a small overlap behind this, since records can be updated
      # after creation.
      add :watermark, :utc_datetime_usec

      add :last_polled_at, :utc_datetime_usec
      add :last_error, :text
      add :consecutive_failures, :integer, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:ingestion_cursors, [:workspace_id, :stream])
  end
end
