defmodule AgentLens.Retention do
  @moduledoc """
  Enforces the retention clocks.

  Three different things expire on three different schedules, which is the whole
  reason this is not one `DELETE`:

    * **Run and observation partitions** are dropped whole. `DROP TABLE` removes
      the rows and their index entries in constant time, where deleting tens of
      millions of rows would churn the table and leave the space to be vacuumed.
    * **Payloads** expire sooner than the rows that carry them. The bulky `jsonb`
      goes while the flattened columns stay queryable, so a ninety-day chart
      still works after thirty days of payloads are gone. This one genuinely is
      an `UPDATE` — the payload is a column, not a partition.
    * **Rollups** expire per grain: minute buckets last a week, hour buckets a
      quarter, day buckets two years. The table is small enough that `DELETE` is
      the right tool.

  A partition is only dropped once its entire range is past the cutoff, so the
  bucket straddling the boundary keeps its rows.
  """

  require Logger

  alias AgentLens.Partitions.Manager
  alias AgentLens.Repo
  alias AgentLens.Rollup

  @default_runs_days 90
  @default_observations_days 90
  @default_payload_days 30

  @typedoc "What one retention sweep removed."
  @type result :: %{
          runs: [String.t()],
          observations: [String.t()],
          payloads_purged: non_neg_integer(),
          rollups_expired: non_neg_integer()
        }

  @doc """
  Runs a full retention sweep.

  ## Options

    * `:runs_days` — how long flattened run rows are kept (default 90)
    * `:observations_days` — how long observations are kept (default 90)
    * `:payload_days` — how long raw payloads are kept (default 30)
    * `:now`, `:repo`
  """
  @spec run!(keyword()) :: result()
  def run!(opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    runs_cutoff = DateTime.add(now, -Keyword.get(opts, :runs_days, @default_runs_days), :day)

    observations_cutoff =
      DateTime.add(now, -Keyword.get(opts, :observations_days, @default_observations_days), :day)

    payload_cutoff =
      DateTime.add(now, -Keyword.get(opts, :payload_days, @default_payload_days), :day)

    result = %{
      runs: Manager.drop_before!(:runs, runs_cutoff, repo),
      observations: Manager.drop_before!(:kpi_observations, observations_cutoff, repo),
      payloads_purged: purge_payloads!(repo, payload_cutoff),
      rollups_expired: expire_rollups!(repo, now)
    }

    Logger.info(
      "retention: dropped #{length(result.runs)} run and " <>
        "#{length(result.observations)} observation partitions, " <>
        "purged #{result.payloads_purged} payloads, " <>
        "expired #{result.rollups_expired} rollups"
    )

    result
  end

  # Only touches rows that still have a payload, so a repeat sweep does no work
  # and reports nothing purged.
  defp purge_payloads!(repo, cutoff) do
    %{num_rows: rows} =
      repo.query!(
        """
        UPDATE runs
        SET payload = '{}'::jsonb
        WHERE start_time < $1 AND payload <> '{}'::jsonb
        """,
        [cutoff]
      )

    rows
  end

  defp expire_rollups!(repo, now) do
    Enum.reduce(Rollup.granularities(), 0, fn granularity, acc ->
      retain_days = Rollup.tiers()[granularity].retain_days
      cutoff = DateTime.add(now, -retain_days, :day)

      %{num_rows: rows} =
        repo.query!(
          "DELETE FROM kpi_rollups WHERE granularity = $1 AND bucket_start < $2",
          [to_string(granularity), cutoff]
        )

      acc + rows
    end)
  end
end
