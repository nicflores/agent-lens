defmodule AgentLens.Kpi.Catalog do
  @moduledoc """
  Persists the KPI registry to `kpi_definitions` and reads it back.

  This is the boundary between the pure domain and the database.
  `AgentLens.Kpi.Registry` stays a function over modules; everything that talks
  to PostgreSQL lives here.

  The round trip has to be exact. Rollups and the UI resolve definitions from
  the table rather than from the modules, so a value that changes on the way
  through — a threshold tuple flattened into a list, an enum left as a string —
  would mean the dashboard is describing a different KPI than the one declared.
  """

  import Ecto.Query

  alias AgentLens.Kpi.Definition
  alias AgentLens.Kpi.Registry
  alias AgentLens.Repo
  alias AgentLens.Store.KpiDefinition

  # Everything except first_observed_at and inserted_at: a re-sync updates the
  # declared shape of a KPI but must never disturb where its series began.
  @replaceable [
    :name,
    :short_description,
    :methodology,
    :kind,
    :unit,
    :range_min,
    :range_max,
    :direction,
    :aggregation,
    :thresholds,
    :health_contribution,
    :min_sample_n,
    :sample_rate,
    :version,
    :updated_at
  ]

  @doc """
  Upserts every definition in the registry, returning how many were written.

  Runs at boot. Safe to run repeatedly.
  """
  @spec sync!(Registry.t(), Ecto.Repo.t()) :: {:ok, non_neg_integer()}
  def sync!(registry, repo \\ Repo) do
    now = DateTime.utc_now()

    entries =
      registry
      |> Map.values()
      |> Enum.map(fn %{definition: definition} ->
        definition
        |> to_attrs()
        |> Map.put(:inserted_at, now)
        |> Map.put(:updated_at, now)
      end)

    {count, _returned} =
      repo.insert_all(KpiDefinition, entries,
        on_conflict: {:replace, @replaceable},
        conflict_target: :slug
      )

    {:ok, count}
  end

  @doc """
  Every stored definition, as domain structs.

  Rows whose KPI module is no longer configured are skipped rather than raising:
  retiring a KPI leaves its historical rows behind, and that is not an error.
  """
  @spec all(Ecto.Repo.t()) :: [Definition.t()]
  def all(repo \\ Repo) do
    KpiDefinition
    |> order_by(:slug)
    |> repo.all()
    |> Enum.flat_map(fn record ->
      case to_definition(record) do
        {:ok, definition} -> [definition]
        :error -> []
      end
    end)
  end

  @doc "Fetches one stored definition by slug."
  @spec fetch(atom() | String.t(), Ecto.Repo.t()) :: {:ok, Definition.t()} | :error
  def fetch(slug, repo \\ Repo) do
    case repo.get(KpiDefinition, to_string(slug)) do
      nil -> :error
      record -> to_definition(record)
    end
  end

  @doc """
  Records where a KPI's series begins, the first time an observation lands.

  Only ever set once: `COALESCE` leaves an existing value untouched, so the
  chart keeps starting where the data actually started.
  """
  @spec mark_first_observed!(atom() | String.t(), DateTime.t(), Ecto.Repo.t()) :: :ok
  def mark_first_observed!(slug, observed_at, repo \\ Repo) do
    repo.update_all(
      from(d in KpiDefinition,
        where: d.slug == ^to_string(slug),
        update: [set: [first_observed_at: coalesce(d.first_observed_at, ^observed_at)]]
      ),
      []
    )

    :ok
  end

  @doc "Encodes a domain definition as column attributes."
  @spec to_attrs(Definition.t()) :: map()
  def to_attrs(%Definition{} = definition) do
    {range_min, range_max} = encode_range(definition.range)

    %{
      slug: Atom.to_string(definition.slug),
      name: definition.name,
      short_description: definition.short_description,
      methodology: definition.methodology,
      kind: Atom.to_string(definition.kind),
      unit: Atom.to_string(definition.unit),
      range_min: range_min,
      range_max: range_max,
      direction: Atom.to_string(definition.direction),
      aggregation: Atom.to_string(definition.aggregation),
      thresholds: encode_thresholds(definition.thresholds),
      health_contribution: Atom.to_string(definition.health_contribution),
      min_sample_n: definition.min_sample_n,
      sample_rate: definition.sample_rate,
      version: definition.version
    }
  end

  @doc """
  Decodes a stored row back into a domain definition.

  Returns `:error` when the row names a KPI this build does not know about.
  """
  @spec to_definition(KpiDefinition.t()) :: {:ok, Definition.t()} | :error
  def to_definition(%KpiDefinition{} = record) do
    with {:ok, slug} <- existing_atom(record.slug),
         {:ok, kind} <- existing_atom(record.kind),
         {:ok, unit} <- existing_atom(record.unit),
         {:ok, direction} <- existing_atom(record.direction),
         {:ok, aggregation} <- existing_atom(record.aggregation),
         {:ok, health} <- existing_atom(record.health_contribution) do
      {:ok,
       %Definition{
         slug: slug,
         name: record.name,
         short_description: record.short_description,
         methodology: record.methodology,
         kind: kind,
         unit: unit,
         range: decode_range(record.range_min, record.range_max),
         direction: direction,
         aggregation: aggregation,
         thresholds: decode_thresholds(record.thresholds),
         health_contribution: health,
         min_sample_n: record.min_sample_n,
         sample_rate: record.sample_rate,
         version: record.version
       }}
    end
  end

  defp encode_range(nil), do: {nil, nil}
  defp encode_range({min, max}), do: {min / 1, max / 1}

  defp decode_range(nil, nil), do: nil
  defp decode_range(min, max), do: {min, max}

  @doc """
  Encodes thresholds for `jsonb`.

  A tuple has no JSON representation, so a banded threshold survives the trip
  as a pair of lists. Shared with `AgentLens.Thresholds`, which stores overrides
  in the same shape — two encoders would be two chances to disagree.
  """
  @spec encode_thresholds(map()) :: map()
  def encode_thresholds(%{good: {good_low, good_high}, warning: {warn_low, warn_high}}) do
    %{"good" => [good_low, good_high], "warning" => [warn_low, warn_high]}
  end

  def encode_thresholds(%{warning: warning, critical: critical}) do
    %{"warning" => warning, "critical" => critical}
  end

  @doc "Decodes stored thresholds back into the shape the domain uses."
  @spec decode_thresholds(map()) :: map()
  def decode_thresholds(%{"good" => [good_low, good_high], "warning" => [warn_low, warn_high]}) do
    %{good: {good_low, good_high}, warning: {warn_low, warn_high}}
  end

  def decode_thresholds(%{"warning" => warning, "critical" => critical}) do
    %{warning: warning, critical: critical}
  end

  # Never String.to_atom/1 on a database value: atoms are not garbage collected,
  # so a stale or tampered row could grow the atom table without bound. Every
  # legitimate value already exists as an atom because a module declared it.
  defp existing_atom(value) when is_binary(value) do
    {:ok, String.to_existing_atom(value)}
  rescue
    ArgumentError -> :error
  end
end
