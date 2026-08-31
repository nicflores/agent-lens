defmodule AgentLens.LangSmith.MockTest do
  use ExUnit.Case, async: true

  alias AgentLens.LangSmith.Mock

  @now ~U[2026-08-30 00:00:00.000000Z]
  @workspace "ws-support"

  defp runs(opts) do
    {:ok, %{items: items}} = Mock.list_runs(@workspace, Keyword.put_new(opts, :now, @now))
    items
  end

  defp day(offset), do: DateTime.add(Mock.epoch(@now), offset, :day)

  defp runs_on_day(offset, limit \\ 60) do
    runs(since: day(offset), limit: limit)
  end

  defp mean(values), do: Enum.sum(values) / length(values)

  describe "determinism" do
    # The mock doubles as the fixture set for drift detection, so the same
    # window must produce the same data every time it is read.
    test "the same window returns identical runs across calls" do
      first = runs(since: day(10), limit: 25)
      second = runs(since: day(10), limit: 25)

      assert first == second
    end

    test "different workspaces produce different data" do
      {:ok, %{items: support}} =
        Mock.list_runs("ws-support", since: day(10), limit: 20, now: @now)

      {:ok, %{items: research}} =
        Mock.list_runs("ws-research", since: day(10), limit: 20, now: @now)

      refute Enum.map(support, & &1["id"]) == Enum.map(research, & &1["id"])
    end
  end

  describe "paging" do
    test "returns runs ordered oldest first" do
      times = runs(since: day(5), limit: 40) |> Enum.map(& &1["start_time"])

      assert times == Enum.sort(times, DateTime)
    end

    test "returns only runs newer than :since" do
      cutoff = day(20)

      for run <- runs(since: cutoff, limit: 30) do
        assert DateTime.compare(run["start_time"], cutoff) == :gt
      end
    end

    test "respects the limit" do
      assert length(runs(since: day(5), limit: 7)) == 7
    end

    test "reports more results remaining when the page is full" do
      {:ok, page} = Mock.list_runs(@workspace, since: day(5), limit: 5, now: @now)
      assert page.has_more?
    end

    test "reports no more results once the window is exhausted" do
      {:ok, page} = Mock.list_runs(@workspace, since: day(89), limit: 10_000, now: @now)
      refute page.has_more?
    end

    # Ninety days of backfill is what gives a new KPI something to be
    # backfilled across, and the dashboard something to display on day one.
    test "covers roughly ninety days of history" do
      {:ok, %{items: items}} =
        Mock.list_runs(@workspace, since: day(0), limit: 100_000, now: @now)

      first = List.first(items)["start_time"]
      last = List.last(items)["start_time"]

      assert DateTime.diff(last, first, :day) >= 85
    end

    test "never returns runs in the future" do
      {:ok, %{items: items}} =
        Mock.list_runs(@workspace, since: day(0), limit: 100_000, now: @now)

      for run <- items do
        assert DateTime.compare(run["start_time"], @now) != :gt
      end
    end
  end

  describe "run payload shape" do
    test "looks like a LangSmith run" do
      [run | _] = runs(since: day(10), limit: 1)

      assert is_binary(run["id"])
      assert is_binary(run["trace_id"])
      assert run["run_type"] in ["chain", "llm", "tool"]
      assert run["status"] in ["success", "error"]
      assert %DateTime{} = run["start_time"]
      assert %DateTime{} = run["end_time"]
      assert is_integer(run["latency_ms"])
    end

    test "carries nested inputs, outputs and metadata the extractors can read" do
      [run | _] = runs(since: day(10), limit: 1)

      assert is_map(run["inputs"])
      assert is_map(run["outputs"])
      assert is_binary(get_in(run, ["extra", "metadata", "model"]))
    end

    test "reports token counts and cost" do
      [run | _] = runs(since: day(10), limit: 1)

      assert is_integer(run["prompt_tokens"])
      assert is_integer(run["completion_tokens"])
      assert is_float(run["total_cost"])
    end
  end

  describe "injected anomalies" do
    # Uniform noise would make the dashboard look alive while showing nothing.
    # Each of these is a specific, findable event at a known time.
    test "latency spikes during the injected window" do
      %{latency_spike: spike} = Mock.anomalies()

      before_spike = runs_on_day(spike.from_day - 4) |> Enum.map(& &1["latency_ms"]) |> mean()
      during_spike = runs_on_day(spike.from_day) |> Enum.map(& &1["latency_ms"]) |> mean()

      assert during_spike > before_spike * 2,
             "expected a visible latency spike, got #{before_spike} -> #{during_spike}"
    end

    test "latency recovers after the spike window" do
      %{latency_spike: spike} = Mock.anomalies()

      during = runs_on_day(spike.from_day) |> Enum.map(& &1["latency_ms"]) |> mean()
      after_spike = runs_on_day(spike.to_day + 2) |> Enum.map(& &1["latency_ms"]) |> mean()

      assert after_spike < during / 2
    end

    test "the model version changes at the regression boundary" do
      %{toxicity_regression: regression} = Mock.anomalies()

      before_model =
        runs_on_day(regression.from_day - 5, 1) |> hd() |> get_in(["extra", "metadata", "model"])

      after_model =
        runs_on_day(regression.from_day + 5, 1) |> hd() |> get_in(["extra", "metadata", "model"])

      refute before_model == after_model
    end

    test "cost creeps upward across the window" do
      early = runs_on_day(5) |> Enum.map(& &1["total_cost"]) |> mean()
      late = runs_on_day(80) |> Enum.map(& &1["total_cost"]) |> mean()

      assert late > early * 1.2, "expected a cost creep, got #{early} -> #{late}"
    end
  end

  describe "feedback" do
    defp feedback(opts) do
      {:ok, %{items: items}} = Mock.list_feedback(@workspace, Keyword.put_new(opts, :now, @now))
      items
    end

    test "uses the kpi. naming convention so slug mapping stays mechanical" do
      for item <- feedback(since: day(10), limit: 30) do
        assert String.starts_with?(item["key"], "kpi.")
      end
    end

    test "scores reference runs that exist" do
      run_ids = runs(since: day(10), limit: 200) |> Enum.map(& &1["id"]) |> MapSet.new()
      items = feedback(since: day(10), limit: 20)

      assert items != []

      for item <- items do
        assert MapSet.member?(run_ids, item["run_id"]),
               "feedback references a run that was never emitted"
      end
    end

    test "is sampled rather than attached to every run" do
      run_count = runs(since: day(10), limit: 500) |> length()

      feedback_runs =
        feedback(since: day(10), limit: 500)
        |> Enum.map(& &1["run_id"])
        |> Enum.uniq()
        |> length()

      assert feedback_runs < run_count,
             "judged KPIs are sampled; feedback on every run would misrepresent cost"
    end

    # The poller advances its cursor to the newest record in a page, so a page
    # that is not ordered oldest-first would strand feedback behind the cursor.
    # A narrow window runs the generator to completion instead of stopping at
    # the limit, which is a different code path through the accumulator.
    test "is ordered oldest first when the window is exhausted before the limit" do
      {:ok, page} = Mock.list_feedback(@workspace, since: day(87), limit: 5_000, now: @now)
      created = Enum.map(page.items, & &1["created_at"])

      assert created != []
      refute page.has_more?
      assert created == Enum.sort(created, DateTime)
    end

    test "is ordered oldest first when the page is truncated by the limit" do
      created = feedback(since: day(10), limit: 8) |> Enum.map(& &1["created_at"])

      assert created == Enum.sort(created, DateTime)
    end

    test "records whether a score came from a model or a human" do
      for item <- feedback(since: day(10), limit: 20) do
        assert get_in(item, ["feedback_source", "type"]) in ["model", "api"]
      end
    end

    test "toxicity regresses after the simulated model change" do
      %{toxicity_regression: regression} = Mock.anomalies()

      scores = fn offset ->
        feedback(since: day(offset), limit: 400)
        |> Enum.filter(&(&1["key"] == "kpi.toxicity"))
        |> Enum.map(& &1["score"])
      end

      before_scores = scores.(regression.from_day - 12)
      after_scores = scores.(regression.from_day + 1)

      assert before_scores != [] and after_scores != []
      assert mean(after_scores) > mean(before_scores) * 2
    end
  end
end
