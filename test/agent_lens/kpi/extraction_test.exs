defmodule AgentLens.Kpi.ExtractionTest do
  use ExUnit.Case, async: true

  alias AgentLens.Kpi.Extraction
  alias AgentLens.Kpi.Input
  alias AgentLens.Kpi.Registry

  @occurred ~U[2026-08-30 12:00:00.000000Z]

  defp registry, do: Registry.load!()

  defp input(overrides \\ []) do
    struct(
      %Input.Run{
        langsmith_run_id: "run-1",
        agent_id: "ws-support",
        status: "success",
        latency_ms: 1200,
        start_time: @occurred,
        payload: %{},
        feedback: %{}
      },
      overrides
    )
  end

  defp slugs(observations), do: observations |> Enum.map(& &1.kpi_slug) |> Enum.sort()

  describe "from_run/3" do
    test "computes every extracted KPI for a run" do
      observations = Extraction.from_run(registry(), input())

      assert slugs(observations) == ["latency_p95", "success_rate"]
    end

    # Judged KPIs come in through the feedback import, and derived ones are
    # computed on bucket close. Neither belongs on the ingest path.
    test "ignores judged and derived KPIs" do
      observations = Extraction.from_run(registry(), input())

      refute "toxicity" in slugs(observations)
      refute "latency_drift" in slugs(observations)
    end

    test "stamps observations as extracted" do
      for observation <- Extraction.from_run(registry(), input()) do
        assert observation.source == "extracted"
      end
    end

    # occurred_at is the run's start_time, not now. It is the partition key, and
    # being stable is what lets recomputation dedupe instead of duplicate.
    test "uses the run's start_time as occurred_at" do
      for observation <- Extraction.from_run(registry(), input()) do
        assert observation.occurred_at == @occurred
      end
    end

    test "carries the KPI version so a formula change is distinguishable" do
      for observation <- Extraction.from_run(registry(), input()) do
        assert observation.kpi_version == 1
      end
    end

    test "attaches the run id when one is supplied" do
      observations = Extraction.from_run(registry(), input(), run_id: 42)

      assert Enum.all?(observations, &(&1.run_id == 42))
    end

    test "records the agent from the run" do
      observations = Extraction.from_run(registry(), input(agent_id: "ws-research"))

      assert Enum.all?(observations, &(&1.agent_id == "ws-research"))
    end
  end

  describe "skipping" do
    # A run with no outcome yet must produce no observation at all. Recording a
    # zero would be inventing data.
    test "omits a KPI that skips this run" do
      observations = Extraction.from_run(registry(), input(status: "pending"))

      refute "success_rate" in slugs(observations)
    end

    test "omits a KPI whose field is missing" do
      observations = Extraction.from_run(registry(), input(latency_ms: nil))

      refute "latency_p95" in slugs(observations)
    end

    test "returns nothing when every KPI skips" do
      assert [] = Extraction.from_run(registry(), input(status: "pending", latency_ms: nil))
    end
  end

  describe "from_feedback/4" do
    test "maps a feedback key onto its KPI slug" do
      observations =
        Extraction.from_feedback(registry(), input(feedback: %{"kpi.toxicity" => 0.02}),
          run_id: 7
        )

      assert [%{kpi_slug: "toxicity", value: 0.02, source: "imported", run_id: 7}] = observations
    end

    test "handles several scores on one run" do
      input = input(feedback: %{"kpi.toxicity" => 0.02, "kpi.polarity" => 0.4})

      assert slugs(Extraction.from_feedback(registry(), input)) == ["sentiment", "toxicity"]
    end

    test "ignores feedback keys with no matching KPI" do
      input = input(feedback: %{"kpi.something_we_do_not_track" => 0.5})

      assert [] = Extraction.from_feedback(registry(), input)
    end

    test "does not produce extracted KPIs" do
      input = input(feedback: %{"kpi.toxicity" => 0.02})

      refute "success_rate" in slugs(Extraction.from_feedback(registry(), input))
    end
  end
end
