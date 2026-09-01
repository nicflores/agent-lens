defmodule AgentLens.BroadcasterTest do
  use AgentLens.DataCase, async: false

  alias AgentLens.Broadcaster
  alias AgentLens.Cache
  alias AgentLens.Ingestion.RunImporter
  alias AgentLens.LangSmith.Mock
  alias AgentLens.Repo
  alias AgentLens.Rollup
  alias AgentLens.Store.KpiRollup

  @workspace "ws-support"
  @now ~U[2026-08-30 00:00:00.000000Z]

  defp flush do
    receive do
      _message -> flush()
    after
      0 -> :ok
    end
  end

  setup do
    Cache.clear()

    since = DateTime.add(@now, -2, :day)
    {:ok, %{items: runs}} = Mock.list_runs(@workspace, since: since, limit: 400, now: @now)
    {:ok, _} = RunImporter.import(@workspace, runs)
    {:ok, _} = Rollup.run!(:hour, since, @now)

    :ok
  end

  describe "refresh/1" do
    test "computes the overview and caches it" do
      assert {:ok, overview} = Broadcaster.refresh()

      assert Enum.any?(overview.agents, &(&1.agent_id == @workspace))
      assert {:ok, ^overview} = Cache.fetch(:overview)
    end

    test "caches a per-agent summary too" do
      {:ok, _} = Broadcaster.refresh()

      assert {:ok, summary} = Cache.fetch({:agent, @workspace})
      assert summary.agent_id == @workspace
    end
  end

  # Section 11: one writer, N readers. Twenty open dashboards must cost what one
  # costs, which means a mount reads the cache and never the database.
  describe "reads are served from cache" do
    test "overview/0 returns the cached copy without querying" do
      {:ok, _} = Broadcaster.refresh()

      # Remove the underlying data. A cached read must still succeed, which it
      # could not do if it were querying.
      Repo.delete_all(KpiRollup)

      assert %{agents: [_ | _]} = Broadcaster.overview()
    end

    test "agent_summary/1 is served from cache" do
      {:ok, _} = Broadcaster.refresh()
      Repo.delete_all(KpiRollup)

      assert %{agent_id: @workspace} = Broadcaster.agent_summary(@workspace)
    end

    test "falls back to querying when nothing is cached yet" do
      Cache.clear()

      assert %{agents: _} = Broadcaster.overview()
    end
  end

  describe "publishing" do
    test "notifies subscribers when the overview changes" do
      :ok = Broadcaster.subscribe(:overview)

      {:ok, _} = Broadcaster.refresh()

      assert_receive {:overview_updated, %{agents: _}}, 1_000
    end

    test "notifies per-agent subscribers" do
      :ok = Broadcaster.subscribe({:agent, @workspace})

      {:ok, _} = Broadcaster.refresh()

      assert_receive {:agent_updated, %{agent_id: @workspace}}, 1_000
    end

    test "does not deliver another agent's updates" do
      :ok = Broadcaster.subscribe({:agent, "ws-somewhere-else"})

      {:ok, _} = Broadcaster.refresh()

      refute_receive {:agent_updated, _}, 200
    end

    # Section 11 again, from the writer's side: a refresh that changes nothing
    # must put nothing on the wire.
    test "publishes a per-KPI point when one changes" do
      :ok = Broadcaster.subscribe({:kpi, @workspace, :latency_p95})

      {:ok, _} = Broadcaster.refresh()

      Repo.update_all(
        from(r in KpiRollup, where: r.kpi_slug == "latency_p95"),
        set: [p95: 9_999.0]
      )

      {:ok, _} = Broadcaster.refresh()

      assert_receive {:kpi_point, @workspace, :latency_p95, %{value: 9_999.0}}, 1_000
    end

    test "says nothing when a refresh changes nothing" do
      :ok = Broadcaster.subscribe({:kpi, @workspace, :latency_p95})

      {:ok, _} = Broadcaster.refresh()
      flush()

      {:ok, _} = Broadcaster.refresh()

      refute_receive {:kpi_point, _agent, _slug, _point}, 200
    end

    test "topics are distinct per agent" do
      refute Broadcaster.topic({:agent, "a"}) == Broadcaster.topic({:agent, "b"})
      refute Broadcaster.topic(:overview) == Broadcaster.topic({:agent, "a"})

      refute Broadcaster.topic({:kpi, "a", :toxicity}) ==
               Broadcaster.topic({:kpi, "a", :latency_p95})
    end
  end

  describe "the running process" do
    test "refreshes on demand without restarting" do
      pid = Process.whereis(Broadcaster)

      {:ok, _} = Broadcaster.refresh()
      {:ok, _} = Broadcaster.refresh()

      assert Process.whereis(Broadcaster) == pid
      assert Process.alive?(pid)
    end

    test "reports when it last succeeded" do
      {:ok, _} = Broadcaster.refresh()

      assert %{last_refresh_at: %DateTime{}, refreshes: n} = Broadcaster.state()
      assert n > 0
    end
  end
end
