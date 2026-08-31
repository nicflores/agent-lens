defmodule AgentLens.Ingestion.FeedbackImporterTest do
  use AgentLens.DataCase, async: false

  alias AgentLens.Ingestion.FeedbackImporter
  alias AgentLens.Ingestion.RunImporter
  alias AgentLens.LangSmith.Mock
  alias AgentLens.Repo
  alias AgentLens.Store.KpiObservation

  @workspace "ws-support"
  @now ~U[2026-08-30 00:00:00.000000Z]

  defp since, do: DateTime.add(Mock.epoch(@now), 10, :day)

  defp ingest_runs(limit \\ 200) do
    {:ok, %{items: items}} = Mock.list_runs(@workspace, since: since(), limit: limit, now: @now)
    {:ok, _} = RunImporter.import(@workspace, items)
    items
  end

  defp feedback(limit \\ 20) do
    {:ok, %{items: items}} =
      Mock.list_feedback(@workspace, since: since(), limit: limit, now: @now)

    items
  end

  defp imported, do: Repo.all(from(o in KpiObservation, where: o.source == "imported"))

  describe "import/3 with the runs already ingested" do
    setup do
      ingest_runs()
      :ok
    end

    test "stores judged scores as imported observations" do
      assert {:ok, result} = FeedbackImporter.import(@workspace, feedback())

      assert result.observations > 0
      assert length(imported()) == result.observations
    end

    test "maps feedback keys onto KPI slugs" do
      {:ok, _} = FeedbackImporter.import(@workspace, feedback())

      slugs = imported() |> Enum.map(& &1.kpi_slug) |> Enum.uniq() |> Enum.sort()
      assert slugs == ["sentiment", "toxicity"]
    end

    test "links observations to the run the feedback is about" do
      {:ok, _} = FeedbackImporter.import(@workspace, feedback())

      assert Enum.all?(imported(), &is_integer(&1.run_id))
    end

    # occurred_at is the run's start_time, not when the evaluator scored it, so
    # a judged value lands in the bucket describing the traffic it measured.
    test "dates observations by the run, not by when it was scored" do
      {:ok, _} = FeedbackImporter.import(@workspace, feedback())

      run_starts =
        Repo.all(from(r in AgentLens.Store.Run, select: {r.id, r.start_time})) |> Map.new()

      for observation <- imported() do
        assert DateTime.compare(
                 observation.occurred_at,
                 Map.fetch!(run_starts, observation.run_id)
               ) ==
                 :eq
      end
    end

    test "is idempotent" do
      items = feedback()

      {:ok, first} = FeedbackImporter.import(@workspace, items)
      {:ok, _} = FeedbackImporter.import(@workspace, items)

      assert length(imported()) == first.observations
    end

    test "advances the watermark to the newest matched record" do
      items = feedback()
      expected = items |> Enum.map(& &1["created_at"]) |> Enum.max(DateTime)

      {:ok, result} = FeedbackImporter.import(@workspace, items)

      assert DateTime.compare(result.watermark, expected) == :eq
    end
  end

  # Feedback is written after the run it attaches to, so a poll can legitimately
  # see a score for a run that has not been ingested yet. Dropping it silently
  # would lose the score for good.
  describe "feedback arriving before its run" do
    test "skips orphan feedback rather than failing the page" do
      assert {:ok, result} = FeedbackImporter.import(@workspace, feedback())

      assert result.observations == 0
      assert result.orphans > 0
    end

    test "does not advance the watermark past unmatched feedback" do
      assert {:ok, %{watermark: nil}} = FeedbackImporter.import(@workspace, feedback())
    end

    test "only advances as far as the newest record it could match" do
      items = feedback(40)

      # Ingest only the runs the first few feedback records point at.
      matched_ids = items |> Enum.take(4) |> Enum.map(& &1["run_id"]) |> MapSet.new()
      {:ok, %{items: runs}} = Mock.list_runs(@workspace, since: since(), limit: 200, now: @now)

      {:ok, _} =
        RunImporter.import(@workspace, Enum.filter(runs, &MapSet.member?(matched_ids, &1["id"])))

      {:ok, result} = FeedbackImporter.import(@workspace, items)

      newest_matched =
        items
        |> Enum.filter(&MapSet.member?(matched_ids, &1["run_id"]))
        |> Enum.map(& &1["created_at"])
        |> Enum.max(DateTime)

      assert DateTime.compare(result.watermark, newest_matched) == :eq
      assert result.orphans > 0
    end

    test "picks the feedback up once the run has been ingested" do
      items = feedback()

      {:ok, %{observations: 0}} = FeedbackImporter.import(@workspace, items)
      ingest_runs()
      {:ok, result} = FeedbackImporter.import(@workspace, items)

      assert result.observations > 0
    end
  end

  describe "empty pages" do
    test "an empty page is a no-op" do
      assert {:ok, %{observations: 0, orphans: 0, watermark: nil}} =
               FeedbackImporter.import(@workspace, [])
    end
  end
end
