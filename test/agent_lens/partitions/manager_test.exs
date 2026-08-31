defmodule AgentLens.Partitions.ManagerTest do
  use AgentLens.DataCase, async: false

  alias AgentLens.Partitions
  alias AgentLens.Partitions.Manager
  alias AgentLens.Repo

  defp insert_run(start_time) do
    Repo.query!(
      """
      INSERT INTO runs (langsmith_run_id, agent_id, start_time, status)
      VALUES ($1, $2, $3, 'success')
      """,
      ["run-#{System.unique_integer([:positive])}", "ws-support", start_time]
    )
  end

  describe "ensure!/1" do
    test "creates the partition for a given date" do
      spec = Partitions.spec(:runs, ~D[2026-08-31])
      assert :ok = Manager.ensure!(spec)

      assert spec.name in Enum.map(Manager.list(:runs), & &1.name)
    end

    test "is idempotent, so a boot-time sweep can run every time" do
      spec = Partitions.spec(:runs, ~D[2026-08-31])

      assert :ok = Manager.ensure!(spec)
      assert :ok = Manager.ensure!(spec)

      names = Manager.list(:runs) |> Enum.map(& &1.name) |> Enum.filter(&(&1 == spec.name))
      assert length(names) == 1
    end

    test "reports the bounds it was created with" do
      spec = Partitions.spec(:kpi_observations, ~D[2026-08-15])
      :ok = Manager.ensure!(spec)

      found = Manager.list(:kpi_observations) |> Enum.find(&(&1.name == spec.name))

      assert DateTime.compare(found.from, spec.from) == :eq
      assert DateTime.compare(found.to, spec.to) == :eq
    end
  end

  describe "ensure_range!/3" do
    test "creates every partition covering the range" do
      assert :ok = Manager.ensure_range!(:runs, ~D[2026-08-31], ~D[2026-09-14])

      names = Manager.list(:runs) |> Enum.map(& &1.name)

      for expected <- ["runs_2026w36", "runs_2026w37", "runs_2026w38"] do
        assert expected in names
      end
    end
  end

  describe "routing rows into partitions" do
    test "a run lands in the partition covering its start_time" do
      :ok = Manager.ensure_range!(:runs, ~D[2026-08-31], ~D[2026-08-31])

      insert_run(~U[2026-09-02 12:00:00Z])

      %{rows: [[count]]} = Repo.query!("SELECT count(*) FROM runs_2026w36")
      assert count == 1
    end

    # Without a matching partition Postgres refuses the insert outright. This is
    # why the partition sweep must run ahead of ingestion, not alongside it.
    test "a run with no covering partition is rejected rather than silently dropped" do
      assert_raise Postgrex.Error, ~r/no partition of relation/, fn ->
        insert_run(~U[2031-01-01 12:00:00Z])
      end
    end
  end

  describe "drop_before!/2" do
    setup do
      :ok = Manager.ensure_range!(:runs, ~D[2026-08-03], ~D[2026-09-14])
      :ok
    end

    test "drops partitions that end at or before the cutoff" do
      dropped = Manager.drop_before!(:runs, ~D[2026-08-31])

      assert "runs_2026w32" in dropped
      refute "runs_2026w36" in dropped
    end

    test "leaves the retained partitions in place" do
      _dropped = Manager.drop_before!(:runs, ~D[2026-08-31])
      names = Manager.list(:runs) |> Enum.map(& &1.name)

      assert "runs_2026w36" in names
      refute "runs_2026w32" in names
    end

    # Retention is DROP PARTITION rather than DELETE. Dropping the table takes
    # the rows and their index entries with it in constant time.
    test "removes the dropped partition's rows" do
      insert_run(~U[2026-08-05 12:00:00Z])
      insert_run(~U[2026-09-02 12:00:00Z])

      _dropped = Manager.drop_before!(:runs, ~D[2026-08-31])

      %{rows: [[count]]} = Repo.query!("SELECT count(*) FROM runs")
      assert count == 1
    end

    test "is a no-op when nothing is old enough" do
      assert [] = Manager.drop_before!(:runs, ~D[2026-01-01])
    end
  end
end
