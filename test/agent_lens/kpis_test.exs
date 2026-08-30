defmodule AgentLens.KpisTest do
  use ExUnit.Case, async: true

  alias AgentLens.Kpi.Definition
  alias AgentLens.Kpi.FieldManifest
  alias AgentLens.Kpi.Input
  alias AgentLens.Kpis

  @modules [Kpis.SuccessRate, Kpis.LatencyP95, Kpis.Toxicity, Kpis.Sentiment, Kpis.Drift]

  # Every KPI module must satisfy these, so they are asserted for all of them
  # rather than restated per module.
  describe "every registered KPI module" do
    test "returns a definition that validates" do
      for module <- @modules do
        assert :ok = module.definition() |> Definition.validate(),
               "#{inspect(module)} returned an invalid definition"
      end
    end

    test "declares only field paths the manifest knows" do
      for module <- @modules do
        assert :ok = module.requires() |> FieldManifest.validate(),
               "#{inspect(module)} requires an unknown field"
      end
    end

    test "uses a slug matching its module" do
      slugs = Enum.map(@modules, & &1.definition().slug)
      assert Enum.uniq(slugs) == slugs, "KPI slugs must be unique"
    end

    test "only declares KPI dependencies when derived" do
      for module <- @modules do
        definition = module.definition()

        if definition.kind != :derived do
          assert [] = module.depends_on(),
                 "#{inspect(module)} is #{definition.kind} but declares dependencies"
        end
      end
    end
  end

  describe "SuccessRate" do
    test "scores a successful run as 1.0" do
      assert {:ok, 1.0} = Kpis.SuccessRate.compute(%Input.Run{status: "success"})
    end

    test "scores a failed run as 0.0" do
      assert {:ok, score} = Kpis.SuccessRate.compute(%Input.Run{status: "error"})
      assert score == 0.0
    end

    # A run still in flight has no outcome yet. Recording it as a zero would
    # depress the rate with data that does not exist.
    test "skips a run that has not finished" do
      assert :skip = Kpis.SuccessRate.compute(%Input.Run{status: "pending"})
      assert :skip = Kpis.SuccessRate.compute(%Input.Run{status: nil})
    end
  end

  describe "LatencyP95" do
    test "reports the run latency" do
      assert {:ok, 1200.0} = Kpis.LatencyP95.compute(%Input.Run{latency_ms: 1200})
    end

    test "skips a run with no recorded latency" do
      assert :skip = Kpis.LatencyP95.compute(%Input.Run{latency_ms: nil})
    end

    test "aggregates as a p95 rather than a mean" do
      assert %Definition{aggregation: :p95, unit: :ms} = Kpis.LatencyP95.definition()
    end
  end

  describe "Toxicity" do
    test "reads the score LangSmith's evaluator attached to the run" do
      run = %Input.Run{feedback: %{"kpi.toxicity" => 0.02}}
      assert {:ok, 0.02} = Kpis.Toxicity.compute(run)
    end

    # Sampled KPIs are absent on most runs by design. That is a skip, not a zero.
    test "skips a run the evaluator did not score" do
      assert :skip = Kpis.Toxicity.compute(%Input.Run{feedback: %{}})
    end

    test "is sampled, since judging costs money" do
      definition = Kpis.Toxicity.definition()
      assert definition.kind == :judged
      assert definition.sample_rate < 1.0
    end

    test "declares the feedback key it imports" do
      assert [{:feedback, "kpi.toxicity"}] = Kpis.Toxicity.requires()
    end
  end

  describe "Sentiment" do
    test "reads the polarity score from feedback" do
      run = %Input.Run{feedback: %{"kpi.polarity" => 0.4}}
      assert {:ok, 0.4} = Kpis.Sentiment.compute(run)
    end

    test "skips an unscored run" do
      assert :skip = Kpis.Sentiment.compute(%Input.Run{feedback: %{}})
    end

    # The reason target_band exists. Relentless maximum positivity is a
    # malfunction, and a two-direction system would render it green.
    test "is banded, so both extremes are unhealthy" do
      definition = Kpis.Sentiment.definition()
      assert definition.direction == :target_band

      alias AgentLens.Kpi.Status
      assert :critical = Status.evaluate(definition, 1.0, sample_n: 100)
      assert :critical = Status.evaluate(definition, -1.0, sample_n: 100)
      assert :good = Status.evaluate(definition, 0.3, sample_n: 100)
    end
  end
end
