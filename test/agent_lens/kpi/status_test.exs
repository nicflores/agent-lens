defmodule AgentLens.Kpi.StatusTest do
  use ExUnit.Case, async: true

  alias AgentLens.Kpi.Definition
  alias AgentLens.Kpi.Status

  defp definition(overrides \\ []) do
    attrs =
      [
        slug: :success_rate,
        name: "Success Rate",
        short_description: "Share of runs that completed without error.",
        kind: :extracted,
        unit: :ratio,
        range: {0.0, 1.0},
        direction: :higher_is_better,
        aggregation: :rate,
        thresholds: %{warning: 0.95, critical: 0.9},
        health_contribution: :critical,
        min_sample_n: 20
      ]
      |> Keyword.merge(overrides)
      |> Map.new()

    {:ok, definition} = Definition.new(attrs)
    definition
  end

  describe "evaluate/3 delegates to the thresholds once the value is trustworthy" do
    test "returns the threshold classification when the sample is adequate" do
      assert :good = Status.evaluate(definition(), 0.99, sample_n: 100)
      assert :warning = Status.evaluate(definition(), 0.92, sample_n: 100)
      assert :critical = Status.evaluate(definition(), 0.5, sample_n: 100)
    end
  end

  # The whole point of the fourth state. Anything that looks healthy but isn't
  # measured is the most dangerous thing a dashboard can render.
  describe "evaluate/3 returns :unknown rather than a misleading status" do
    test "when there is no value at all" do
      assert :unknown = Status.evaluate(definition(), nil, sample_n: 100)
    end

    test "when the sample is below min_sample_n" do
      assert :unknown = Status.evaluate(definition(), 0.99, sample_n: 19)
    end

    test "when the sample size is unknown but the KPI requires a minimum" do
      assert :unknown = Status.evaluate(definition(), 0.99, [])
    end

    test "when the data is older than the staleness window" do
      observed = DateTime.add(DateTime.utc_now(), -3600, :second)

      assert :unknown =
               Status.evaluate(definition(), 0.99,
                 sample_n: 100,
                 observed_at: observed,
                 max_age: 600
               )
    end

    test "but not when the data is inside the staleness window" do
      observed = DateTime.add(DateTime.utc_now(), -60, :second)

      assert :good =
               Status.evaluate(definition(), 0.99,
                 sample_n: 100,
                 observed_at: observed,
                 max_age: 600
               )
    end

    test "a value that would otherwise be critical is still :unknown when undersampled" do
      assert :unknown = Status.evaluate(definition(), 0.1, sample_n: 2)
    end
  end

  describe "evaluate/3 with no minimum sample" do
    test "accepts a missing sample_n when min_sample_n is zero" do
      assert :good = Status.evaluate(definition(min_sample_n: 0), 0.99, [])
    end
  end

  describe "apply_hysteresis/3" do
    test "holds the previous status until N consecutive buckets agree" do
      assert :good = Status.apply_hysteresis(:good, [:warning, :good, :good], 3)
      assert :good = Status.apply_hysteresis(:good, [:warning, :warning, :good], 3)
    end

    test "flips once N consecutive buckets agree" do
      assert :warning = Status.apply_hysteresis(:good, [:warning, :warning, :warning], 3)
    end

    test "ignores older buckets beyond the window" do
      assert :warning = Status.apply_hysteresis(:good, [:warning, :warning, :warning, :good], 3)
    end

    test "holds when there is not yet enough history to justify a flip" do
      assert :good = Status.apply_hysteresis(:good, [:warning, :warning], 3)
    end

    test "adopts the latest status immediately when there is no previous status" do
      assert :warning = Status.apply_hysteresis(nil, [:warning, :good, :good], 3)
    end

    test "stays put when the recent buckets already match the previous status" do
      assert :good = Status.apply_hysteresis(:good, [:good, :good, :good], 3)
    end

    test "treats a run of one as no damping" do
      assert :critical = Status.apply_hysteresis(:good, [:critical], 1)
    end

    test "holds the previous status when there is no history at all" do
      assert :good = Status.apply_hysteresis(:good, [], 3)
    end
  end

  # Folding hysteresis over a whole series, which is what the read path needs:
  # it has buckets, not a remembered previous status.
  describe "stabilize/2" do
    test "adopts the first status when there is no history to damp against" do
      assert :good = Status.stabilize([:good], 3)
    end

    test "ignores a single bucket crossing a threshold" do
      assert :good = Status.stabilize([:good, :good, :good, :critical], 3)
    end

    test "ignores an oscillation around a boundary" do
      assert :good = Status.stabilize([:good, :warning, :good, :warning, :good, :warning], 3)
    end

    test "flips once the crossing is sustained" do
      assert :critical = Status.stabilize([:good, :good, :critical, :critical, :critical], 3)
    end

    test "flips back when recovery is sustained" do
      statuses = [:critical, :critical, :critical, :good, :good, :good]

      assert :good = Status.stabilize(statuses, 3)
    end

    test "holds through a recovery that is not yet convincing" do
      statuses = [:critical, :critical, :critical, :good, :good]

      assert :critical = Status.stabilize(statuses, 3)
    end

    test "a run length of one means no damping at all" do
      assert :critical = Status.stabilize([:good, :good, :critical], 1)
    end

    test "has nothing to say about an empty series" do
      assert nil == Status.stabilize([], 3)
    end
  end

  describe "roll_up/1 for the agent-level badge" do
    test "takes the worst contributing status" do
      assert :critical =
               Status.roll_up([
                 {definition(), :good},
                 {definition(), :critical},
                 {definition(), :warning}
               ])
    end

    test "ranks :unknown as worse than :good but better than :warning" do
      assert :unknown = Status.roll_up([{definition(), :good}, {definition(), :unknown}])

      assert :warning =
               Status.roll_up([{definition(), :unknown}, {definition(), :warning}])
    end

    # Token consumption is informational. It must not be able to turn an
    # otherwise healthy agent red.
    test "ignores KPIs that do not contribute to health" do
      non_contributing = definition(health_contribution: :none)

      assert :good = Status.roll_up([{definition(), :good}, {non_contributing, :critical}])
    end

    test "is :unknown when nothing contributes" do
      assert :unknown = Status.roll_up([{definition(health_contribution: :none), :critical}])
      assert :unknown = Status.roll_up([])
    end
  end
end
