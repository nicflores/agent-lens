defmodule AgentLens.Query do
  @moduledoc """
  The read path. Every dashboard query goes through here, and every one of them
  reads `kpi_rollups` and nothing else.

  ## Never compute on read

  There is no aggregation over `runs` or `kpi_observations` in this module. The
  expensive work happened when the bucket closed; a chart is a range scan over a
  table with a composite primary key in exactly that order. That is what lets
  twenty open dashboards cost about what one costs.

  ## Gaps stay gaps

  Buckets that do not exist are simply absent from the series. Nothing is
  zero-filled and nothing is interpolated. A period with no data must render as
  a hole, because a confident zero where a KPI was not yet being measured is the
  most misleading thing a chart can draw.
  """

  alias AgentLens.Kpi.Definition
  alias AgentLens.Kpi.Registry
  alias AgentLens.Kpi.Status
  alias AgentLens.Repo
  alias AgentLens.Rollup
  alias AgentLens.Thresholds

  @default_max_points 300

  @typedoc "One plotted point."
  @type point :: %{
          at: DateTime.t(),
          value: float(),
          sample_n: non_neg_integer(),
          population_n: non_neg_integer()
        }

  @typedoc "A series ready to hand to a chart."
  @type series :: %{
          slug: atom(),
          granularity: Rollup.granularity() | nil,
          downsampled?: boolean(),
          points: [point()]
        }

  @doc """
  A KPI's series for one agent over a time range.

  ## Options

    * `:granularity` — force a grain instead of choosing by range
    * `:max_points` — point budget (default #{@default_max_points})
    * `:registry`, `:repo`
  """
  @spec series(String.t(), atom(), DateTime.t(), DateTime.t(), keyword()) :: series()
  def series(agent_id, kpi_slug, from, to, opts \\ []) do
    registry = registry(opts)

    case Registry.fetch_definition(registry, kpi_slug) do
      :error ->
        %{slug: kpi_slug, granularity: nil, downsampled?: false, points: []}

      {:ok, definition} ->
        build_series(agent_id, definition, from, to, opts)
    end
  end

  defp build_series(agent_id, definition, from, to, opts) do
    repo = Keyword.get(opts, :repo, Repo)
    max_points = Keyword.get(opts, :max_points, @default_max_points)

    granularity =
      Keyword.get_lazy(opts, :granularity, fn ->
        Rollup.granularity_for(from, to, max_points)
      end)

    stored = Rollup.bucket_count(from, to, granularity)

    if stored > max_points do
      group_seconds = group_seconds(from, to, granularity, max_points)

      %{
        slug: definition.slug,
        granularity: granularity,
        downsampled?: true,
        points:
          downsampled_points(repo, agent_id, definition, granularity, from, to, group_seconds)
      }
    else
      %{
        slug: definition.slug,
        granularity: granularity,
        downsampled?: false,
        points: exact_points(repo, agent_id, definition, granularity, from, to)
      }
    end
  end

  # Rounded up to a whole number of stored buckets, so a super-bucket never
  # splits one.
  defp group_seconds(from, to, granularity, max_points) do
    span = DateTime.diff(to, from)
    bucket = Rollup.seconds_per_bucket(granularity)

    span
    |> div(max(max_points, 1))
    |> max(bucket)
    |> Kernel./(bucket)
    |> ceil()
    |> Kernel.*(bucket)
  end

  defp exact_points(repo, agent_id, definition, granularity, from, to) do
    %{rows: rows} =
      repo.query!(
        """
        SELECT bucket_start, #{Rollup.value_expression(definition.aggregation)},
               sample_n, population_n
        FROM kpi_rollups
        WHERE agent_id = $1 AND kpi_slug = $2 AND granularity = $3
          AND bucket_start >= $4 AND bucket_start < $5
          AND count > 0
        ORDER BY bucket_start
        """,
        [agent_id, to_string(definition.slug), to_string(granularity), from, to]
      )

    to_points(rows)
  end

  defp downsampled_points(repo, agent_id, definition, granularity, from, to, group_seconds) do
    %{rows: rows} =
      repo.query!(
        """
        SELECT to_timestamp(floor(extract(epoch FROM bucket_start) / $6) * $6) AS at,
               #{Rollup.combine_expression(definition.aggregation)},
               sum(sample_n)::int, sum(population_n)::int
        FROM kpi_rollups
        WHERE agent_id = $1 AND kpi_slug = $2 AND granularity = $3
          AND bucket_start >= $4 AND bucket_start < $5
          AND count > 0
        GROUP BY 1
        ORDER BY 1
        """,
        [agent_id, to_string(definition.slug), to_string(granularity), from, to, group_seconds]
      )

    to_points(rows)
  end

  defp to_points(rows) do
    for [at, value, sample_n, population_n] <- rows, not is_nil(value) do
      %{
        at: at,
        value: value / 1,
        sample_n: sample_n || 0,
        population_n: population_n || 0
      }
    end
  end

  @doc """
  The most recent bucket for a KPI, with its evaluated status.

  Returns `:unknown` with a `nil` value when there is nothing to show — an
  unregistered KPI, no data yet, or a sample too small to trust.
  """
  @spec latest(String.t(), atom(), keyword()) :: map()
  def latest(agent_id, kpi_slug, opts \\ []) do
    registry = registry(opts)

    case Registry.fetch_definition(registry, kpi_slug) do
      :error -> unknown(kpi_slug, nil)
      {:ok, definition} -> latest_for(agent_id, definition, opts)
    end
  end

  defp latest_for(agent_id, definition, opts) do
    repo = Keyword.get(opts, :repo, Repo)

    # Per-agent overrides apply wherever status is judged, not only on the page
    # where they were entered.
    definition =
      Thresholds.apply_override(
        definition,
        Keyword.get_lazy(opts, :overrides, fn -> Thresholds.for_agent(agent_id, repo) end)
      )

    case newest_bucket(repo, agent_id, definition, preferred_grains(definition, opts)) do
      nil ->
        unknown(definition.slug, definition)

      {granularity, %{at: at, value: value, sample_n: sample_n} = bucket} ->
        raw = Status.evaluate(definition, value, sample_n: sample_n)

        %{
          slug: definition.slug,
          definition: definition,
          granularity: granularity,
          at: at,
          value: value,
          sample_n: sample_n,
          population_n: bucket.population_n,
          raw_status: raw,
          status: damped_status(agent_id, definition, granularity, raw, opts)
        }
    end
  end

  # Section 12's hysteresis: require several consecutive buckets past a
  # threshold before the badge moves.
  #
  # A KPI sitting on its boundary will otherwise flip on every refresh, and a
  # dashboard that flickers is one people stop reading — which costs far more
  # than being a bucket or two late to a genuine transition. Off unless the
  # caller asks, so the raw judgement is always available underneath.
  defp damped_status(agent_id, definition, granularity, raw, opts) do
    case Keyword.get(opts, :hysteresis) do
      nil ->
        raw

      required when is_integer(required) and required > 1 ->
        repo = Keyword.get(opts, :repo, Repo)
        window = Keyword.get(opts, :hysteresis_window, required * 4)

        agent_id
        |> recent_statuses(definition, granularity, window, repo)
        |> Status.stabilize(required)
        |> Kernel.||(raw)

      _one ->
        raw
    end
  end

  defp recent_statuses(agent_id, definition, granularity, limit, repo) do
    %{rows: rows} =
      repo.query!(
        """
        SELECT #{Rollup.value_expression(definition.aggregation)}, sample_n
        FROM kpi_rollups
        WHERE agent_id = $1 AND kpi_slug = $2 AND granularity = $3 AND count > 0
        ORDER BY bucket_start DESC
        LIMIT $4
        """,
        [agent_id, to_string(definition.slug), to_string(granularity), limit]
      )

    rows
    |> Enum.reverse()
    |> Enum.map(fn [value, sample_n] ->
      Status.evaluate(definition, value, sample_n: sample_n)
    end)
  end

  @doc """
  Events inside a window that changed what a KPI's numbers mean.

  A model swap or a bumped KPI version shifts the measurement itself, and on a
  chart that is indistinguishable from the agent genuinely changing behaviour.
  Marking them is what stops someone investigating a regression that never
  happened.

  The state already in force at the start of the window is not a change, so it
  is not annotated.
  """
  @spec annotations(String.t(), atom(), DateTime.t(), DateTime.t(), keyword()) :: [map()]
  def annotations(agent_id, kpi_slug, from, to, opts \\ []) do
    registry = registry(opts)

    case Registry.fetch_definition(registry, kpi_slug) do
      :error ->
        []

      {:ok, definition} ->
        repo = Keyword.get(opts, :repo, Repo)

        (model_changes(repo, agent_id, from, to) ++
           version_changes(repo, agent_id, definition, from, to))
        |> Enum.sort_by(& &1.at, DateTime)
    end
  end

  defp model_changes(repo, agent_id, from, to) do
    %{rows: rows} =
      repo.query!(
        """
        SELECT model, min(start_time)
        FROM runs
        WHERE agent_id = $1 AND start_time >= $2 AND start_time < $3 AND model IS NOT NULL
        GROUP BY model
        ORDER BY 2
        """,
        [agent_id, from, to]
      )

    rows
    |> Enum.drop(1)
    |> Enum.map(fn [model, at] -> %{at: at, label: "model → #{model}", kind: :model} end)
  end

  defp version_changes(repo, agent_id, definition, from, to) do
    %{rows: rows} =
      repo.query!(
        """
        SELECT kpi_version, min(occurred_at)
        FROM kpi_observations
        WHERE agent_id = $1 AND kpi_slug = $2 AND occurred_at >= $3 AND occurred_at < $4
        GROUP BY kpi_version
        ORDER BY 2
        """,
        [agent_id, to_string(definition.slug), from, to]
      )

    rows
    |> Enum.drop(1)
    |> Enum.map(fn [version, at] -> %{at: at, label: "v#{version}", kind: :version} end)
  end

  # A derived KPI only ever has day buckets; everything else is tried finest
  # first.
  defp preferred_grains(%Definition{kind: :derived}, _opts), do: [:day]

  defp preferred_grains(_definition, opts),
    do: Keyword.get(opts, :granularities, [:minute, :hour, :day])

  # Returns the finest grain whose newest bucket is *adequately sampled*, rather
  # than simply the finest that has any data.
  #
  # This matters more than it looks. At modest traffic an hour bucket can hold
  # fewer runs than a KPI's `min_sample_n`, so reading only the finest grain
  # would leave that card grey forever — never wrong, never useful. An
  # all-unknown dashboard teaches people to ignore it just as effectively as an
  # all-green one does.
  #
  # Falls back to the newest bucket at any grain when none is adequate, so the
  # card still shows the value and its honest `:unknown` status.
  defp newest_bucket(repo, agent_id, definition, grains) do
    candidates =
      for granularity <- grains,
          point = newest_at(repo, agent_id, definition, granularity),
          do: {granularity, point}

    Enum.find(candidates, List.first(candidates), fn {_granularity, point} ->
      point.sample_n >= definition.min_sample_n
    end)
  end

  defp newest_at(repo, agent_id, definition, granularity) do
    %{rows: rows} =
      repo.query!(
        """
        SELECT bucket_start, #{Rollup.value_expression(definition.aggregation)},
               sample_n, population_n
        FROM kpi_rollups
        WHERE agent_id = $1 AND kpi_slug = $2 AND granularity = $3 AND count > 0
        ORDER BY bucket_start DESC
        LIMIT 1
        """,
        [agent_id, to_string(definition.slug), to_string(granularity)]
      )

    case to_points(rows) do
      [point] -> point
      [] -> nil
    end
  end

  defp unknown(slug, definition) do
    %{
      slug: slug,
      definition: definition,
      granularity: nil,
      at: nil,
      value: nil,
      sample_n: 0,
      population_n: 0,
      raw_status: :unknown,
      status: :unknown
    }
  end

  @doc """
  Every KPI's current state for one agent, plus the agent's rolled-up status.

  Includes KPIs with no data at all, reported as `:unknown`. A KPI silently
  missing from a dashboard is indistinguishable from a healthy one.
  """
  @spec agent_summary(String.t(), keyword()) :: map()
  def agent_summary(agent_id, opts \\ []) do
    registry = registry(opts)

    # Loaded once for the whole summary rather than per KPI.
    overrides =
      Keyword.get_lazy(opts, :overrides, fn ->
        Thresholds.for_agent(agent_id, Keyword.get(opts, :repo, Repo))
      end)

    opts = Keyword.put(opts, :overrides, overrides)

    kpis =
      registry
      |> Registry.definitions()
      |> Enum.map(&latest_for(agent_id, &1, opts))

    contributions =
      for kpi <- kpis, not is_nil(kpi.definition), do: {kpi.definition, kpi.status}

    %{
      agent_id: agent_id,
      kpis: kpis,
      status: Status.roll_up(contributions),
      counts: count_by_status(kpis)
    }
  end

  defp count_by_status(kpis) do
    base = %{good: 0, warning: 0, critical: 0, unknown: 0}
    Enum.reduce(kpis, base, fn kpi, acc -> Map.update!(acc, kpi.status, &(&1 + 1)) end)
  end

  @doc """
  Summaries for every agent that has data, for the agent grid.

  Stamped with `computed_at` so a cached copy can be aged, and so the UI can say
  how fresh what it is showing actually is.
  """
  @spec overview(keyword()) :: map()
  def overview(opts \\ []) do
    %{
      agents: opts |> agent_ids() |> Enum.map(&agent_summary(&1, opts)),
      computed_at: DateTime.utc_now()
    }
  end

  @doc "Every agent that has produced a rollup."
  @spec agent_ids(keyword()) :: [String.t()]
  def agent_ids(opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    %{rows: rows} = repo.query!("SELECT DISTINCT agent_id FROM kpi_rollups ORDER BY 1")

    List.flatten(rows)
  end

  defp registry(opts), do: Keyword.get_lazy(opts, :registry, &Registry.load!/0)
end
