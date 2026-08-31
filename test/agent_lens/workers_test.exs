defmodule AgentLens.WorkersTest do
  use AgentLens.DataCase, async: false
  use Oban.Testing, repo: AgentLens.Repo

  alias AgentLens.Ingestion.RunImporter
  alias AgentLens.LangSmith.Mock
  alias AgentLens.Partitions.Manager
  alias AgentLens.Repo
  alias AgentLens.Store.KpiRollup
  alias AgentLens.Store.Run
  alias AgentLens.Workers.DerivedWorker
  alias AgentLens.Workers.RetentionWorker
  alias AgentLens.Workers.RollupWorker

  @workspace "ws-support"
  @now ~U[2026-08-30 00:00:00.000000Z]

  defp ingest_recent do
    {:ok, %{items: items}} =
      Mock.list_runs(@workspace, since: DateTime.add(@now, -2, :day), limit: 500, now: @now)

    {:ok, _} = RunImporter.import(@workspace, items)
    :ok
  end

  describe "RollupWorker" do
    setup do
      ingest_recent()
      :ok
    end

    test "computes buckets at the requested granularity" do
      assert {:ok, %{buckets: buckets, granularity: :hour}} =
               perform_job(RollupWorker, %{
                 "granularity" => "hour",
                 "now" => DateTime.to_iso8601(@now)
               })

      assert buckets > 0
      assert Repo.all(from(r in KpiRollup, select: r.granularity, distinct: true)) == ["hour"]
    end

    # Late observations are the norm, not the exception, so each run recomputes
    # a window rather than only the bucket that just closed.
    test "recomputes a window of recent buckets, not just the last one" do
      {:ok, %{buckets: buckets}} =
        perform_job(RollupWorker, %{
          "granularity" => "hour",
          "now" => DateTime.to_iso8601(@now)
        })

      # Two KPIs across a multi-hour lookback.
      assert buckets > 2
    end

    test "is safe to run repeatedly" do
      args = %{"granularity" => "hour", "now" => DateTime.to_iso8601(@now)}

      {:ok, _} = perform_job(RollupWorker, args)
      before = Repo.aggregate(KpiRollup, :count)
      {:ok, _} = perform_job(RollupWorker, args)

      assert Repo.aggregate(KpiRollup, :count) == before
    end

    # Job args round-trip through the database, so an unknown grain must fail
    # loudly rather than creating an atom or silently doing nothing.
    test "rejects an unknown granularity" do
      assert_raise ArgumentError, ~r/granularity/, fn ->
        perform_job(RollupWorker, %{"granularity" => "fortnight"})
      end
    end
  end

  describe "DerivedWorker" do
    test "runs the derived pass without error when there is nothing to compare" do
      assert {:ok, %{buckets: 0}} =
               perform_job(DerivedWorker, %{"as_of" => DateTime.to_iso8601(@now)})
    end

    test "accepts window overrides" do
      ingest_recent()

      assert {:ok, %{buckets: _}} =
               perform_job(DerivedWorker, %{
                 "as_of" => DateTime.to_iso8601(@now),
                 "current_days" => 1,
                 "baseline_days" => 1
               })
    end
  end

  describe "RetentionWorker" do
    test "reports what it removed" do
      assert {:ok, result} = perform_job(RetentionWorker, %{})

      assert Map.has_key?(result, :payloads_purged)
      assert Map.has_key?(result, :rollups_expired)
    end

    # The same job that drops what has aged out provisions what is about to be
    # needed, so ingestion never meets a missing partition.
    test "keeps the partition runway ahead of ingestion" do
      {:ok, _} = perform_job(RetentionWorker, %{})

      future = DateTime.add(DateTime.utc_now(), 7, :day)

      assert Enum.any?(Manager.list(:runs), fn partition ->
               DateTime.compare(partition.to, future) == :gt
             end)
    end

    test "leaves recent data alone" do
      ingest_recent()
      before = Repo.aggregate(Run, :count)

      {:ok, _} = perform_job(RetentionWorker, %{})

      assert Repo.aggregate(Run, :count) == before
    end
  end

  describe "the configured schedule" do
    test "covers every grain plus the derived and retention passes" do
      crontab =
        :agent_lens
        |> Application.fetch_env!(Oban)
        |> Keyword.fetch!(:plugins)
        |> Enum.find_value(fn
          {Oban.Plugins.Cron, opts} -> Keyword.fetch!(opts, :crontab)
          _other -> nil
        end)

      workers = Enum.map(crontab, fn entry -> elem(entry, 1) end) |> Enum.uniq()

      assert RollupWorker in workers
      assert DerivedWorker in workers
      assert RetentionWorker in workers

      grains =
        for {_schedule, RollupWorker, opts} <- crontab,
            do: opts[:args]["granularity"]

      assert Enum.sort(grains) == ["day", "hour", "minute"]
    end
  end
end
