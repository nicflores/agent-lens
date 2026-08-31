defmodule AgentLens.RollupTest do
  use AgentLens.DataCase, async: false

  alias AgentLens.Ingestion.FeedbackImporter
  alias AgentLens.Ingestion.RunImporter
  alias AgentLens.LangSmith.Mock
  alias AgentLens.Repo
  alias AgentLens.Rollup
  alias AgentLens.Store.KpiRollup
  alias AgentLens.Store.Run

  @workspace "ws-support"
  @now ~U[2026-08-30 00:00:00.000000Z]

  describe "bucket_start/2" do
    test "truncates to the minute" do
      assert ~U[2026-08-30 13:45:00.000000Z] =
               Rollup.bucket_start(~U[2026-08-30 13:45:37.123456Z], :minute)
    end

    test "truncates to the hour" do
      assert ~U[2026-08-30 13:00:00.000000Z] =
               Rollup.bucket_start(~U[2026-08-30 13:45:37.123456Z], :hour)
    end

    test "truncates to the day" do
      assert ~U[2026-08-30 00:00:00.000000Z] =
               Rollup.bucket_start(~U[2026-08-30 13:45:37.123456Z], :day)
    end
  end

  describe "tiers/0" do
    test "keeps fine grains briefly and coarse grains for years" do
      tiers = Rollup.tiers()

      assert tiers[:minute].retain_days < tiers[:hour].retain_days
      assert tiers[:hour].retain_days < tiers[:day].retain_days
    end
  end

  # Section 11: granularity follows the time range, and every chart is capped
  # at roughly 300 points, so query cost is bounded regardless of what the user
  # picks.
  describe "granularity_for/3" do
    # 1,440 minute points is five times the cap, so a day resolves to hour
    # buckets. Serving genuine minute resolution for 24h means re-aggregating
    # minute buckets on read, not picking a finer tier here.
    test "serves a day-long range from hour buckets at the default cap" do
      assert :hour = Rollup.granularity_for(~U[2026-08-29 00:00:00Z], ~U[2026-08-30 00:00:00Z])
    end

    test "serves a day from minute buckets when the caller allows more points" do
      assert :minute =
               Rollup.granularity_for(~U[2026-08-29 00:00:00Z], ~U[2026-08-30 00:00:00Z], 1_500)
    end

    test "serves a week from hour buckets" do
      assert :hour = Rollup.granularity_for(~U[2026-08-23 00:00:00Z], ~U[2026-08-30 00:00:00Z])
    end

    test "serves a quarter from day buckets" do
      assert :day = Rollup.granularity_for(~U[2026-06-01 00:00:00Z], ~U[2026-08-30 00:00:00Z])
    end

    test "picks the finest grain that fits the cap" do
      for days <- [1, 7, 30, 90] do
        to = ~U[2026-08-30 00:00:00Z]
        from = DateTime.add(to, -days, :day)
        granularity = Rollup.granularity_for(from, to, 300)

        assert Rollup.bucket_count(from, to, granularity) <= 300,
               "#{days}d at #{granularity} exceeds the cap"
      end
    end

    # Past roughly 300 days there is no coarser tier to escape to, so the cap
    # gives way rather than the data.
    test "falls back to the coarsest grain beyond the cap's reach" do
      to = ~U[2026-08-30 00:00:00Z]
      from = DateTime.add(to, -730, :day)

      assert :day = Rollup.granularity_for(from, to, 300)
      assert Rollup.bucket_count(from, to, :day) == 730
    end
  end

  describe "run!/4" do
    setup do
      {:ok, %{items: runs}} =
        Mock.list_runs(@workspace, since: Mock.epoch(@now), limit: 400, now: @now)

      {:ok, _} = RunImporter.import(@workspace, runs)

      from = runs |> Enum.map(& &1["start_time"]) |> Enum.min(DateTime)
      to = runs |> Enum.map(& &1["start_time"]) |> Enum.max(DateTime) |> DateTime.add(1, :hour)

      %{from: from, to: to}
    end

    test "writes buckets for every KPI present", %{from: from, to: to} do
      assert {:ok, written} = Rollup.run!(:hour, from, to)
      assert written > 0

      slugs = Repo.all(from(r in KpiRollup, select: r.kpi_slug, distinct: true)) |> Enum.sort()
      assert slugs == ["latency_p95", "success_rate"]
    end

    test "computes the whole statistic set, not just one aggregation", %{from: from, to: to} do
      {:ok, _} = Rollup.run!(:hour, from, to)

      rollup = Repo.one(from(r in KpiRollup, where: r.kpi_slug == "latency_p95", limit: 1))

      assert rollup.count > 0
      assert rollup.sum > 0
      assert rollup.min <= rollup.p50
      assert rollup.p50 <= rollup.p95
      assert rollup.p95 <= rollup.p99
      assert rollup.p99 <= rollup.max
      assert rollup.distinct_count > 0
    end

    test "stamps the granularity it was computed at", %{from: from, to: to} do
      {:ok, _} = Rollup.run!(:hour, from, to)

      assert Repo.all(from(r in KpiRollup, select: r.granularity, distinct: true)) == ["hour"]
    end

    test "buckets are aligned to the granularity", %{from: from, to: to} do
      {:ok, _} = Rollup.run!(:hour, from, to)

      for start <- Repo.all(from(r in KpiRollup, select: r.bucket_start)) do
        assert start.minute == 0
        assert start.second == 0
      end
    end

    test "is idempotent", %{from: from, to: to} do
      {:ok, first} = Rollup.run!(:hour, from, to)
      {:ok, second} = Rollup.run!(:hour, from, to)

      assert first == second
      assert Repo.aggregate(KpiRollup, :count) == first
    end

    test "recomputes rather than accumulating when observations change", %{from: from, to: to} do
      {:ok, _} = Rollup.run!(:hour, from, to)
      before = Repo.one(from(r in KpiRollup, where: r.kpi_slug == "success_rate", limit: 1))

      {:ok, _} = Rollup.run!(:hour, from, to)
      after_rerun = Repo.one(from(r in KpiRollup, where: r.kpi_slug == "success_rate", limit: 1))

      assert before.count == after_rerun.count
      assert before.sum == after_rerun.sum
    end

    test "computes several granularities independently", %{from: from, to: to} do
      {:ok, hours} = Rollup.run!(:hour, from, to)
      {:ok, days} = Rollup.run!(:day, from, to)

      assert days < hours
      assert Repo.aggregate(KpiRollup, :count) == hours + days
    end

    test "ignores observations outside the window", %{from: from} do
      narrow_to = DateTime.add(from, 1, :hour)
      {:ok, _} = Rollup.run!(:hour, from, narrow_to)

      for start <- Repo.all(from(r in KpiRollup, select: r.bucket_start)) do
        assert DateTime.compare(start, narrow_to) == :lt
      end
    end
  end

  # Section 7: a toxicity score from 3 judged runs must not render identically
  # to one from 400, so the bucket has to carry both numbers.
  describe "sample_n versus population_n" do
    setup do
      {:ok, %{items: runs}} =
        Mock.list_runs(@workspace, since: Mock.epoch(@now), limit: 400, now: @now)

      {:ok, _} = RunImporter.import(@workspace, runs)

      {:ok, %{items: feedback}} =
        Mock.list_feedback(@workspace, since: Mock.epoch(@now), limit: 400, now: @now)

      {:ok, _} = FeedbackImporter.import(@workspace, feedback)

      from = runs |> Enum.map(& &1["start_time"]) |> Enum.min(DateTime)
      to = runs |> Enum.map(& &1["start_time"]) |> Enum.max(DateTime) |> DateTime.add(1, :hour)

      {:ok, _} = Rollup.run!(:day, from, to)
      :ok
    end

    test "an exhaustive KPI has sample_n equal to the run population" do
      rollup = Repo.one(from(r in KpiRollup, where: r.kpi_slug == "success_rate", limit: 1))

      assert rollup.sample_n == rollup.population_n
    end

    test "a sampled KPI has sample_n well below the population" do
      rollup = Repo.one(from(r in KpiRollup, where: r.kpi_slug == "toxicity", limit: 1))

      assert rollup.sample_n > 0
      assert rollup.sample_n < rollup.population_n
    end

    test "population_n counts runs, not observations" do
      runs_in_bucket =
        Repo.one(
          from(r in Run,
            where: fragment("date_trunc('day', ?)", r.start_time) == ^~U[2026-06-02 00:00:00Z],
            select: count()
          )
        )

      rollup =
        Repo.one(
          from(r in KpiRollup,
            where: r.kpi_slug == "success_rate" and r.bucket_start == ^~U[2026-06-02 00:00:00Z]
          )
        )

      assert rollup.population_n == runs_in_bucket
    end
  end
end
