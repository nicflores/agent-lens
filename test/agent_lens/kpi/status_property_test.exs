defmodule AgentLens.Kpi.StatusPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias AgentLens.Kpi.Definition
  alias AgentLens.Kpi.Status

  @min_sample_n 20

  defp definition(overrides) do
    attrs =
      [
        slug: :property,
        name: "Property",
        short_description: "A KPI used to check invariants.",
        kind: :extracted,
        unit: :ratio,
        aggregation: :mean,
        health_contribution: :normal,
        min_sample_n: @min_sample_n
      ]
      |> Keyword.merge(overrides)
      |> Map.new()

    {:ok, definition} = Definition.new(attrs)
    definition
  end

  defp rank(:good), do: 0
  defp rank(:unknown), do: 1
  defp rank(:warning), do: 2
  defp rank(:critical), do: 3

  defp value, do: float(min: -1000.0, max: 1000.0)

  describe "monotonic directions are monotonic in the value" do
    property "for :higher_is_better, a larger value is never a worse status" do
      definition =
        definition(
          direction: :higher_is_better,
          thresholds: %{warning: 10.0, critical: 0.0}
        )

      check all(a <- value(), b <- value()) do
        {lower, higher} = if a <= b, do: {a, b}, else: {b, a}

        status_lower = Status.evaluate(definition, lower, sample_n: 100)
        status_higher = Status.evaluate(definition, higher, sample_n: 100)

        assert rank(status_higher) <= rank(status_lower)
      end
    end

    property "for :lower_is_better, a smaller value is never a worse status" do
      definition =
        definition(
          direction: :lower_is_better,
          thresholds: %{warning: 0.0, critical: 10.0}
        )

      check all(a <- value(), b <- value()) do
        {lower, higher} = if a <= b, do: {a, b}, else: {b, a}

        status_lower = Status.evaluate(definition, lower, sample_n: 100)
        status_higher = Status.evaluate(definition, higher, sample_n: 100)

        assert rank(status_lower) <= rank(status_higher)
      end
    end
  end

  describe "an inadequate sample always wins" do
    property "no value produces a non-:unknown status below min_sample_n" do
      definition =
        definition(
          direction: :higher_is_better,
          thresholds: %{warning: 10.0, critical: 0.0}
        )

      check all(
              v <- value(),
              sample_n <- integer(0..(@min_sample_n - 1))
            ) do
        assert :unknown = Status.evaluate(definition, v, sample_n: sample_n)
      end
    end

    property "and every value produces a definite status at or above it" do
      definition =
        definition(
          direction: :higher_is_better,
          thresholds: %{warning: 10.0, critical: 0.0}
        )

      check all(
              v <- value(),
              sample_n <- integer(@min_sample_n..1000)
            ) do
        refute Status.evaluate(definition, v, sample_n: sample_n) == :unknown
      end
    end
  end

  describe "banded directions are not monotonic, by design" do
    property "any value inside the good band is :good" do
      definition =
        definition(
          direction: :target_band,
          thresholds: %{good: {-0.1, 0.7}, warning: {-0.4, 0.9}}
        )

      check all(v <- float(min: -0.1, max: 0.7)) do
        assert :good = Status.evaluate(definition, v, sample_n: 100)
      end
    end

    property "any value outside the warning band is :critical, at either extreme" do
      definition =
        definition(
          direction: :target_band,
          thresholds: %{good: {-0.1, 0.7}, warning: {-0.4, 0.9}}
        )

      check all(
              magnitude <- float(min: 0.001, max: 100.0),
              sign <- member_of([-1, 1])
            ) do
        v = if sign == 1, do: 0.9 + magnitude, else: -0.4 - magnitude

        assert :critical = Status.evaluate(definition, v, sample_n: 100)
      end
    end
  end
end
