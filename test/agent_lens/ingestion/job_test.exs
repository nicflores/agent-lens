defmodule AgentLens.Ingestion.JobTest do
  use AgentLens.DataCase, async: false

  alias AgentLens.Ingestion.Cursor
  alias AgentLens.Ingestion.Job
  alias AgentLens.LangSmith.Mock
  alias AgentLens.Repo
  alias AgentLens.Store.KpiObservation
  alias AgentLens.Store.Run

  @workspace "ws-support"
  @now ~U[2026-08-30 00:00:00.000000Z]

  defp opts(extra \\ []), do: Keyword.merge([now: @now, limit: 50], extra)

  describe "run_once/3 for runs" do
    test "ingests a page and advances the cursor" do
      assert {:ok, result} = Job.run_once(@workspace, :runs, opts())

      assert result.runs == 50
      assert Repo.aggregate(Run, :count) == 50
      assert Cursor.watermark(@workspace, :runs) != nil
    end

    test "reports more pages remaining" do
      assert {:ok, %{has_more?: true}} = Job.run_once(@workspace, :runs, opts())
    end

    test "the next poll continues from the cursor rather than restarting" do
      {:ok, first} = Job.run_once(@workspace, :runs, opts())
      {:ok, second} = Job.run_once(@workspace, :runs, opts())

      assert DateTime.compare(second.watermark, first.watermark) == :gt
    end

    # The overlap window means consecutive polls deliberately re-read a little,
    # so total stored runs must be less than pages x page size.
    test "overlapping polls converge rather than accumulate duplicates" do
      {:ok, _} = Job.run_once(@workspace, :runs, opts())
      {:ok, _} = Job.run_once(@workspace, :runs, opts())

      count = Repo.aggregate(Run, :count)
      assert count > 50
      assert count <= 100
    end

    test "computes observations along the way" do
      {:ok, _} = Job.run_once(@workspace, :runs, opts())

      assert Repo.aggregate(KpiObservation, :count) > 0
    end
  end

  describe "run_once/3 for feedback" do
    test "imports scores for runs already ingested" do
      {:ok, _} = Job.drain(@workspace, :runs, opts(limit: 200, max_pages: 20))

      assert {:ok, result} = Job.run_once(@workspace, :feedback, opts())
      assert result.observations > 0
    end

    test "does not advance its cursor past feedback whose run is missing" do
      assert {:ok, %{observations: 0}} = Job.run_once(@workspace, :feedback, opts())
      assert Cursor.watermark(@workspace, :feedback) == nil
    end
  end

  describe "drain/3" do
    test "reads pages until the window is exhausted" do
      # Start near the end of the window so this drains a few pages rather than
      # the whole 90-day universe.
      :ok = Cursor.advance!(@workspace, :runs, DateTime.add(Mock.epoch(@now), 87, :day))

      assert {:ok, summary} = Job.drain(@workspace, :runs, opts(limit: 200, max_pages: 50))

      assert summary.pages > 1

      # summary.runs counts rows written, which exceeds the distinct count
      # because each page deliberately re-reads the overlap window.
      assert summary.runs >= Repo.aggregate(Run, :count)
      assert Repo.aggregate(Run, :count) > 200
    end

    test "stops at max_pages so a backfill cannot run away" do
      assert {:ok, %{pages: 3}} = Job.drain(@workspace, :runs, opts(limit: 20, max_pages: 3))
    end

    # Feedback that never matches a run leaves the cursor parked. Draining must
    # notice the lack of progress and stop rather than re-reading forever.
    test "stops when a page makes no progress" do
      assert {:ok, summary} = Job.drain(@workspace, :feedback, opts(limit: 20, max_pages: 50))

      assert summary.pages == 1
      assert summary.observations == 0
    end
  end

  describe "failures" do
    defmodule FailingClient do
      @moduledoc false
      @behaviour AgentLens.LangSmith.Client

      @impl true
      def list_runs(_workspace, _opts), do: {:error, :timeout}

      @impl true
      def list_feedback(_workspace, _opts), do: {:error, :timeout}
    end

    test "records the failure and leaves the cursor alone" do
      {:ok, _} = Job.run_once(@workspace, :runs, opts())
      watermark = Cursor.watermark(@workspace, :runs)

      assert {:error, :timeout} = Job.run_once(@workspace, :runs, opts(client: FailingClient))

      assert DateTime.compare(Cursor.watermark(@workspace, :runs), watermark) == :eq
      assert %{consecutive_failures: 1, last_error: error} = Cursor.get(@workspace, :runs)
      assert error =~ "timeout"
    end

    test "a later success clears the failure count" do
      {:error, :timeout} = Job.run_once(@workspace, :runs, opts(client: FailingClient))
      {:ok, _} = Job.run_once(@workspace, :runs, opts())

      assert %{consecutive_failures: 0} = Cursor.get(@workspace, :runs)
    end
  end
end
