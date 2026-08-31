defmodule AgentLens.Repo.Migrations.AddObanJobsTable do
  @moduledoc """
  Oban's job tables, which carry the rollup cron, the derived pass, and
  retention.
  """

  use Ecto.Migration

  def up, do: Oban.Migration.up(version: 14)

  # Leaves the tables in place at version 1 rather than dropping job history.
  def down, do: Oban.Migration.down(version: 1)
end
