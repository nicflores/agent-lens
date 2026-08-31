defmodule AgentLens.QueryTest do
  use AgentLens.DataCase, async: false

  alias AgentLens.Ingestion.FeedbackImporter
  alias AgentLens.Ingestion.RunImporter
  alias AgentLens.LangSmith.Mock
  alias AgentLens.Query
  alias AgentLens.Repo
  alias AgentLens.Rollup
  alias AgentLens.Store.KpiRollup

  @workspace "ws-support"
  @now ~U[2026-08-30 00:00:00.000000Z]

  setup do
    since = DateTime.add(@now, -6, :day)

    {:ok, %{items: runs}} = Mock.list_runs(@workspace, since: since, limit: 1_500, now: @now)
    {:ok, _} = RunImporter.import(@workspace, runs)

    {:ok, %{items: feedback}} =
      Mock.list_feedback(@workspace, since: since, limit: 1_500, now: @now)

    {:ok, _} = FeedbackImporter.import(@workspace, feedback)

    for granularity <- [:hour, :day] do
      {:ok, _} = Rollup.run!(granularity, since, @now)
    end

    %{from: since, to: @now}
  end

  describe "series/5" do
    test "returns points from rollups", %{from: from, to: to} do
      series = Query.series(@workspace, :latency_p95, from, to)

      assert series.points != []
      assert %{at: %DateTime{}, value: value} = hd(series.points)
      assert is_float(value)
    end

    test "reports the granularity it served", %{from: from, to: to} do
      series = Query.series(@workspace, :latency_p95, from, to)

      assert series.granularity in [:minute, :hour, :day]
    end

    test "returns points in chronological order", %{from: from, to: to} do
      series = Query.series(@workspace, :latency_p95, from, to)
      times = Enum.map(series.points, & &1.at)

      assert times == Enum.sort(times, DateTime)
    end

    test "carries sample adequacy alongside each point", %{from: from, to: to} do
      series = Query.series(@workspace, :toxicity, from, to)

      assert Enum.all?(series.points, &is_integer(&1.sample_n))
      assert Enum.all?(series.points, &is_integer(&1.population_n))
    end

    # Section 5: the definition's aggregation names the column, so the read path
    # never branches on which KPI it is serving.
    test "reads the statistic the KPI declared", %{from: from, to: to} do
      latency = Query.series(@workspace, :latency_p95, from, to, granularity: :hour)

      bucket =
        Repo.one(
          from(r in KpiRollup,
            where:
              r.kpi_slug == "latency_p95" and r.granularity == "hour" and
                r.bucket_start == ^hd(latency.points).at
          )
        )

      assert hd(latency.points).value == bucket.p95
    end

    test "a rate KPI reads as sum over count", %{from: from, to: to} do
      series = Query.series(@workspace, :success_rate, from, to, granularity: :hour)

      bucket =
        Repo.one(
          from(r in KpiRollup,
            where:
              r.kpi_slug == "success_rate" and r.granularity == "hour" and
                r.bucket_start == ^hd(series.points).at
          )
        )

      assert_in_delta hd(series.points).value, bucket.sum / bucket.count, 0.0001
    end

    test "an unknown KPI returns an empty series rather than raising", %{from: from, to: to} do
      assert %{points: []} = Query.series(@workspace, :no_such_kpi, from, to)
    end

    test "an agent with no data returns an empty series", %{from: from, to: to} do
      assert %{points: []} = Query.series("ws-nonexistent", :latency_p95, from, to)
    end
  end

  # Section 6: whatever a backfill cannot reach is genuinely absent, and the
  # chart must show a gap rather than a confident zero.
  describe "gaps are gaps" do
    test "does not fill missing buckets with zeros", %{from: from, to: to} do
      Repo.delete_all(
        from(r in KpiRollup,
          where:
            r.kpi_slug == "latency_p95" and r.granularity == "hour" and
              r.bucket_start >= ^DateTime.add(from, 1, :day) and
              r.bucket_start < ^DateTime.add(from, 2, :day)
        )
      )

      series = Query.series(@workspace, :latency_p95, from, to, granularity: :hour)

      refute Enum.any?(series.points, &(&1.value == 0.0))

      gap_points =
        Enum.filter(series.points, fn point ->
          DateTime.compare(point.at, DateTime.add(from, 1, :day)) != :lt and
            DateTime.compare(point.at, DateTime.add(from, 2, :day)) == :lt
        end)

      assert gap_points == []
    end
  end

  describe "the point cap" do
    test "keeps a long range within the cap", %{to: to} do
      from = DateTime.add(to, -730, :day)
      series = Query.series(@workspace, :latency_p95, from, to, max_points: 100)

      assert length(series.points) <= 100
    end

    test "reports when it had to re-aggregate to fit", %{to: to} do
      from = DateTime.add(to, -730, :day)
      series = Query.series(@workspace, :latency_p95, from, to, max_points: 10)

      assert series.downsampled?
    end

    test "does not re-aggregate when the range already fits", %{from: from, to: to} do
      series = Query.series(@workspace, :latency_p95, from, to, max_points: 5_000)

      refute series.downsampled?
    end

    # Combining buckets has to respect what the statistic means: a rate is a
    # weighted mean of its parts, and counts add.
    test "re-aggregates a rate as a weighted mean, not a mean of means", %{from: from, to: to} do
      full = Query.series(@workspace, :success_rate, from, to, granularity: :hour)
      squeezed = Query.series(@workspace, :success_rate, from, to, max_points: 3)

      full_mean =
        Enum.sum(Enum.map(full.points, &(&1.value * &1.sample_n))) /
          Enum.sum(Enum.map(full.points, & &1.sample_n))

      squeezed_mean =
        Enum.sum(Enum.map(squeezed.points, &(&1.value * &1.sample_n))) /
          Enum.sum(Enum.map(squeezed.points, & &1.sample_n))

      assert_in_delta full_mean, squeezed_mean, 0.001
    end
  end

  describe "latest/3" do
    test "returns the most recent bucket with its status" do
      assert %{value: value, status: status} = Query.latest(@workspace, :success_rate)

      assert is_float(value)
      assert status in [:good, :warning, :critical, :unknown]
    end

    test "returns unknown for a KPI with no data" do
      assert %{value: nil, status: :unknown} = Query.latest(@workspace, :no_such_kpi)
    end

    # An hour bucket at this traffic rate holds ~10 runs, below success_rate's
    # minimum of 20. Reading only the finest grain would leave the card
    # permanently grey — which misinforms exactly as much as a false green.
    test "falls back to a coarser grain when the finest is too thinly sampled" do
      latest = Query.latest(@workspace, :success_rate)

      assert latest.status != :unknown
      assert latest.granularity == :day
      assert latest.sample_n >= latest.definition.min_sample_n
    end

    test "prefers the finest grain that is adequately sampled" do
      latest = Query.latest(@workspace, :success_rate)
      coarser = Query.latest(@workspace, :success_rate, granularities: [:day])

      # Both land on day here, but the point is it stopped as soon as the
      # sample was trustworthy rather than always jumping to the coarsest.
      assert latest.granularity == coarser.granularity
    end

    test "reports the granularity it settled on, so the UI can say so" do
      assert %{granularity: granularity} = Query.latest(@workspace, :latency_p95)
      assert granularity in [:minute, :hour, :day]
    end

    # A sampled KPI below its minimum must render grey, never green.
    test "reports unknown when the sample is too small" do
      Repo.update_all(
        from(r in KpiRollup, where: r.kpi_slug == "toxicity"),
        set: [sample_n: 1]
      )

      assert %{status: :unknown} = Query.latest(@workspace, :toxicity)
    end
  end

  describe "agent_summary/2" do
    test "covers every registered KPI, including ones with no data" do
      summary = Query.agent_summary(@workspace)

      slugs = summary.kpis |> Enum.map(& &1.slug) |> Enum.sort()
      assert slugs == [:latency_drift, :latency_p95, :sentiment, :success_rate, :toxicity]
    end

    test "carries the definition so the UI needs no lookup of its own" do
      summary = Query.agent_summary(@workspace)
      kpi = Enum.find(summary.kpis, &(&1.slug == :latency_p95))

      assert kpi.definition.name == "Latency p95"
      assert kpi.definition.unit == :ms
    end

    test "rolls the agent up to its worst contributing status" do
      summary = Query.agent_summary(@workspace)

      assert summary.status in [:good, :warning, :critical, :unknown]
    end

    test "counts how many KPIs are in each state" do
      summary = Query.agent_summary(@workspace)

      assert is_map(summary.counts)
      assert Map.keys(summary.counts) |> Enum.sort() == [:critical, :good, :unknown, :warning]
    end
  end

  describe "overview/1" do
    test "summarises every agent that has data" do
      overview = Query.overview()

      assert Enum.any?(overview.agents, &(&1.agent_id == @workspace))
    end

    test "is stamped so a cached copy can be aged" do
      overview = Query.overview()

      assert %DateTime{} = overview.computed_at
    end
  end
end
