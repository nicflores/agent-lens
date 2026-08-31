defmodule AgentLens.Kpi.Extraction do
  @moduledoc """
  Runs the KPI modules against an ingested run and returns observation rows.

  Pure: it takes a registry and an input and gives back attribute maps. The
  caller decides what to do with them.

  Splits by kind, because the three kinds are on different schedules:

    * `:extracted` — free arithmetic on the payload, computed here on every run
    * `:judged` — scored elsewhere and imported through the feedback path
    * `:derived` — computed on bucket close from other KPIs' rollups

  A KPI returning `:skip` produces no row at all. That distinction carries all
  the way to the dashboard: a missing observation renders as unknown, while a
  zero would render as a confident, wrong number.
  """

  alias AgentLens.Kpi.Definition
  alias AgentLens.Kpi.Input
  alias AgentLens.Kpi.Registry

  @doc """
  Computes every `:extracted` KPI for a run.

  ## Options

    * `:run_id` — the stored run's id, linking observations back to it
  """
  @spec from_run(Registry.t(), Input.Run.t(), keyword()) :: [map()]
  def from_run(registry, %Input.Run{} = input, opts \\ []) do
    registry
    |> entries_of_kind(:extracted)
    |> Enum.flat_map(fn %{module: module, definition: definition} ->
      observe(module.compute(input), definition, input, "extracted", opts)
    end)
  end

  @doc """
  Maps the feedback attached to a run onto observations.

  A feedback key with no matching KPI is ignored rather than stored: LangSmith
  may carry evaluators this build does not know about, and that is not an error.
  """
  @spec from_feedback(Registry.t(), Input.Run.t(), keyword()) :: [map()]
  def from_feedback(registry, %Input.Run{} = input, opts \\ []) do
    by_key = feedback_index(registry)

    input.feedback
    |> Enum.flat_map(fn {key, score} ->
      case Map.fetch(by_key, key) do
        {:ok, %{module: module, definition: definition}} ->
          observe(module.compute(input), definition, input, "imported", opts)

        :error ->
          _ = score
          []
      end
    end)
    |> Enum.sort_by(& &1.kpi_slug)
  end

  @doc """
  Indexes the KPIs that import a LangSmith feedback key, keyed by that key.

  Built from each module's `requires/0`, so the mapping follows the declared
  dependency rather than a second list that could drift out of step with it.
  """
  @spec feedback_index(Registry.t()) :: %{optional(String.t()) => Registry.entry()}
  def feedback_index(registry) do
    for entry <- Map.values(registry),
        {:feedback, key} <- entry.module.requires(),
        into: %{} do
      {key, entry}
    end
  end

  defp entries_of_kind(registry, kind) do
    registry
    |> Map.values()
    |> Enum.filter(&(&1.definition.kind == kind))
    |> Enum.sort_by(& &1.definition.slug)
  end

  defp observe(:skip, _definition, _input, _source, _opts), do: []

  defp observe({:ok, value}, definition, input, source, opts),
    do: observe({:ok, value, %{}}, definition, input, source, opts)

  defp observe({:ok, value, metadata}, %Definition{} = definition, input, source, opts) do
    [
      %{
        run_id: Keyword.get(opts, :run_id),
        agent_id: input.agent_id,
        kpi_slug: Atom.to_string(definition.slug),
        value: value * 1.0,
        source: source,
        kpi_version: definition.version,
        judge_model: Map.get(metadata, :judge_model),
        metadata: Map.drop(metadata, [:judge_model]),
        occurred_at: input.start_time
      }
    ]
  end
end
