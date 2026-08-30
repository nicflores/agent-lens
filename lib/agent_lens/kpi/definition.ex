defmodule AgentLens.Kpi.Definition do
  @moduledoc """
  The declarative description of a KPI.

  Everything downstream — rollups, status evaluation, the dashboard — reads a
  `%Definition{}` rather than knowing anything about the module that produced
  it. That indirection is what lets a new KPI module propagate to the rollup
  layer and the UI without either being modified.

  In particular `aggregation` is *data*, not code. If a new KPI ever requires
  touching the rollup module, the abstraction has leaked.
  """

  alias AgentLens.Kpi.Thresholds

  @kinds [:extracted, :judged, :derived]
  @units [:ratio, :ms, :count, :usd, :score]
  @aggregations [:mean, :p50, :p95, :p99, :rate, :count, :count_distinct]
  @health_contributions [:none, :normal, :critical]
  @directions [:higher_is_better, :lower_is_better, :target_band]

  @required [
    :slug,
    :name,
    :short_description,
    :kind,
    :unit,
    :direction,
    :aggregation,
    :thresholds,
    :health_contribution
  ]

  @enforce_keys [:slug, :name, :short_description]
  defstruct [
    :slug,
    :name,
    :short_description,
    :methodology,
    :kind,
    :unit,
    :range,
    :direction,
    :aggregation,
    :thresholds,
    health_contribution: :normal,
    min_sample_n: 0,
    sample_rate: 1.0,
    version: 1
  ]

  @type kind :: :extracted | :judged | :derived
  @type unit :: :ratio | :ms | :count | :usd | :score
  @type aggregation :: :mean | :p50 | :p95 | :p99 | :rate | :count | :count_distinct
  @type health_contribution :: :none | :normal | :critical

  @type t :: %__MODULE__{
          slug: atom(),
          name: String.t(),
          short_description: String.t(),
          methodology: String.t() | nil,
          kind: kind(),
          unit: unit(),
          range: {number(), number()} | nil,
          direction: Thresholds.direction(),
          aggregation: aggregation(),
          thresholds: Thresholds.t(),
          health_contribution: health_contribution(),
          min_sample_n: non_neg_integer(),
          sample_rate: float(),
          version: pos_integer()
        }

  @doc "Returns the permitted values for each enumerated field."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @spec aggregations() :: [aggregation()]
  def aggregations, do: @aggregations

  @doc """
  Builds a definition from attributes, validating it.

  Unknown keys are ignored; missing ones fall back to the struct defaults and
  are then caught by validation.
  """
  @spec new(map()) :: {:ok, t()} | {:error, String.t()}
  def new(attrs) when is_map(attrs) do
    definition = struct(__MODULE__, attrs)

    with :ok <- validate(definition) do
      {:ok, definition}
    end
  end

  @doc """
  Validates a definition's internal coherence.

  Called by `AgentLens.Kpi.Registry` at boot for every registered module, so a
  malformed definition refuses to start the application rather than surfacing
  as a confusing `nil` in a worker at 3am.
  """
  @spec validate(t()) :: :ok | {:error, String.t()}
  def validate(%__MODULE__{} = definition) do
    with :ok <- validate_required(definition),
         :ok <- validate_slug(definition),
         :ok <- validate_enums(definition),
         :ok <- validate_counters(definition),
         :ok <- validate_thresholds(definition),
         :ok <- validate_range(definition) do
      validate_sample_rate(definition)
    end
  end

  defp validate_required(definition) do
    Enum.reduce_while(@required, :ok, fn field, :ok ->
      case validate_present(field, Map.fetch!(definition, field)) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp validate_present(field, nil), do: {:error, "#{field} is required"}

  defp validate_present(field, value) when is_binary(value) do
    if String.trim(value) == "" do
      {:error, "#{field} must not be blank"}
    else
      :ok
    end
  end

  defp validate_present(_field, _value), do: :ok

  defp validate_slug(%{slug: slug}) when is_atom(slug), do: :ok

  defp validate_slug(%{slug: slug}),
    do: {:error, "slug must be an atom, got #{inspect(slug)}"}

  defp validate_enums(definition) do
    with :ok <- validate_inclusion(:kind, definition.kind, @kinds),
         :ok <- validate_inclusion(:unit, definition.unit, @units),
         :ok <- validate_inclusion(:direction, definition.direction, @directions),
         :ok <- validate_inclusion(:aggregation, definition.aggregation, @aggregations) do
      validate_inclusion(
        :health_contribution,
        definition.health_contribution,
        @health_contributions
      )
    end
  end

  defp validate_inclusion(field, value, allowed) do
    if value in allowed do
      :ok
    else
      {:error, "#{field} must be one of #{inspect(allowed)}, got #{inspect(value)}"}
    end
  end

  defp validate_counters(%{min_sample_n: n}) when not (is_integer(n) and n >= 0),
    do: {:error, "min_sample_n must be a non-negative integer, got #{inspect(n)}"}

  defp validate_counters(%{version: v}) when not (is_integer(v) and v > 0),
    do: {:error, "version must be a positive integer, got #{inspect(v)}"}

  defp validate_counters(_definition), do: :ok

  defp validate_thresholds(%{direction: direction, thresholds: thresholds}) do
    with {:ok, _thresholds} <- Thresholds.validate(direction, thresholds), do: :ok
  end

  defp validate_range(%{range: nil}), do: :ok

  defp validate_range(%{range: {min, max}} = definition)
       when is_number(min) and is_number(max) do
    cond do
      min > max ->
        {:error, "range is inverted, got {#{min}, #{max}}"}

      not within_range?(definition.direction, definition.thresholds, min, max) ->
        {:error, "thresholds fall outside the declared range {#{min}, #{max}}"}

      true ->
        :ok
    end
  end

  defp validate_range(%{range: other}),
    do: {:error, "range must be a {min, max} tuple or nil, got #{inspect(other)}"}

  defp within_range?(:target_band, %{warning: {low, high}}, min, max),
    do: low >= min and high <= max

  defp within_range?(_direction, %{warning: warning, critical: critical}, min, max),
    do: warning >= min and warning <= max and critical >= min and critical <= max

  defp validate_sample_rate(%{kind: :judged, sample_rate: rate})
       when is_number(rate) and rate > 0 and rate <= 1,
       do: :ok

  defp validate_sample_rate(%{kind: :judged, sample_rate: rate}),
    do: {:error, "sample_rate must be in (0, 1] for a judged KPI, got #{inspect(rate)}"}

  defp validate_sample_rate(%{sample_rate: 1.0}), do: :ok

  defp validate_sample_rate(%{kind: kind, sample_rate: rate}),
    do:
      {:error,
       "sample_rate #{inspect(rate)} is only meaningful for a judged KPI; " <>
         "#{inspect(kind)} KPIs are computed on every run"}
end
