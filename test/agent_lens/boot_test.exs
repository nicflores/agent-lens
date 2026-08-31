defmodule AgentLens.BootTest do
  use AgentLens.DataCase, async: false

  alias AgentLens.Boot
  alias AgentLens.Partitions.Manager
  alias AgentLens.Repo
  alias AgentLens.Store.KpiDefinition

  describe "run/1" do
    test "syncs the KPI catalog" do
      assert :ok = Boot.run()
      assert Repo.aggregate(KpiDefinition, :count) == 5
    end

    test "creates partitions around today for every partitioned table" do
      assert :ok = Boot.run()

      assert Manager.list(:runs) != []
      assert Manager.list(:kpi_observations) != []
    end

    test "creates a partition covering today, so ingestion can start immediately" do
      assert :ok = Boot.run()

      today = DateTime.utc_now()

      assert Enum.any?(Manager.list(:runs), fn partition ->
               DateTime.compare(partition.from, today) != :gt and
                 DateTime.compare(partition.to, today) == :gt
             end)
    end

    test "is idempotent, since it runs on every boot" do
      assert :ok = Boot.run()
      before = Manager.list(:runs) |> length()

      assert :ok = Boot.run()

      assert Manager.list(:runs) |> length() == before
      assert Repo.aggregate(KpiDefinition, :count) == 5
    end

    # A bad KPI config must stop the application rather than let a worker
    # discover the problem later under load.
    test "refuses to run with an invalid registry" do
      assert_raise RuntimeError, ~r/invalid KPI configuration/, fn ->
        Boot.run(kpis: [Enum])
      end
    end
  end

  # The supervision tree must not proceed to the poller before partitions
  # exist, or ingestion would insert rows no partition covers. Doing the work
  # in init/1 is what guarantees that; a Task would return immediately and race.
  describe "start_link/1 is synchronous" do
    test "the work is already complete when start_link returns" do
      assert :ignore = Boot.start_link([])

      assert Repo.aggregate(KpiDefinition, :count) == 5
      assert Manager.list(:runs) != []
    end

    test "a boot failure propagates out of start_link rather than being swallowed" do
      # start_link links to us, and the raise in init/1 would take this test
      # process down with it — which is precisely the propagation being asserted.
      Process.flag(:trap_exit, true)

      assert {:error, {%RuntimeError{}, _stacktrace}} = Boot.start_link(kpis: [Enum])
    end
  end
end
