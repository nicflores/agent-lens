defmodule AgentLens.Store.KpiThreshold do
  @moduledoc """
  A per-agent threshold override.

  Modules ship defaults; these are configuration. The right toxicity threshold
  for a customer-facing agent is wrong for an internal research one, and tuning
  must not require a deploy.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "kpi_thresholds" do
    field :agent_id, :string
    field :kpi_slug, :string
    field :thresholds, :map
    field :updated_by, :string

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(threshold, attrs) do
    threshold
    |> cast(attrs, [:agent_id, :kpi_slug, :thresholds, :updated_by])
    |> validate_required([:agent_id, :kpi_slug, :thresholds])
    |> unique_constraint([:agent_id, :kpi_slug])
    |> foreign_key_constraint(:kpi_slug)
  end
end
