defmodule AgentLens.Kpi do
  @moduledoc """
  The behaviour every KPI implements.

  This is the extensibility seam of the whole system. Adding a KPI is one module
  implementing this behaviour plus one line in the `:kpis` list in
  `config/config.exs` — nothing else. Rollups read `aggregation` from the
  definition rather than branching on slug, and the UI renders from the
  definition rather than from bespoke markup, so neither has to change.

  ## A minimal KPI

      defmodule AgentLens.Kpis.SuccessRate do
        use AgentLens.Kpi

        alias AgentLens.Kpi.Definition
        alias AgentLens.Kpi.Input

        @impl true
        def definition do
          %Definition{slug: :success_rate, ...}
        end

        @impl true
        def requires, do: [:status]

        @impl true
        def compute(%Input.Run{status: "success"}), do: {:ok, 1.0}
        def compute(%Input.Run{}), do: {:ok, 0.0}
      end

  `use AgentLens.Kpi` supplies defaults for the optional callbacks, so a module
  only defines what it actually needs.
  """

  alias AgentLens.Kpi.Definition
  alias AgentLens.Kpi.FieldManifest
  alias AgentLens.Kpi.Input

  @doc """
  The KPI's declarative description: identity, units, direction, thresholds, and
  how it aggregates. Read at boot and stored, never consulted on the data path.
  """
  @callback definition() :: Definition.t()

  @doc """
  The run fields this KPI reads, validated against `AgentLens.Kpi.FieldManifest`
  at boot so a missing field is a startup error rather than a `nil` crash later.
  """
  @callback requires() :: [FieldManifest.path()]

  @doc """
  Computes the KPI.

  Returns `{:ok, value}`, `{:ok, value, metadata}` when there is provenance
  worth retaining (a judge model, a confidence), or `:skip` when this input
  legitimately carries no observation — which is not the same as a zero and must
  never be recorded as one.
  """
  @callback compute(Input.t()) :: {:ok, float()} | {:ok, float(), map()} | :skip

  @doc """
  Other KPI slugs whose series this one is computed from. Only `:derived` KPIs
  declare dependencies; the registry validates them and rejects cycles.
  """
  @callback depends_on() :: [atom()]

  @doc """
  An optional bespoke renderer. Defaults to `nil`, meaning the generic card
  driven entirely by the definition.
  """
  @callback component() :: module() | nil

  @optional_callbacks requires: 0, depends_on: 0, component: 0

  @doc false
  defmacro __using__(_opts) do
    quote do
      @behaviour AgentLens.Kpi

      @impl true
      def requires, do: []

      @impl true
      def depends_on, do: []

      @impl true
      def component, do: nil

      defoverridable requires: 0, depends_on: 0, component: 0
    end
  end

  @doc """
  Whether a module implements this behaviour.

  Used by the registry to reject a misconfigured entry with a clear message
  rather than an `UndefinedFunctionError`.
  """
  @spec implemented_by?(module()) :: boolean()
  def implemented_by?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and
      function_exported?(module, :definition, 0) and
      function_exported?(module, :compute, 1)
  end
end
