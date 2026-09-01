defmodule AgentLens.Thresholds do
  @moduledoc """
  Per-agent threshold overrides.

  Modules ship defaults; these are *configuration*. The right toxicity
  threshold for a customer-facing agent is wrong for an internal research one,
  and tuning must not require a deploy — otherwise thresholds get set once,
  never revisited, and the dashboard slowly becomes wallpaper.

  An override replaces the definition's thresholds wherever status is
  evaluated, not merely on the page where it was typed. Anything less would
  mean the card and the badge disagreed with the number you had just set.
  """

  import Ecto.Query

  alias AgentLens.Kpi.Catalog
  alias AgentLens.Kpi.Definition
  alias AgentLens.Kpi.Thresholds, as: Shape
  alias AgentLens.Repo
  alias AgentLens.Store.KpiThreshold

  @doc """
  Every override for an agent, keyed by slug.

  Loaded once per summary rather than per KPI: the agent grid renders five KPIs
  across three agents, and a query each would be fifteen for data that fits in
  one.
  """
  @spec for_agent(String.t(), Ecto.Repo.t()) :: %{optional(atom()) => Shape.t()}
  def for_agent(agent_id, repo \\ Repo) do
    from(t in KpiThreshold, where: t.agent_id == ^agent_id)
    |> repo.all()
    |> Enum.reduce(%{}, fn record, acc ->
      case decode(record.kpi_slug, record.thresholds) do
        {:ok, slug, thresholds} -> Map.put(acc, slug, thresholds)
        :error -> acc
      end
    end)
  end

  @doc """
  Applies any override to a definition.

  Validated against the definition's own direction on the way in, so an
  override can adjust where the lines sit but never turn a banded KPI into a
  monotonic one.
  """
  @spec apply_override(Definition.t(), %{optional(atom()) => Shape.t()}) :: Definition.t()
  def apply_override(%Definition{} = definition, overrides) do
    case Map.fetch(overrides, definition.slug) do
      {:ok, thresholds} -> %Definition{definition | thresholds: thresholds}
      :error -> definition
    end
  end

  @doc "The thresholds in force for one agent and KPI, override or default."
  @spec effective(Definition.t(), String.t(), Ecto.Repo.t()) :: Shape.t()
  def effective(%Definition{} = definition, agent_id, repo \\ Repo) do
    definition
    |> apply_override(for_agent(agent_id, repo))
    |> Map.fetch!(:thresholds)
  end

  @doc """
  Stores an override, rejecting one that does not fit the KPI's direction.

  A malformed override would be worse than none: it would silently mis-colour
  a KPI that someone had deliberately gone to the trouble of tuning.
  """
  @spec put(String.t(), Definition.t(), Shape.t(), keyword()) ::
          {:ok, KpiThreshold.t()} | {:error, term()}
  def put(agent_id, %Definition{} = definition, thresholds, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    with {:ok, valid} <- Shape.validate(definition.direction, thresholds),
         :ok <- within_range(definition, valid) do
      %KpiThreshold{}
      |> KpiThreshold.changeset(%{
        agent_id: agent_id,
        kpi_slug: Atom.to_string(definition.slug),
        thresholds: Catalog.encode_thresholds(valid),
        updated_by: Keyword.get(opts, :updated_by)
      })
      |> repo.insert(
        on_conflict: {:replace, [:thresholds, :updated_by, :updated_at]},
        conflict_target: [:agent_id, :kpi_slug]
      )
    end
  end

  @doc "Removes an override, returning the KPI to its shipped defaults."
  @spec delete(String.t(), atom(), Ecto.Repo.t()) :: :ok
  def delete(agent_id, kpi_slug, repo \\ Repo) do
    from(t in KpiThreshold,
      where: t.agent_id == ^agent_id and t.kpi_slug == ^to_string(kpi_slug)
    )
    |> repo.delete_all()

    :ok
  end

  @doc "Whether an agent has overridden a KPI's shipped thresholds."
  @spec overridden?(String.t(), atom(), Ecto.Repo.t()) :: boolean()
  def overridden?(agent_id, kpi_slug, repo \\ Repo) do
    repo.exists?(
      from(t in KpiThreshold,
        where: t.agent_id == ^agent_id and t.kpi_slug == ^to_string(kpi_slug)
      )
    )
  end

  defp within_range(%Definition{range: nil}, _thresholds), do: :ok

  defp within_range(%Definition{range: {low, high}} = definition, thresholds) do
    if Enum.all?(threshold_values(definition.direction, thresholds), &(&1 >= low and &1 <= high)) do
      :ok
    else
      {:error, "thresholds must fall inside the KPI's range of #{low} to #{high}"}
    end
  end

  defp threshold_values(:target_band, %{good: {a, b}, warning: {c, d}}), do: [a, b, c, d]

  defp threshold_values(_direction, %{warning: warning, critical: critical}),
    do: [warning, critical]

  defp decode(slug, encoded) do
    {:ok, String.to_existing_atom(slug), Catalog.decode_thresholds(encoded)}
  rescue
    ArgumentError -> :error
  end
end
