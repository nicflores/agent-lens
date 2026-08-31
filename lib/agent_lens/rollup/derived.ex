defmodule AgentLens.Rollup.Derived do
  @moduledoc """
  Computes `:derived` KPIs on bucket close, from other KPIs' rollups.

  This is the pass that turns the dashboard from a status board into something
  that notices a model update quietly degraded an agent. Absolute thresholds
  catch an agent that is broken; drift catches one that is getting worse while
  still nominally passing.

  ## Where the values are written

  Straight into `kpi_rollups`, not `kpi_observations`. A derived value is a
  property of a *bucket*, not of any single run — there is no run to attach it
  to, and `kpi_observations.source` is deliberately limited to the three ways a
  per-run value can arise. Every statistic column carries the single value, so
  whichever one the definition's `aggregation` names, the read path finds it.

  ## The comparison windows

  `current` is the trailing `:current_days`; `baseline` is the `:baseline_days`
  immediately preceding it, so the two never overlap. Both are read at hour
  granularity, which gives a distribution with enough points to be meaningful
  while still fitting inside the 90-day hour-bucket retention.

  ## Why the baseline excludes unhealthy periods

  A rolling baseline has an unpleasant property: once an incident scrolls out of
  the current window and into the reference window, current-versus-baseline
  diverges *again* — and the KPI reads critical for the whole length of the
  baseline after everything has already recovered. In testing, a four-day
  latency spike produced a PSI of 0.39 on a fully recovered system, and would
  have gone on doing so for a month.

  That is not a statistical error. PSI is faithfully reporting that the two
  distributions differ; the flaw is in asking it to treat a period we already
  know was broken as the definition of normal.

  So the baseline keeps only buckets in which the source KPI was inside its own
  thresholds, which is what a person would do by hand. `baseline_excluded`
  records how much was dropped. If too little healthy history survives, the KPI
  returns `:skip` and renders unknown, rather than comparing against a reference
  it cannot vouch for.
  """

  require Logger

  alias AgentLens.Kpi.Input
  alias AgentLens.Kpi.Registry
  alias AgentLens.Kpi.Thresholds
  alias AgentLens.Repo
  alias AgentLens.Rollup

  @default_current_days 7
  @default_baseline_days 30
  @source_granularity :hour

  @doc """
  Computes every derived KPI for every agent, for the day ending at `as_of`.

  Returns the number of buckets written. A KPI that returns `:skip` — too few
  points, no baseline — writes nothing at all, so the dashboard renders it
  unknown rather than showing a number derived from noise.

  ## Options

    * `:current_days` — length of the window being judged (default 7)
    * `:baseline_days` — length of the window it is compared against (default 30)
    * `:registry`, `:repo`
  """
  @spec run!(DateTime.t(), keyword()) :: {:ok, non_neg_integer()}
  def run!(as_of, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)
    registry = Keyword.get_lazy(opts, :registry, &Registry.load!/0)

    current_days = Keyword.get(opts, :current_days, @default_current_days)
    baseline_days = Keyword.get(opts, :baseline_days, @default_baseline_days)

    current_to = as_of
    current_from = DateTime.add(current_to, -current_days, :day)
    baseline_from = DateTime.add(current_from, -baseline_days, :day)

    derived = entries_of_kind(registry, :derived)
    agents = agents_with_data(repo, baseline_from, current_to)

    written =
      for entry <- derived, agent <- agents, reduce: 0 do
        acc ->
          window =
            build_window(repo, registry, agent, entry, {baseline_from, current_from, current_to})

          case entry.module.compute(window) do
            {:ok, value} -> acc + write(repo, entry, agent, as_of, value, window)
            {:ok, value, _metadata} -> acc + write(repo, entry, agent, as_of, value, window)
            :skip -> acc
          end
      end

    {:ok, written}
  end

  defp entries_of_kind(registry, kind) do
    registry
    |> Map.values()
    |> Enum.filter(&(&1.definition.kind == kind))
    |> Enum.sort_by(& &1.definition.slug)
  end

  defp agents_with_data(repo, from, to) do
    %{rows: rows} =
      repo.query!(
        """
        SELECT DISTINCT agent_id
        FROM kpi_rollups
        WHERE granularity = $1 AND bucket_start >= $2 AND bucket_start < $3
        ORDER BY 1
        """,
        [to_string(@source_granularity), from, to]
      )

    List.flatten(rows)
  end

  defp build_window(repo, registry, agent, entry, {baseline_from, current_from, current_to}) do
    sources = entry.module.depends_on()

    current =
      Map.new(sources, fn slug ->
        {slug, series(repo, registry, agent, slug, current_from, current_to)}
      end)

    {baseline, excluded} =
      Enum.reduce(sources, {%{}, %{}}, fn slug, {values, counts} ->
        observed = series(repo, registry, agent, slug, baseline_from, current_from)
        healthy = healthy_only(registry, slug, observed)

        {Map.put(values, slug, healthy),
         Map.put(counts, slug, length(observed) - length(healthy))}
      end)

    %Input.Window{
      agent_id: agent,
      bucket_start: current_from,
      bucket_end: current_to,
      granularity: @source_granularity,
      current: current,
      baseline: baseline,
      baseline_excluded: excluded
    }
  end

  # Keeps only the periods in which the source KPI was within its own
  # thresholds.
  #
  # Judged on thresholds alone, deliberately ignoring `min_sample_n`: the
  # question here is "was this period anomalous", not "is this bucket
  # individually trustworthy". A source bucket is far finer than the grain those
  # minimums were set for, so consulting them would discard the entire baseline.
  defp healthy_only(registry, slug, values) do
    case Registry.fetch_definition(registry, slug) do
      {:ok, definition} ->
        Enum.filter(values, fn value ->
          Thresholds.classify(definition.direction, definition.thresholds, value) == :good
        end)

      :error ->
        values
    end
  end

  # Reads whichever statistic the source KPI's `aggregation` names. That
  # indirection is why a derived KPI can depend on any other KPI without this
  # module knowing anything about either of them.
  defp series(repo, registry, agent, slug, from, to) do
    expression =
      case Registry.fetch_definition(registry, slug) do
        {:ok, definition} -> Rollup.value_expression(definition.aggregation)
        :error -> Rollup.value_expression(:mean)
      end

    %{rows: rows} =
      repo.query!(
        """
        SELECT #{expression}
        FROM kpi_rollups
        WHERE agent_id = $1 AND kpi_slug = $2 AND granularity = $3
          AND bucket_start >= $4 AND bucket_start < $5
          AND count > 0
        ORDER BY bucket_start
        """,
        [agent, to_string(slug), to_string(@source_granularity), from, to]
      )

    rows |> List.flatten() |> Enum.reject(&is_nil/1)
  end

  defp write(repo, entry, agent, as_of, value, window) do
    bucket = Rollup.bucket_start(as_of, :day)
    now = DateTime.utc_now()
    sources = entry.module.depends_on()

    sample_n = sources |> Enum.map(&length(Input.Window.current(window, &1))) |> Enum.sum()
    population_n = sources |> Enum.map(&length(Input.Window.baseline(window, &1))) |> Enum.sum()

    %{num_rows: rows} =
      repo.query!(
        """
        INSERT INTO kpi_rollups (
          agent_id, kpi_slug, granularity, bucket_start,
          count, sum, min, max, p50, p95, p99,
          sample_n, population_n, inserted_at, updated_at
        )
        VALUES ($1, $2, 'day', $3, 1, $4, $4, $4, $4, $4, $4, $5, $6, $7, $7)
        ON CONFLICT (agent_id, kpi_slug, granularity, bucket_start) DO UPDATE SET
          count = 1,
          sum = EXCLUDED.sum, min = EXCLUDED.min, max = EXCLUDED.max,
          p50 = EXCLUDED.p50, p95 = EXCLUDED.p95, p99 = EXCLUDED.p99,
          sample_n = EXCLUDED.sample_n,
          population_n = EXCLUDED.population_n,
          updated_at = EXCLUDED.updated_at
        """,
        [
          agent,
          Atom.to_string(entry.definition.slug),
          bucket,
          value,
          sample_n,
          population_n,
          now
        ]
      )

    rows
  end
end
