defmodule AgentLens.Repo.Migrations.CreateKpiThresholds do
  @moduledoc """
  Per-agent threshold overrides.

  KPI modules define sensible defaults, but thresholds are *configuration*: the
  right toxicity threshold for a customer-facing agent is wrong for an internal
  research one, and tuning must not require a deploy.
  """

  use Ecto.Migration

  def change do
    create table(:kpi_thresholds) do
      add :agent_id, :string, null: false

      add :kpi_slug,
          references(:kpi_definitions, column: :slug, type: :string, on_delete: :delete_all),
          null: false

      add :thresholds, :map, null: false
      add :updated_by, :string

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:kpi_thresholds, [:agent_id, :kpi_slug])
  end
end
