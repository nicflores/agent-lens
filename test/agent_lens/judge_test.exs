defmodule AgentLens.JudgeTest do
  use AgentLens.DataCase, async: false
  use Oban.Testing, repo: AgentLens.Repo

  alias AgentLens.Ingestion.RunImporter
  alias AgentLens.Judge
  alias AgentLens.LangSmith.Mock
  alias AgentLens.Repo
  alias AgentLens.Store.KpiObservation
  alias AgentLens.Workers.JudgeWorker

  @workspace "ws-support"
  @now ~U[2026-08-30 00:00:00.000000Z]

  defmodule StubLLM do
    @moduledoc false
    @behaviour AgentLens.LLM.Client

    @impl true
    def complete(_prompt, _opts), do: {:ok, %{text: "0.42", model: "stub-judge-v1"}}
  end

  defmodule UnparseableLLM do
    @moduledoc false
    @behaviour AgentLens.LLM.Client

    @impl true
    def complete(_prompt, _opts), do: {:ok, %{text: "I would rather not say", model: "stub"}}
  end

  defmodule FailingLLM do
    @moduledoc false
    @behaviour AgentLens.LLM.Client

    @impl true
    def complete(_prompt, _opts), do: {:error, :timeout}
  end

  defp since, do: DateTime.add(@now, -1, :day)

  defp ingest(count \\ 20) do
    {:ok, %{items: runs}} = Mock.list_runs(@workspace, since: since(), limit: count, now: @now)
    {:ok, _} = RunImporter.import(@workspace, runs)
    :ok
  end

  defp judged, do: Repo.all(from(o in KpiObservation, where: o.source == "judged"))

  describe "backfill/5" do
    setup do
      ingest()
      :ok
    end

    # The whole point: a KPI switched on today gets history anyway.
    test "scores runs that have no observation yet" do
      assert {:ok, result} = Judge.backfill(@workspace, :toxicity, since(), @now, llm: StubLLM)

      assert result.judged > 0
      assert length(judged()) == result.judged
    end

    test "records which model did the judging, since a score is uninterpretable without it" do
      {:ok, _} = Judge.backfill(@workspace, :toxicity, since(), @now, llm: StubLLM)

      assert Enum.all?(judged(), &(&1.judge_model == "stub-judge-v1"))
    end

    test "stamps observations as judged, not imported" do
      {:ok, _} = Judge.backfill(@workspace, :toxicity, since(), @now, llm: StubLLM)

      assert Enum.all?(judged(), &(&1.source == "judged"))
    end

    test "dates them by the run, so they land in the bucket they describe" do
      {:ok, _} = Judge.backfill(@workspace, :toxicity, since(), @now, llm: StubLLM)

      starts = Repo.all(from(r in AgentLens.Store.Run, select: r.start_time)) |> MapSet.new()

      assert Enum.all?(judged(), &MapSet.member?(starts, &1.occurred_at))
    end

    test "does not re-judge a run it has already scored" do
      {:ok, first} = Judge.backfill(@workspace, :toxicity, since(), @now, llm: StubLLM)
      {:ok, second} = Judge.backfill(@workspace, :toxicity, since(), @now, llm: StubLLM)

      assert second.judged == 0
      assert length(judged()) == first.judged
    end

    test "respects the batch size, so a long backfill stays interruptible" do
      {:ok, result} = Judge.backfill(@workspace, :toxicity, since(), @now, llm: StubLLM, batch: 3)

      assert result.judged == 3
    end
  end

  describe "what it declines to do" do
    # Sentiment is imported from a LangSmith evaluator and declares no local
    # prompt, so there is nothing this tier can do for it.
    test "skips a KPI that declares no local judge" do
      ingest()

      assert {:ok, %{judged: 0, skipped: skipped}} =
               Judge.backfill(@workspace, :sentiment, since(), @now, llm: StubLLM)

      assert skipped > 0
    end

    # An extracted KPI is computed inline at ingest, so every run already has
    # one and there is genuinely no backfill to do.
    test "finds nothing to do for a KPI already computed on every run" do
      ingest()

      assert {:ok, %{judged: 0, skipped: 0}} =
               Judge.backfill(@workspace, :success_rate, since(), @now, llm: StubLLM)
    end

    # Retention purges payloads sooner than rows. A run without one cannot be
    # judged at any price, and that is where the series honestly begins.
    test "cannot judge a run whose payload has been purged" do
      ingest()
      Repo.update_all(AgentLens.Store.Run, set: [payload: %{}])

      assert {:ok, %{judged: 0}} =
               Judge.backfill(@workspace, :toxicity, since(), @now, llm: StubLLM)
    end

    # An unparseable answer is a failure, not a skip: the run is still
    # judgeable and should be retried rather than silently written off.
    test "counts an unparseable reply as a failure" do
      ingest(5)

      assert {:ok, %{judged: 0, failed: failed}} =
               Judge.backfill(@workspace, :toxicity, since(), @now, llm: UnparseableLLM)

      assert failed > 0
    end

    test "survives a model outage without writing anything" do
      ingest(5)

      assert {:ok, %{judged: 0, failed: failed}} =
               Judge.backfill(@workspace, :toxicity, since(), @now, llm: FailingLLM)

      assert failed > 0
      assert judged() == []
    end

    test "reports an unknown KPI rather than silently doing nothing" do
      assert {:error, {:unknown_kpi, :nope}} =
               Judge.backfill(@workspace, :nope, since(), @now, llm: StubLLM)
    end
  end

  describe "JudgeWorker" do
    test "enqueues a backfill job" do
      assert {:ok, _job} =
               JudgeWorker.enqueue(@workspace, :toxicity, from: since(), to: @now, batch: 5)

      assert_enqueued(worker: JudgeWorker, queue: :judge)
    end

    # A ninety-day backfill is many small jobs rather than one long one, so it
    # can be paused, retried and rate-limited a batch at a time.
    test "queues its own successor while there is still work" do
      ingest(20)

      assert {:ok, %{done: false}} =
               perform_job(JudgeWorker, %{
                 "agent_id" => @workspace,
                 "kpi_slug" => "toxicity",
                 "from" => DateTime.to_iso8601(since()),
                 "to" => DateTime.to_iso8601(@now),
                 "batch" => 5
               })

      assert_enqueued(worker: JudgeWorker)
    end

    test "stops when there is nothing left to judge" do
      assert {:ok, %{done: true}} =
               perform_job(JudgeWorker, %{
                 "agent_id" => @workspace,
                 "kpi_slug" => "toxicity",
                 "from" => DateTime.to_iso8601(since()),
                 "to" => DateTime.to_iso8601(@now),
                 "batch" => 5
               })

      refute_enqueued(worker: JudgeWorker)
    end
  end
end
