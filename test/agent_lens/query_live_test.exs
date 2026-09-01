defmodule AgentLens.QueryLiveTest do
  @moduledoc """
  The Phase 7 additions to the read path: damped status transitions and the
  annotations that stop a methodology change from reading as drift.
  """

  use AgentLens.DataCase, async: false

  alias AgentLens.Ingestion.RunImporter
  alias AgentLens.LangSmith.Mock
  alias AgentLens.Query
  alias AgentLens.Repo
  alias AgentLens.Rollup
  alias AgentLens.Store.KpiRollup

  @workspace "ws-support"
  @now ~U[2026-08-30 00:00:00.000000Z]

  defp bucket(offset_hours, value, sample_n \\ 100) do
    Repo.insert!(%KpiRollup{
      agent_id: @workspace,
      kpi_slug: "success_rate",
      granularity: "hour",
      bucket_start: DateTime.add(@now, offset_hours, :hour),
      count: sample_n,
      sum: value * sample_n,
      min: value,
      max: value,
      p50: value,
      p95: value,
      p99: value,
      sample_n: sample_n,
      population_n: sample_n,
      inserted_at: @now,
      updated_at: @now
    })
  end

  # A KPI flickering across its boundary teaches people to ignore the
  # dashboard, which costs more than being a bucket late.
  describe "latest/3 with hysteresis" do
    test "does not flip on a single bucket crossing the threshold" do
      for h <- -6..-1, do: bucket(h, 0.99)
      bucket(0, 0.80)

      reading = Query.latest(@workspace, :success_rate, granularities: [:hour], hysteresis: 3)

      assert reading.raw_status == :critical
      assert reading.status == :good
    end

    test "flips once the crossing is sustained" do
      for h <- -6..-4, do: bucket(h, 0.99)
      for h <- -3..0, do: bucket(h, 0.80)

      reading = Query.latest(@workspace, :success_rate, granularities: [:hour], hysteresis: 3)

      assert reading.status == :critical
    end

    test "damps an oscillation around the boundary" do
      values = [0.99, 0.80, 0.99, 0.80, 0.99, 0.80]

      values
      |> Enum.with_index()
      |> Enum.each(fn {value, index} -> bucket(index - 6, value) end)

      reading = Query.latest(@workspace, :success_rate, granularities: [:hour], hysteresis: 3)

      assert reading.status == :good
      assert reading.raw_status == :critical
    end

    test "reports the undamped status too, so the deep dive can show both" do
      for h <- -6..-1, do: bucket(h, 0.99)
      bucket(0, 0.80)

      reading = Query.latest(@workspace, :success_rate, granularities: [:hour], hysteresis: 3)

      assert reading.raw_status != reading.status
    end

    test "is off by default, so a caller opts into the delay" do
      for h <- -6..-1, do: bucket(h, 0.99)
      bucket(0, 0.80)

      reading = Query.latest(@workspace, :success_rate, granularities: [:hour])

      assert reading.status == :critical
    end
  end

  # An unannotated methodology change looks exactly like real drift, and
  # someone will spend a day chasing it.
  describe "annotations/4" do
    setup do
      %{toxicity_regression: regression} = Mock.anomalies()
      epoch = Mock.epoch(@now)

      {:ok, %{items: runs}} =
        Mock.list_runs(@workspace,
          since: DateTime.add(epoch, regression.from_day - 3, :day),
          limit: 1_600,
          now: @now
        )

      {:ok, _} = RunImporter.import(@workspace, runs)
      {:ok, _} = Rollup.run!(:hour, DateTime.add(epoch, regression.from_day - 3, :day), @now)

      %{epoch: epoch, regression: regression}
    end

    test "marks where the model changed underneath the KPI", %{epoch: epoch, regression: r} do
      from = DateTime.add(epoch, r.from_day - 3, :day)

      annotations = Query.annotations(@workspace, :latency_p95, from, @now)

      assert Enum.any?(annotations, &(&1.label =~ r.model_after))
    end

    test "does not annotate the model already in use at the start of the window",
         %{epoch: epoch, regression: r} do
      from = DateTime.add(epoch, r.from_day - 3, :day)

      annotations = Query.annotations(@workspace, :latency_p95, from, @now)

      refute Enum.any?(annotations, &(&1.label =~ r.model_before))
    end

    test "places the mark at the change, not at the window edge", %{epoch: epoch, regression: r} do
      from = DateTime.add(epoch, r.from_day - 3, :day)
      changeover = DateTime.add(epoch, r.from_day, :day)

      [annotation | _] = Query.annotations(@workspace, :latency_p95, from, @now)

      assert abs(DateTime.diff(annotation.at, changeover)) < 3_600
    end

    test "returns nothing when nothing changed", %{epoch: epoch, regression: r} do
      from = DateTime.add(epoch, r.from_day - 3, :day)
      to = DateTime.add(epoch, r.from_day - 1, :day)

      assert [] = Query.annotations(@workspace, :latency_p95, from, to)
    end

    test "is empty for an unregistered KPI rather than raising" do
      assert [] = Query.annotations(@workspace, :no_such_kpi, DateTime.add(@now, -1, :day), @now)
    end
  end
end
