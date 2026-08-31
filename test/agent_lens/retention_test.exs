defmodule AgentLens.RetentionTest do
  use AgentLens.DataCase, async: false

  alias AgentLens.Partitions.Manager
  alias AgentLens.Repo
  alias AgentLens.Retention
  alias AgentLens.Store.KpiRollup
  alias AgentLens.Store.Run

  @now ~U[2026-08-30 00:00:00.000000Z]

  defp insert_run(start_time, payload \\ %{"outputs" => %{"text" => "kept"}}) do
    :ok = Manager.ensure_range!(:runs, start_time, start_time)

    Repo.insert!(%Run{
      langsmith_run_id: "run-#{System.unique_integer([:positive])}",
      agent_id: "ws-support",
      start_time: start_time,
      status: "success",
      payload: payload,
      inserted_at: @now,
      updated_at: @now
    })
  end

  defp insert_rollup(granularity, bucket_start) do
    Repo.insert!(%KpiRollup{
      agent_id: "ws-support",
      kpi_slug: "success_rate",
      granularity: granularity,
      bucket_start: bucket_start,
      count: 1,
      sum: 1.0,
      sample_n: 1,
      population_n: 1,
      inserted_at: @now,
      updated_at: @now
    })
  end

  defp days_ago(n), do: DateTime.add(@now, -n, :day)

  describe "dropping expired partitions" do
    test "drops run partitions past the retention window" do
      insert_run(days_ago(120))
      insert_run(days_ago(5))

      assert %{runs: dropped} = Retention.run!(now: @now)
      assert dropped != []

      assert Repo.aggregate(Run, :count) == 1
    end

    test "keeps partitions inside the window" do
      insert_run(days_ago(5))

      _result = Retention.run!(now: @now)

      assert Repo.aggregate(Run, :count) == 1
    end

    # Section 8: retention is DROP PARTITION, not DELETE. A partition is only
    # dropped once its entire range is past the cutoff, so the bucket straddling
    # the boundary survives with its rows intact.
    test "does not drop the partition straddling the cutoff" do
      insert_run(days_ago(89))

      _result = Retention.run!(now: @now, runs_days: 90)

      assert Repo.aggregate(Run, :count) == 1
    end
  end

  describe "purging payloads" do
    # Payloads are retained on a shorter clock than the rows. The flattened
    # columns stay queryable while the bulky jsonb goes.
    test "empties payloads older than the payload window but keeps the rows" do
      old = insert_run(days_ago(60))
      recent = insert_run(days_ago(5))

      _result = Retention.run!(now: @now, payload_days: 30, runs_days: 90)

      assert Repo.get_by(Run, langsmith_run_id: old.langsmith_run_id).payload == %{}
      assert Repo.get_by(Run, langsmith_run_id: recent.langsmith_run_id).payload != %{}
    end

    test "leaves the row queryable after its payload is purged" do
      old = insert_run(days_ago(60))

      _result = Retention.run!(now: @now, payload_days: 30, runs_days: 90)

      kept = Repo.get_by(Run, langsmith_run_id: old.langsmith_run_id)
      assert kept.status == "success"
      assert kept.agent_id == "ws-support"
    end

    test "reports how many payloads it purged" do
      insert_run(days_ago(60))
      insert_run(days_ago(61))

      assert %{payloads_purged: 2} = Retention.run!(now: @now, payload_days: 30, runs_days: 90)
    end
  end

  describe "expiring rollups by tier" do
    test "keeps each grain for its own retention" do
      insert_rollup("minute", days_ago(30))
      insert_rollup("hour", days_ago(30))
      insert_rollup("day", days_ago(30))

      _result = Retention.run!(now: @now)

      grains = Repo.all(from(r in KpiRollup, select: r.granularity)) |> Enum.sort()
      assert grains == ["day", "hour"]
    end

    test "expires hour buckets past ninety days but keeps day buckets" do
      insert_rollup("hour", days_ago(200))
      insert_rollup("day", days_ago(200))

      _result = Retention.run!(now: @now)

      assert Repo.all(from(r in KpiRollup, select: r.granularity)) == ["day"]
    end

    test "expires day buckets past two years" do
      insert_rollup("day", days_ago(800))

      _result = Retention.run!(now: @now)

      assert Repo.aggregate(KpiRollup, :count) == 0
    end

    test "reports how many buckets it expired" do
      insert_rollup("minute", days_ago(30))
      insert_rollup("minute", days_ago(31))

      assert %{rollups_expired: 2} = Retention.run!(now: @now)
    end
  end

  describe "idempotency" do
    test "a second run has nothing left to do" do
      insert_run(days_ago(120))
      insert_rollup("minute", days_ago(30))

      _first = Retention.run!(now: @now)
      second = Retention.run!(now: @now)

      assert second.runs == []
      assert second.rollups_expired == 0
      assert second.payloads_purged == 0
    end
  end
end
