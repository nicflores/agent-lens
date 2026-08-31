defmodule AgentLens.Store.Run do
  @moduledoc """
  A retained LangSmith run.

  The flattened columns carry what every query filters or aggregates on; the
  full `payload` is kept so a KPI added later can read a field we never thought
  to flatten, with no migration and no backfill from LangSmith.

  The primary key is composite because the table is partitioned by `start_time`
  and PostgreSQL requires the partition key in every unique index.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @castable [
    :langsmith_run_id,
    :agent_id,
    :trace_id,
    :parent_run_id,
    :name,
    :run_type,
    :start_time,
    :end_time,
    :latency_ms,
    :status,
    :error,
    :model,
    :prompt_tokens,
    :completion_tokens,
    :cost_usd,
    :payload
  ]

  @primary_key false
  schema "runs" do
    field :id, :id, read_after_writes: true
    field :langsmith_run_id, :string, primary_key: true
    field :agent_id, :string
    field :trace_id, :string
    field :parent_run_id, :string
    field :name, :string
    field :run_type, :string
    field :start_time, :utc_datetime_usec, primary_key: true
    field :end_time, :utc_datetime_usec
    field :latency_ms, :integer
    field :status, :string
    field :error, :string
    field :model, :string
    field :prompt_tokens, :integer
    field :completion_tokens, :integer
    field :cost_usd, :decimal
    field :payload, :map, default: %{}

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Builds a changeset for an ingested run.

  `agent_id` is the LangSmith workspace the run was polled from rather than
  anything in the payload, so the poller sets it explicitly.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(run, attrs) do
    run
    |> cast(attrs, @castable)
    |> validate_required([:langsmith_run_id, :agent_id, :start_time])
    |> validate_number(:latency_ms, greater_than_or_equal_to: 0)
  end
end
