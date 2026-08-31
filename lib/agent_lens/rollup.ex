defmodule AgentLens.Rollup do
  @moduledoc """
  Turns observations into time buckets. This is the only module that does so.

  ## Why it never mentions a KPI

  It computes the *whole* statistic set — count, sum, min, max, p50, p95, p99,
  distinct count — for every KPI, and a definition's `aggregation` selects which
  of those the read path treats as the value. That is what makes `aggregation`
  data rather than code: adding a KPI never touches this module, because there
  is nothing here to branch on.

  ## Why each grain is computed from raw observations

  Percentiles do not compose. The p95 of a day is not the average, or the
  maximum, of twenty-four hourly p95s, so an hour bucket cannot be rolled up
  from minute buckets without quietly producing a wrong number. Each grain is
  therefore computed from the observations directly, while they are still
  retained — which is also why the day grain outlives them.

  ## Keeping the door open

  Everything about bucketing lives here. If this ever becomes the bottleneck, a
  TimescaleDB continuous aggregate can replace this one module and nothing above
  it changes.
  """

  alias AgentLens.Repo

  @tiers %{
    minute: %{seconds: 60, trunc: "minute", retain_days: 7},
    hour: %{seconds: 3_600, trunc: "hour", retain_days: 90},
    day: %{seconds: 86_400, trunc: "day", retain_days: 730}
  }

  # Section 11: cap every chart at roughly this many points, so query cost is
  # bounded no matter what range the user asks for.
  @default_max_points 300

  @typedoc "A rollup grain."
  @type granularity :: :minute | :hour | :day

  @doc "The rollup tiers, coarsest retained longest."
  @spec tiers() :: map()
  def tiers, do: @tiers

  @doc "The grains, finest first."
  @spec granularities() :: [granularity()]
  def granularities, do: [:minute, :hour, :day]

  @doc "How many seconds one bucket of this grain spans."
  @spec seconds_per_bucket(granularity()) :: pos_integer()
  def seconds_per_bucket(granularity), do: @tiers[granularity].seconds

  @doc """
  Truncates a timestamp to the start of its bucket.

  ## Examples

      iex> AgentLens.Rollup.bucket_start(~U[2026-08-30 13:45:37.123456Z], :hour)
      ~U[2026-08-30 13:00:00.000000Z]

  """
  @spec bucket_start(DateTime.t(), granularity()) :: DateTime.t()
  def bucket_start(datetime, :minute),
    do: %{datetime | second: 0, microsecond: {0, 6}}

  def bucket_start(datetime, :hour),
    do: %{datetime | minute: 0, second: 0, microsecond: {0, 6}}

  def bucket_start(datetime, :day),
    do: %{datetime | hour: 0, minute: 0, second: 0, microsecond: {0, 6}}

  @doc """
  The finest stored grain that covers a range without exceeding the point cap.

  This is what bounds read cost: a user asking for two years gets day buckets,
  not two years of minutes.

  ## Two caveats worth knowing

  The point cap and the grain cannot always both be satisfied by choosing a
  tier, because only three tiers exist:

    * At the default cap, a 24-hour range resolves to **hour** buckets (24
      points), not minute buckets — 1,440 minute points would be five times over
      the cap. Serving true minute resolution for a day means reading minute
      buckets and re-aggregating them up to ~300 display points, which belongs
      to the read path.
    * Beyond roughly 300 days there is no coarser tier to fall back to, so `:day`
      is returned even though it exceeds the cap — two years is 730 points. The
      same read-path re-aggregation applies.

  So this answers "which stored tier do I read from", and the caller remains
  responsible for how many points it puts on the wire.
  """
  @spec granularity_for(DateTime.t(), DateTime.t(), pos_integer()) :: granularity()
  def granularity_for(from, to, max_points \\ @default_max_points) do
    span = DateTime.diff(to, from)

    Enum.find(granularities(), :day, fn granularity ->
      span / seconds_per_bucket(granularity) <= max_points
    end)
  end

  @doc """
  How many stored buckets a range spans at a given grain.

  The read path uses this to decide how far it must re-aggregate to stay within
  its point budget.
  """
  @spec bucket_count(DateTime.t(), DateTime.t(), granularity()) :: non_neg_integer()
  def bucket_count(from, to, granularity) do
    to
    |> DateTime.diff(from)
    |> max(0)
    |> div(seconds_per_bucket(granularity))
  end

  @doc """
  The SQL expression yielding a bucket's value for a given aggregation.

  This is the other half of "aggregation is data": the rollup writes every
  statistic, and this picks the one a KPI declared. A new KPI selects a
  different column rather than requiring new code.

  `:mean` and `:rate` are the same arithmetic — a rate is the mean of a series
  of ones and zeros — and both guard against a zero count rather than dividing
  by it.
  """
  @spec value_expression(atom()) :: String.t()
  def value_expression(aggregation) when aggregation in [:mean, :rate],
    do: "(sum / NULLIF(count, 0))"

  def value_expression(:p50), do: "p50"
  def value_expression(:p95), do: "p95"
  def value_expression(:p99), do: "p99"
  def value_expression(:count), do: "count::double precision"
  def value_expression(:count_distinct), do: "distinct_count::double precision"

  @doc """
  Recomputes every bucket of `granularity` whose start falls in `[from, to)`.

  Idempotent: buckets are upserted, so a window can be recomputed after late or
  corrected observations arrive without accumulating duplicates.

  Returns the number of buckets written.
  """
  @spec run!(granularity(), DateTime.t(), DateTime.t(), keyword()) :: {:ok, non_neg_integer()}
  def run!(granularity, from, to, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)
    tier = Map.fetch!(@tiers, granularity)

    written = aggregate_observations(repo, granularity, tier.trunc, from, to)
    :ok = attach_population(repo, granularity, tier.trunc, from, to)

    {:ok, written}
  end

  defp aggregate_observations(repo, granularity, trunc, from, to) do
    %{num_rows: rows} =
      repo.query!(
        """
        INSERT INTO kpi_rollups (
          agent_id, kpi_slug, granularity, bucket_start,
          count, sum, min, max, p50, p95, p99, distinct_count,
          sample_n, population_n, inserted_at, updated_at
        )
        SELECT
          o.agent_id,
          o.kpi_slug,
          $1,
          date_trunc($2, o.occurred_at),
          count(*),
          sum(o.value),
          min(o.value),
          max(o.value),
          percentile_cont(0.5)  WITHIN GROUP (ORDER BY o.value),
          percentile_cont(0.95) WITHIN GROUP (ORDER BY o.value),
          percentile_cont(0.99) WITHIN GROUP (ORDER BY o.value),
          count(DISTINCT o.value),
          count(*),
          0,
          now(), now()
        FROM kpi_observations o
        WHERE o.occurred_at >= $3 AND o.occurred_at < $4
        GROUP BY o.agent_id, o.kpi_slug, date_trunc($2, o.occurred_at)
        ON CONFLICT (agent_id, kpi_slug, granularity, bucket_start) DO UPDATE SET
          count          = EXCLUDED.count,
          sum            = EXCLUDED.sum,
          min            = EXCLUDED.min,
          max            = EXCLUDED.max,
          p50            = EXCLUDED.p50,
          p95            = EXCLUDED.p95,
          p99            = EXCLUDED.p99,
          distinct_count = EXCLUDED.distinct_count,
          sample_n       = EXCLUDED.sample_n,
          updated_at     = EXCLUDED.updated_at
        """,
        [to_string(granularity), trunc, from, to]
      )

    rows
  end

  # population_n is how many runs the bucket could have drawn from, which is a
  # property of the bucket rather than of any KPI. Without it, a score from
  # three sampled runs would render exactly like one from four hundred.
  defp attach_population(repo, granularity, trunc, from, to) do
    repo.query!(
      """
      UPDATE kpi_rollups r
      SET population_n = p.n
      FROM (
        SELECT agent_id, date_trunc($2, start_time) AS bucket, count(*) AS n
        FROM runs
        WHERE start_time >= $3 AND start_time < $4
        GROUP BY 1, 2
      ) p
      WHERE r.agent_id = p.agent_id
        AND r.granularity = $1
        AND r.bucket_start = p.bucket
      """,
      [to_string(granularity), trunc, from, to]
    )

    :ok
  end
end
