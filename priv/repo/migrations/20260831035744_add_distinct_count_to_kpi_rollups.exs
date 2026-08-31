defmodule AgentLens.Repo.Migrations.AddDistinctCountToKpiRollups do
  @moduledoc """
  Completes the statistic set a bucket carries, so every value in the
  `aggregation` enum has a column behind it.

  The rollup layer computes the full set for every KPI and never branches on
  which one it is; `aggregation` selects which statistic the read path treats
  as *the* value. Leaving `:count_distinct` without a column would have made
  that promise only mostly true.
  """

  use Ecto.Migration

  def change do
    alter table(:kpi_rollups) do
      add :distinct_count, :integer
    end
  end
end
