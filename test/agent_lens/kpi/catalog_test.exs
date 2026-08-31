defmodule AgentLens.Kpi.CatalogTest do
  use AgentLens.DataCase, async: false

  alias AgentLens.Kpi.Catalog
  alias AgentLens.Kpi.Definition
  alias AgentLens.Kpi.Registry
  alias AgentLens.Repo
  alias AgentLens.Store.KpiDefinition

  defp registry, do: Registry.load!()

  describe "encoding a definition for storage" do
    test "flattens the range into two columns" do
      {:ok, definition} = Registry.fetch_definition(registry(), :success_rate)
      attrs = Catalog.to_attrs(definition)

      assert attrs.range_min == 0.0
      assert attrs.range_max == 1.0
    end

    test "stores a nil range as two nulls" do
      {:ok, definition} = Registry.fetch_definition(registry(), :latency_p95)
      attrs = Catalog.to_attrs(definition)

      assert attrs.range_min == nil
      assert attrs.range_max == nil
    end

    test "writes enumerated fields as strings" do
      {:ok, definition} = Registry.fetch_definition(registry(), :toxicity)
      attrs = Catalog.to_attrs(definition)

      assert attrs.slug == "toxicity"
      assert attrs.kind == "judged"
      assert attrs.direction == "lower_is_better"
    end

    # A tuple has no JSON representation, so a banded threshold has to survive
    # the trip as a pair of lists.
    test "encodes a banded threshold as lists" do
      {:ok, definition} = Registry.fetch_definition(registry(), :sentiment)
      attrs = Catalog.to_attrs(definition)

      assert attrs.thresholds == %{"good" => [-0.1, 0.7], "warning" => [-0.4, 0.9]}
    end

    test "encodes a monotonic threshold as scalars" do
      {:ok, definition} = Registry.fetch_definition(registry(), :success_rate)
      attrs = Catalog.to_attrs(definition)

      assert attrs.thresholds == %{"warning" => 0.95, "critical" => 0.9}
    end
  end

  # The property that matters: whatever a KPI module declares must come back
  # from the database unchanged, or the UI and the rollup layer are reading a
  # different KPI than the one that was defined.
  describe "round trip through the database" do
    test "every configured KPI survives a write and read unchanged" do
      registry = registry()
      {:ok, _count} = Catalog.sync!(registry)

      stored = Map.new(Catalog.all(), &{&1.slug, &1})

      for definition <- Registry.definitions(registry) do
        assert Map.fetch!(stored, definition.slug) == definition,
               "#{definition.slug} did not survive the round trip"
      end
    end

    test "the reloaded definitions still validate" do
      {:ok, _count} = Catalog.sync!(registry())

      for definition <- Catalog.all() do
        assert :ok = Definition.validate(definition)
      end
    end
  end

  describe "sync!/2" do
    test "inserts every configured definition" do
      assert {:ok, 5} = Catalog.sync!(registry())
      assert Repo.aggregate(KpiDefinition, :count) == 5
    end

    test "is idempotent across boots" do
      {:ok, 5} = Catalog.sync!(registry())
      {:ok, 5} = Catalog.sync!(registry())

      assert Repo.aggregate(KpiDefinition, :count) == 5
    end

    test "updates a definition whose module changed" do
      {:ok, _} = Catalog.sync!(registry())

      {:ok, original} = Registry.fetch_definition(registry(), :success_rate)
      changed = %Definition{original | name: "Completion Rate", version: 2}
      {:ok, _} = Catalog.sync!(%{success_rate: %{module: nil, definition: changed}})

      assert %KpiDefinition{name: "Completion Rate", version: 2} =
               Repo.get(KpiDefinition, "success_rate")
    end

    # first_observed_at records where a series legitimately starts. Re-running
    # the boot sync must never reset it, or every deploy would erase the
    # provenance of every chart.
    test "preserves first_observed_at across a re-sync" do
      {:ok, _} = Catalog.sync!(registry())

      observed = ~U[2026-01-15 08:30:00.000000Z]

      Repo.update_all(
        from(d in KpiDefinition, where: d.slug == "toxicity"),
        set: [first_observed_at: observed]
      )

      {:ok, _} = Catalog.sync!(registry())

      assert %KpiDefinition{first_observed_at: ^observed} = Repo.get(KpiDefinition, "toxicity")
    end
  end

  describe "all/1" do
    test "returns an empty list before anything is synced" do
      assert [] = Catalog.all()
    end

    test "skips rows whose KPI module is no longer configured" do
      {:ok, _} = Catalog.sync!(registry())

      Repo.insert!(%KpiDefinition{
        slug: "a_kpi_that_no_longer_exists",
        name: "Retired",
        short_description: "Left behind by a removed module.",
        kind: "extracted",
        unit: "ratio",
        direction: "higher_is_better",
        aggregation: "mean",
        thresholds: %{"warning" => 0.5, "critical" => 0.2},
        health_contribution: "normal",
        min_sample_n: 0,
        sample_rate: 1.0,
        version: 1
      })

      slugs = Catalog.all() |> Enum.map(& &1.slug)

      assert length(slugs) == 5
      assert Enum.all?(slugs, &is_atom/1)
    end
  end
end
