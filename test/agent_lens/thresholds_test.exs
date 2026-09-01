defmodule AgentLens.ThresholdsTest do
  use AgentLens.DataCase, async: false

  alias AgentLens.Kpi.Catalog
  alias AgentLens.Kpi.Registry
  alias AgentLens.Kpi.Status
  alias AgentLens.Thresholds

  @workspace "ws-support"

  setup do
    # An override references its KPI by foreign key, so the catalog has to be
    # present — which in production the boot sequence guarantees.
    {:ok, _count} = Catalog.sync!(Registry.load!())
    :ok
  end

  defp definition(slug) do
    {:ok, definition} = Registry.fetch_definition(Registry.load!(), slug)
    definition
  end

  describe "put/4" do
    test "stores an override for one agent" do
      assert {:ok, _record} =
               Thresholds.put(@workspace, definition(:toxicity), %{warning: 0.2, critical: 0.4})

      assert %{toxicity: %{warning: 0.2, critical: 0.4}} = Thresholds.for_agent(@workspace)
    end

    test "replaces an existing override rather than accumulating" do
      {:ok, _} = Thresholds.put(@workspace, definition(:toxicity), %{warning: 0.2, critical: 0.4})
      {:ok, _} = Thresholds.put(@workspace, definition(:toxicity), %{warning: 0.3, critical: 0.5})

      assert %{toxicity: %{warning: 0.3}} = Thresholds.for_agent(@workspace)
    end

    test "does not leak between agents" do
      {:ok, _} = Thresholds.put(@workspace, definition(:toxicity), %{warning: 0.2, critical: 0.4})

      assert Thresholds.for_agent("ws-research") == %{}
    end

    test "round-trips a banded threshold, which has no JSON tuple" do
      bands = %{good: {-0.2, 0.6}, warning: {-0.5, 0.8}}

      {:ok, _} = Thresholds.put(@workspace, definition(:sentiment), bands)

      assert %{sentiment: ^bands} = Thresholds.for_agent(@workspace)
    end
  end

  # An override can move where the lines sit. It must not be able to change what
  # kind of judgement the KPI makes.
  describe "put/4 rejects an incoherent override" do
    test "refuses a monotonic pair in the wrong order" do
      assert {:error, message} =
               Thresholds.put(@workspace, definition(:toxicity), %{warning: 0.5, critical: 0.1})

      assert message =~ "warning"
    end

    test "refuses a monotonic shape on a banded KPI" do
      assert {:error, _} =
               Thresholds.put(@workspace, definition(:sentiment), %{warning: 0.1, critical: 0.2})
    end

    test "refuses thresholds outside the KPI's declared range" do
      assert {:error, message} =
               Thresholds.put(@workspace, definition(:toxicity), %{warning: 0.5, critical: 5.0})

      assert message =~ "range"
    end

    test "allows an unbounded KPI to be set high" do
      assert {:ok, _} =
               Thresholds.put(@workspace, definition(:latency_p95), %{
                 warning: 30_000.0,
                 critical: 60_000.0
               })
    end
  end

  describe "apply_override/2" do
    test "replaces the definition's thresholds" do
      overrides = %{toxicity: %{warning: 0.2, critical: 0.4}}

      assert %{thresholds: %{warning: 0.2}} =
               Thresholds.apply_override(definition(:toxicity), overrides)
    end

    test "leaves a KPI with no override untouched" do
      original = definition(:toxicity)

      assert Thresholds.apply_override(original, %{}) == original
    end

    # The point of the whole feature: a tuned threshold has to change the
    # verdict, not just the number on the form.
    test "changes the status a value evaluates to" do
      original = definition(:toxicity)
      value = 0.10

      assert :warning = Status.evaluate(original, value, sample_n: 100)

      relaxed = Thresholds.apply_override(original, %{toxicity: %{warning: 0.2, critical: 0.4}})
      assert :good = Status.evaluate(relaxed, value, sample_n: 100)

      strict = Thresholds.apply_override(original, %{toxicity: %{warning: 0.01, critical: 0.05}})
      assert :critical = Status.evaluate(strict, value, sample_n: 100)
    end
  end

  describe "delete/3" do
    test "returns the KPI to its shipped defaults" do
      shipped = definition(:toxicity).thresholds
      {:ok, _} = Thresholds.put(@workspace, definition(:toxicity), %{warning: 0.2, critical: 0.4})

      :ok = Thresholds.delete(@workspace, :toxicity)

      assert Thresholds.for_agent(@workspace) == %{}
      assert Thresholds.effective(definition(:toxicity), @workspace) == shipped
    end

    test "is harmless when there is no override" do
      assert :ok = Thresholds.delete(@workspace, :toxicity)
    end
  end

  describe "overridden?/3" do
    test "reports whether an agent has tuned a KPI" do
      refute Thresholds.overridden?(@workspace, :toxicity)

      {:ok, _} = Thresholds.put(@workspace, definition(:toxicity), %{warning: 0.2, critical: 0.4})

      assert Thresholds.overridden?(@workspace, :toxicity)
    end
  end
end
