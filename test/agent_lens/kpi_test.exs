defmodule AgentLens.KpiTest do
  use ExUnit.Case, async: true

  alias AgentLens.Kpi

  defmodule Minimal do
    @moduledoc false
    use AgentLens.Kpi

    @impl true
    def definition do
      %AgentLens.Kpi.Definition{
        slug: :minimal,
        name: "Minimal",
        short_description: "The smallest KPI that can exist.",
        kind: :extracted,
        unit: :ratio,
        range: {0.0, 1.0},
        direction: :higher_is_better,
        aggregation: :mean,
        thresholds: %{warning: 0.5, critical: 0.2}
      }
    end

    @impl true
    def compute(%AgentLens.Kpi.Input.Run{}), do: {:ok, 1.0}
  end

  describe "use AgentLens.Kpi supplies defaults for the optional callbacks" do
    test "requires/0 defaults to no field dependencies" do
      assert [] = Minimal.requires()
    end

    test "depends_on/0 defaults to no KPI dependencies" do
      assert [] = Minimal.depends_on()
    end

    test "component/0 defaults to nil, meaning the generic card" do
      assert nil == Minimal.component()
    end

    test "the module is registered as implementing the behaviour" do
      assert Kpi.implemented_by?(Minimal)
    end
  end

  describe "implemented_by?/1" do
    test "is false for a module that does not implement the behaviour" do
      refute Kpi.implemented_by?(Enum)
    end

    test "is false for a module that does not exist" do
      refute Kpi.implemented_by?(AgentLens.Kpis.NoSuchThing)
    end
  end
end
