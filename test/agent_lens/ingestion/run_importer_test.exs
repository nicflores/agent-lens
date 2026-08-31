defmodule AgentLens.Ingestion.RunImporterTest do
  use AgentLens.DataCase, async: false

  alias AgentLens.Ingestion.RunImporter
  alias AgentLens.LangSmith.Mock
  alias AgentLens.Repo
  alias AgentLens.Store.KpiObservation
  alias AgentLens.Store.Run

  @workspace "ws-support"
  @now ~U[2026-08-30 00:00:00.000000Z]

  defp page(opts) do
    {:ok, %{items: items}} =
      Mock.list_runs(@workspace, Keyword.merge([now: @now, limit: 10], opts))

    items
  end

  describe "import/3" do
    test "stores the runs" do
      items = page(since: Mock.epoch(@now))

      assert {:ok, result} = RunImporter.import(@workspace, items)
      assert result.runs == length(items)
      assert Repo.aggregate(Run, :count) == length(items)
    end

    test "computes extracted observations inline" do
      {:ok, result} = RunImporter.import(@workspace, page(since: Mock.epoch(@now)))

      assert result.observations > 0
      assert Repo.aggregate(KpiObservation, :count) == result.observations
    end

    test "links observations back to their run" do
      {:ok, _} = RunImporter.import(@workspace, page(since: Mock.epoch(@now)))

      run = Repo.one(from(r in Run, limit: 1))
      observations = Repo.all(from(o in KpiObservation, where: o.run_id == ^run.id))

      assert observations != []
      assert Enum.all?(observations, &(&1.source == "extracted"))
    end

    test "returns the newest start_time as the watermark" do
      items = page(since: Mock.epoch(@now))
      expected = items |> Enum.map(& &1["start_time"]) |> Enum.max(DateTime)

      {:ok, result} = RunImporter.import(@workspace, items)

      assert DateTime.compare(result.watermark, expected) == :eq
    end

    test "attributes runs to the workspace they were polled from" do
      {:ok, _} = RunImporter.import("ws-research", page(since: Mock.epoch(@now)))

      assert Repo.all(from(r in Run, select: r.agent_id)) |> Enum.uniq() == ["ws-research"]
    end
  end

  # Re-reading the overlap window is normal, so importing the same page twice
  # must converge rather than accumulate.
  describe "idempotency" do
    test "re-importing the same page does not duplicate runs" do
      items = page(since: Mock.epoch(@now))

      {:ok, _} = RunImporter.import(@workspace, items)
      {:ok, _} = RunImporter.import(@workspace, items)

      assert Repo.aggregate(Run, :count) == length(items)
    end

    test "re-importing the same page does not duplicate observations" do
      items = page(since: Mock.epoch(@now))

      {:ok, first} = RunImporter.import(@workspace, items)
      {:ok, _second} = RunImporter.import(@workspace, items)

      assert Repo.aggregate(KpiObservation, :count) == first.observations
    end

    test "updates a run that changed since it was first seen" do
      [item | _] = page(since: Mock.epoch(@now))
      pending = Map.merge(item, %{"status" => "pending", "end_time" => nil, "latency_ms" => nil})

      {:ok, _} = RunImporter.import(@workspace, [pending])
      assert %Run{status: "pending"} = Repo.one(from(r in Run, limit: 1))

      {:ok, _} = RunImporter.import(@workspace, [item])
      assert %Run{status: "success"} = Repo.one(from(r in Run, limit: 1))
    end
  end

  # Backfill reaches back further than the partitions the boot sweep creates,
  # so the importer has to make room for the batch it is about to write.
  describe "partition safety" do
    test "creates partitions covering a backfill batch" do
      old = page(since: Mock.epoch(@now), limit: 5)

      assert {:ok, %{runs: 5}} = RunImporter.import(@workspace, old)
    end

    test "handles a batch spanning several weeks" do
      spread =
        for offset <- [0, 20, 55, 88] do
          [item] =
            page(since: DateTime.add(Mock.epoch(@now), offset, :day), limit: 1)

          item
        end

      assert {:ok, %{runs: 4}} = RunImporter.import(@workspace, spread)
      assert Repo.aggregate(Run, :count) == 4
    end
  end

  describe "empty pages" do
    test "an empty page is a no-op with no watermark" do
      assert {:ok, %{runs: 0, observations: 0, watermark: nil}} =
               RunImporter.import(@workspace, [])
    end
  end
end
