defmodule AgentLens.Kpi.RegistryTest do
  use ExUnit.Case, async: true

  alias AgentLens.Kpi.Definition
  alias AgentLens.Kpi.Registry
  alias AgentLens.Kpi.Status
  alias AgentLens.Kpis

  @real [Kpis.SuccessRate, Kpis.LatencyP95, Kpis.Toxicity, Kpis.Sentiment, Kpis.Drift]

  defp base_definition(overrides) do
    struct(
      %Definition{
        slug: :placeholder,
        name: "Placeholder",
        short_description: "A KPI defined inside a test.",
        kind: :extracted,
        unit: :ratio,
        range: {0.0, 1.0},
        direction: :higher_is_better,
        aggregation: :mean,
        thresholds: %{warning: 0.5, critical: 0.2}
      },
      Map.new(overrides)
    )
  end

  defmodule BadField do
    @moduledoc false
    use AgentLens.Kpi

    @impl true
    def definition do
      %Definition{
        slug: :bad_field,
        name: "Bad Field",
        short_description: "Requires a field that was never stored.",
        kind: :extracted,
        unit: :ratio,
        range: {0.0, 1.0},
        direction: :higher_is_better,
        aggregation: :mean,
        thresholds: %{warning: 0.5, critical: 0.2}
      }
    end

    @impl true
    def requires, do: [:ttft_ms]

    @impl true
    def compute(_input), do: :skip
  end

  defmodule DanglingDependency do
    @moduledoc false
    use AgentLens.Kpi

    @impl true
    def definition do
      %Definition{
        slug: :dangling,
        name: "Dangling",
        short_description: "Depends on a KPI that is not registered.",
        kind: :derived,
        unit: :ratio,
        range: {0.0, 1.0},
        direction: :higher_is_better,
        aggregation: :mean,
        thresholds: %{warning: 0.5, critical: 0.2}
      }
    end

    @impl true
    def depends_on, do: [:no_such_kpi]

    @impl true
    def compute(_input), do: :skip
  end

  defmodule CycleA do
    @moduledoc false
    use AgentLens.Kpi

    @impl true
    def definition do
      %Definition{
        slug: :cycle_a,
        name: "Cycle A",
        short_description: "Half of a dependency cycle.",
        kind: :derived,
        unit: :ratio,
        range: {0.0, 1.0},
        direction: :higher_is_better,
        aggregation: :mean,
        thresholds: %{warning: 0.5, critical: 0.2}
      }
    end

    @impl true
    def depends_on, do: [:cycle_b]

    @impl true
    def compute(_input), do: :skip
  end

  defmodule CycleB do
    @moduledoc false
    use AgentLens.Kpi

    @impl true
    def definition do
      %Definition{
        slug: :cycle_b,
        name: "Cycle B",
        short_description: "The other half of a dependency cycle.",
        kind: :derived,
        unit: :ratio,
        range: {0.0, 1.0},
        direction: :higher_is_better,
        aggregation: :mean,
        thresholds: %{warning: 0.5, critical: 0.2}
      }
    end

    @impl true
    def depends_on, do: [:cycle_a]

    @impl true
    def compute(_input), do: :skip
  end

  defmodule Duplicate do
    @moduledoc false
    use AgentLens.Kpi

    @impl true
    def definition do
      %Definition{
        slug: :success_rate,
        name: "Also Success Rate",
        short_description: "Claims a slug another module already owns.",
        kind: :extracted,
        unit: :ratio,
        range: {0.0, 1.0},
        direction: :higher_is_better,
        aggregation: :mean,
        thresholds: %{warning: 0.5, critical: 0.2}
      }
    end

    @impl true
    def compute(_input), do: :skip
  end

  describe "build/1 with the configured KPIs" do
    test "registers every module by slug" do
      assert {:ok, registry} = Registry.build(@real)

      assert Map.keys(registry) |> Enum.sort() ==
               [:latency_drift, :latency_p95, :sentiment, :success_rate, :toxicity]
    end

    test "carries both the module and its validated definition" do
      assert {:ok, registry} = Registry.build(@real)
      assert %{module: Kpis.SuccessRate, definition: %Definition{}} = registry[:success_rate]
    end

    test "accepts an empty list" do
      assert {:ok, registry} = Registry.build([])
      assert registry == %{}
    end
  end

  describe "build/1 refuses invalid configurations" do
    test "rejects a module that does not implement the behaviour" do
      assert {:error, message} = Registry.build([Enum])
      assert message =~ "Enum"
    end

    test "rejects a module that does not exist" do
      assert {:error, message} = Registry.build([AgentLens.Kpis.Imaginary])
      assert message =~ "Imaginary"
    end

    # The mechanism that turns a 3am nil crash into a startup failure.
    test "rejects a KPI requiring a field that was never stored, naming the field" do
      assert {:error, message} = Registry.build([BadField])
      assert message =~ "ttft_ms"
      assert message =~ "BadField"
    end

    test "rejects a dependency on an unregistered KPI" do
      assert {:error, message} = Registry.build([DanglingDependency])
      assert message =~ "no_such_kpi"
    end

    test "rejects a dependency cycle" do
      assert {:error, message} = Registry.build([CycleA, CycleB])
      assert message =~ "cycle"
    end

    test "rejects two modules claiming the same slug" do
      assert {:error, message} = Registry.build([Kpis.SuccessRate, Duplicate])
      assert message =~ "success_rate"
    end

    test "rejects an invalid definition and names the module" do
      defmodule Invalid do
        @moduledoc false
        use AgentLens.Kpi

        @impl true
        def definition do
          %Definition{
            slug: :invalid,
            name: "Invalid",
            short_description: "Thresholds that contradict the direction.",
            kind: :extracted,
            unit: :ratio,
            range: {0.0, 1.0},
            direction: :higher_is_better,
            aggregation: :mean,
            thresholds: %{warning: 0.2, critical: 0.5}
          }
        end

        @impl true
        def compute(_input), do: :skip
      end

      assert {:error, message} = Registry.build([Invalid])
      assert message =~ "Invalid"
    end
  end

  describe "build!/1" do
    test "returns the registry when valid" do
      assert %{} = Registry.build!(@real)
    end

    # Section 5: a bad KPI config must refuse to boot rather than crash a
    # worker later.
    test "raises rather than returning a partial registry" do
      assert_raise RuntimeError, ~r/ttft_ms/, fn -> Registry.build!([BadField]) end
    end
  end

  describe "load!/0" do
    test "builds from application config" do
      registry = Registry.load!()
      assert Map.has_key?(registry, :success_rate)
    end
  end

  describe "lookups" do
    setup do
      %{registry: Registry.build!(@real)}
    end

    test "fetches a definition by slug", %{registry: registry} do
      assert {:ok, %Definition{slug: :toxicity}} = Registry.fetch_definition(registry, :toxicity)
    end

    test "returns :error for an unregistered slug", %{registry: registry} do
      assert :error = Registry.fetch_definition(registry, :nope)
    end

    test "lists definitions of a given kind", %{registry: registry} do
      slugs = registry |> Registry.by_kind(:derived) |> Enum.map(& &1.slug)
      assert slugs == [:latency_drift]
    end
  end

  # ── The acceptance test for Phase 1 ──────────────────────────────────────
  #
  # The claim is that adding a KPI is one new module plus one config line, and
  # that nothing else in the system needs to change. This asserts it rather
  # than trusting it: a KPI defined entirely here registers, validates, and
  # produces a status through the shared machinery.
  describe "adding a KPI requires no changes outside the module and config" do
    defmodule BrandNew do
      @moduledoc false
      use AgentLens.Kpi

      alias AgentLens.Kpi.Input

      @impl true
      def definition do
        %Definition{
          slug: :cache_hit_rate,
          name: "Cache Hit Rate",
          short_description: "Share of runs served from the prompt cache.",
          kind: :extracted,
          unit: :ratio,
          range: {0.0, 1.0},
          direction: :higher_is_better,
          aggregation: :rate,
          thresholds: %{warning: 0.6, critical: 0.3},
          health_contribution: :none,
          min_sample_n: 10
        }
      end

      @impl true
      def requires, do: [{:payload, ["extra", "metadata", "cache_hit"]}]

      @impl true
      def compute(%Input.Run{} = run) do
        case Input.Run.fetch(run, {:payload, ["extra", "metadata", "cache_hit"]}) do
          {:ok, true} -> {:ok, 1.0}
          {:ok, false} -> {:ok, 0.0}
          _other -> :skip
        end
      end
    end

    test "the new KPI registers alongside the existing ones" do
      assert {:ok, registry} = Registry.build(@real ++ [BrandNew])
      assert %{definition: %Definition{name: "Cache Hit Rate"}} = registry[:cache_hit_rate]
    end

    test "its status evaluates through the same machinery, with no new code" do
      registry = Registry.build!(@real ++ [BrandNew])
      {:ok, definition} = Registry.fetch_definition(registry, :cache_hit_rate)

      assert :good = Status.evaluate(definition, 0.9, sample_n: 50)
      assert :critical = Status.evaluate(definition, 0.1, sample_n: 50)
      assert :unknown = Status.evaluate(definition, 0.9, sample_n: 3)
    end

    test "and it is excluded from agent health, as its definition asks" do
      registry = Registry.build!(@real ++ [BrandNew])
      {:ok, definition} = Registry.fetch_definition(registry, :cache_hit_rate)

      assert :unknown = Status.roll_up([{definition, :critical}])
    end

    test "the placeholder helper builds a definition usable without any module" do
      assert :ok = base_definition(slug: :ad_hoc) |> Definition.validate()
    end
  end
end
