defmodule AgentLens.Rollup.DerivedTest do
  use AgentLens.DataCase, async: false

  alias AgentLens.Ingestion.RunImporter
  alias AgentLens.LangSmith.Mock
  alias AgentLens.Repo
  alias AgentLens.Rollup
  alias AgentLens.Rollup.Derived
  alias AgentLens.Store.KpiRollup

  @workspace "ws-support"
  @now ~U[2026-08-30 00:00:00.000000Z]

  # Short windows keep the fixture small while still giving the statistic more
  # than the 30 points per side it requires.
  @windows [current_days: 2, baseline_days: 5]

  defp day(offset), do: DateTime.add(Mock.epoch(@now), offset, :day)

  defp ingest(from_day, to_day) do
    {:ok, %{items: items}} =
      Mock.list_runs(@workspace,
        since: day(from_day),
        limit: (to_day - from_day) * 240 + 10,
        now: @now
      )

    keep = Enum.filter(items, &(DateTime.compare(&1["start_time"], day(to_day)) == :lt))
    {:ok, _} = RunImporter.import(@workspace, keep)

    {:ok, _} = Rollup.run!(:hour, day(from_day), day(to_day))
    :ok
  end

  defp drift_for(as_of_day) do
    {:ok, _written} = Derived.run!(day(as_of_day), @windows)

    Repo.one(
      from(r in KpiRollup,
        where:
          r.kpi_slug == "latency_drift" and
            r.bucket_start == ^Rollup.bucket_start(day(as_of_day), :day)
      )
    )
  end

  describe "run!/2" do
    setup do
      ingest(12, 21)
      :ok
    end

    test "writes a day-granularity bucket for the derived KPI" do
      rollup = drift_for(20)

      assert rollup.granularity == "day"
      assert rollup.kpi_slug == "latency_drift"
      assert rollup.agent_id == @workspace
    end

    # A derived value is a single number for the bucket, so every statistic
    # column carries it. Whatever the definition's aggregation asks for, the
    # read path gets the same right answer.
    test "stores the value across the statistic set" do
      rollup = drift_for(20)

      assert rollup.count == 1
      assert rollup.sum == rollup.p50
      assert rollup.p50 == rollup.p95
      assert rollup.min == rollup.max
    end

    test "records how many points each side of the comparison had" do
      rollup = drift_for(20)

      assert rollup.sample_n > 30
      assert rollup.population_n > 30
    end

    test "is idempotent" do
      _first = drift_for(20)
      before = Repo.aggregate(from(r in KpiRollup, where: r.kpi_slug == "latency_drift"), :count)

      _second = drift_for(20)

      assert Repo.aggregate(from(r in KpiRollup, where: r.kpi_slug == "latency_drift"), :count) ==
               before
    end

    test "does not touch the KPIs it derives from" do
      before = Repo.aggregate(from(r in KpiRollup, where: r.kpi_slug == "latency_p95"), :count)
      _rollup = drift_for(20)

      assert Repo.aggregate(from(r in KpiRollup, where: r.kpi_slug == "latency_p95"), :count) ==
               before
    end
  end

  # The payoff for the whole phase: the anomaly Phase 3 injected into the mock
  # is found here by a statistic that knows nothing about it.
  describe "detecting the injected latency spike" do
    setup do
      %{latency_spike: spike} = Mock.anomalies()
      ingest(spike.from_day - 9, spike.to_day)
      %{spike: spike}
    end

    test "drift is low while the distribution is stable", %{spike: spike} do
      quiet = drift_for(spike.from_day - 2)

      assert quiet.sum < 0.1, "expected no meaningful drift, got #{quiet.sum}"
    end

    test "drift is significant once the spike enters the current window", %{spike: spike} do
      spiked = drift_for(spike.from_day + 2)

      assert spiked.sum > 0.25,
             "expected significant drift during the spike, got #{spiked.sum}"
    end

    test "the spike reads as drift many times larger than the quiet baseline", %{spike: spike} do
      quiet = drift_for(spike.from_day - 2)
      spiked = drift_for(spike.from_day + 2)

      assert spiked.sum > quiet.sum * 10
    end

    # The status layer must agree with the statistic, using only the thresholds
    # the KPI module declared.
    test "the drift KPI evaluates as critical during the spike", %{spike: spike} do
      alias AgentLens.Kpi.Registry
      alias AgentLens.Kpi.Status

      {:ok, definition} = Registry.fetch_definition(Registry.load!(), :latency_drift)

      quiet = drift_for(spike.from_day - 2)
      spiked = drift_for(spike.from_day + 2)

      assert :good = Status.evaluate(definition, quiet.sum, sample_n: quiet.sample_n)
      assert :critical = Status.evaluate(definition, spiked.sum, sample_n: spiked.sample_n)
    end
  end

  describe "insufficient data" do
    test "skips rather than inventing a number when there is no history" do
      assert {:ok, 0} = Derived.run!(day(20), @windows)

      assert Repo.aggregate(from(r in KpiRollup, where: r.kpi_slug == "latency_drift"), :count) ==
               0
    end

    test "skips when the baseline is too short to bin" do
      ingest(18, 20)

      assert {:ok, 0} = Derived.run!(day(20), @windows)
    end
  end
end
