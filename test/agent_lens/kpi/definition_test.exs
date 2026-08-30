defmodule AgentLens.Kpi.DefinitionTest do
  use ExUnit.Case, async: true

  alias AgentLens.Kpi.Definition

  @valid [
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

  defp valid(overrides \\ []), do: @valid |> Keyword.merge(overrides) |> Map.new()

  describe "new/1" do
    test "builds a definition from valid attributes" do
      assert {:ok, definition} = Definition.new(valid())
      assert definition.slug == :success_rate
      assert definition.aggregation == :rate
    end

    test "applies defaults for the optional fields" do
      assert {:ok, definition} = Definition.new(valid())
      assert definition.version == 1
      assert definition.sample_rate == 1.0
      assert definition.methodology == nil
    end
  end

  describe "enumerated fields" do
    test "rejects an unknown kind" do
      assert {:error, message} = Definition.new(valid(kind: :vibes))
      assert message =~ "kind"
    end

    test "rejects an unknown unit" do
      assert {:error, _} = Definition.new(valid(unit: :furlongs))
    end

    test "rejects an unknown aggregation" do
      assert {:error, _} = Definition.new(valid(aggregation: :mode))
    end

    test "rejects an unknown health_contribution" do
      assert {:error, _} = Definition.new(valid(health_contribution: :sorta))
    end
  end

  describe "required fields" do
    test "rejects a missing slug" do
      assert {:error, message} = valid() |> Map.delete(:slug) |> Definition.new()
      assert message =~ "slug"
    end

    test "rejects a blank name" do
      assert {:error, _} = Definition.new(valid(name: "   "))
    end

    test "rejects a missing short_description, since the UI shows it as the card tooltip" do
      assert {:error, _} = valid() |> Map.delete(:short_description) |> Definition.new()
    end
  end

  describe "thresholds and direction are validated together" do
    test "rejects a monotonic threshold shape on a banded direction" do
      assert {:error, _} =
               Definition.new(
                 valid(direction: :target_band, thresholds: %{warning: 1, critical: 2})
               )
    end

    test "accepts a banded threshold shape on a banded direction" do
      assert {:ok, _} =
               Definition.new(
                 valid(
                   direction: :target_band,
                   thresholds: %{good: {0.3, 0.7}, warning: {0.1, 0.9}}
                 )
               )
    end

    test "rejects an incoherent monotonic pair" do
      assert {:error, _} = Definition.new(valid(thresholds: %{warning: 0.9, critical: 0.95}))
    end
  end

  describe "range" do
    test "accepts a nil range" do
      assert {:ok, %Definition{range: nil}} = Definition.new(valid(range: nil))
    end

    test "rejects thresholds that fall outside the declared range" do
      assert {:error, message} =
               Definition.new(
                 valid(range: {0.0, 0.5}, thresholds: %{warning: 0.95, critical: 0.9})
               )

      assert message =~ "range"
    end

    test "rejects an inverted range" do
      assert {:error, _} = Definition.new(valid(range: {1.0, 0.0}))
    end
  end

  describe "sample_rate" do
    test "accepts a fractional rate for a judged KPI" do
      assert {:ok, %Definition{sample_rate: 0.1}} =
               Definition.new(valid(kind: :judged, sample_rate: 0.1))
    end

    test "rejects a rate above 1.0" do
      assert {:error, _} = Definition.new(valid(kind: :judged, sample_rate: 1.5))
    end

    test "rejects a zero rate, which would silently never sample" do
      assert {:error, _} = Definition.new(valid(kind: :judged, sample_rate: 0.0))
    end

    # Extracted KPIs are computed inline on every run; asking for a sample of
    # them is a config error rather than a cost saving.
    test "rejects sampling on a non-judged KPI" do
      assert {:error, message} = Definition.new(valid(kind: :extracted, sample_rate: 0.5))
      assert message =~ "sample_rate"
    end
  end

  describe "version" do
    test "rejects a non-positive version" do
      assert {:error, _} = Definition.new(valid(version: 0))
    end
  end
end
