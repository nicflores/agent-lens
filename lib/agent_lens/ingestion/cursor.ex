defmodule AgentLens.Ingestion.Cursor do
  @moduledoc """
  Persisted ingestion watermarks, one per `(workspace, stream)`.

  The watermark is how a restart resumes cleanly instead of re-reading ninety
  days or silently skipping the gap. Each poll starts a little *behind* it,
  because LangSmith runs can be updated after they are created and a cursor
  parked exactly at the last-seen timestamp would never see those edits.

  Runs and feedback keep separate watermarks. Feedback is written after the run
  it attaches to, so a shared cursor would either drag run ingestion along
  behind a slow evaluator or advance past feedback that had not landed yet.
  """

  use Ecto.Schema

  import Ecto.Query

  alias AgentLens.Repo

  @type stream :: :runs | :feedback
  @type t :: %__MODULE__{}

  @streams [:runs, :feedback]

  @default_overlap_seconds 300
  @default_backfill_days 90

  schema "ingestion_cursors" do
    field :workspace_id, :string
    field :stream, :string
    field :watermark, :utc_datetime_usec
    field :last_polled_at, :utc_datetime_usec
    field :last_error, :string
    field :consecutive_failures, :integer, default: 0

    timestamps(type: :utc_datetime_usec)
  end

  @doc "The ingestion streams, each with its own independent cursor."
  @spec streams() :: [stream()]
  def streams, do: @streams

  @doc "The stored cursor row, or `nil` if this workspace has never been polled."
  @spec get(String.t(), stream(), Ecto.Repo.t()) :: t() | nil
  def get(workspace_id, stream, repo \\ Repo) do
    repo.one(
      from(c in __MODULE__,
        where: c.workspace_id == ^workspace_id and c.stream == ^to_string(stream)
      )
    )
  end

  @doc "The last timestamp successfully ingested, or `nil`."
  @spec watermark(String.t(), stream(), Ecto.Repo.t()) :: DateTime.t() | nil
  def watermark(workspace_id, stream, repo \\ Repo) do
    case get(workspace_id, stream, repo) do
      nil -> nil
      cursor -> cursor.watermark
    end
  end

  @doc """
  Where the next poll should start reading from.

  With no watermark this is the start of the backfill window. Otherwise it is
  the watermark minus an overlap, so records updated after creation are seen
  again rather than missed.

  ## Options

    * `:overlap_seconds` — how far to re-read behind the watermark (default 300)
    * `:backfill_days` — how far back to start from cold (default 90)
    * `:now` — injectable clock
    * `:repo`

  """
  @spec poll_since(String.t(), stream(), keyword()) :: DateTime.t()
  def poll_since(workspace_id, stream, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    case watermark(workspace_id, stream, repo) do
      nil ->
        DateTime.add(now, -Keyword.get(opts, :backfill_days, @default_backfill_days), :day)

      watermark ->
        DateTime.add(watermark, -Keyword.get(opts, :overlap_seconds, @default_overlap_seconds))
    end
  end

  @doc """
  Advances the watermark after a successful poll and clears any failure state.

  Monotonic: a page containing only older records must not rewind the cursor, or
  the poller would re-read the same window forever.
  """
  @spec advance!(String.t(), stream(), DateTime.t(), Ecto.Repo.t()) :: :ok
  def advance!(workspace_id, stream, watermark, repo \\ Repo) do
    now = DateTime.utc_now()

    upsert!(
      workspace_id,
      stream,
      %{
        watermark: watermark,
        last_polled_at: now,
        last_error: nil,
        consecutive_failures: 0,
        inserted_at: now,
        updated_at: now
      },
      [
        watermark:
          dynamic(
            [c],
            fragment("GREATEST(?, EXCLUDED.watermark)", c.watermark)
          ),
        last_polled_at: dynamic([_c], fragment("EXCLUDED.last_polled_at")),
        last_error: dynamic([_c], fragment("EXCLUDED.last_error")),
        consecutive_failures: dynamic([_c], fragment("EXCLUDED.consecutive_failures")),
        updated_at: dynamic([_c], fragment("EXCLUDED.updated_at"))
      ],
      repo
    )
  end

  @doc """
  Records a failed poll without touching the watermark, so the same window is
  retried rather than skipped.
  """
  @spec record_failure!(String.t(), stream(), String.t(), Ecto.Repo.t()) :: :ok
  def record_failure!(workspace_id, stream, reason, repo \\ Repo) do
    now = DateTime.utc_now()

    upsert!(
      workspace_id,
      stream,
      %{
        watermark: nil,
        last_polled_at: now,
        last_error: reason,
        consecutive_failures: 1,
        inserted_at: now,
        updated_at: now
      },
      [
        last_polled_at: dynamic([_c], fragment("EXCLUDED.last_polled_at")),
        last_error: dynamic([_c], fragment("EXCLUDED.last_error")),
        consecutive_failures: dynamic([c], c.consecutive_failures + 1),
        updated_at: dynamic([_c], fragment("EXCLUDED.updated_at"))
      ],
      repo
    )
  end

  defp upsert!(workspace_id, stream, attrs, replacements, repo) do
    entry = Map.merge(attrs, %{workspace_id: workspace_id, stream: to_string(stream)})

    repo.insert_all(__MODULE__, [entry],
      on_conflict: [set: replacements],
      conflict_target: [:workspace_id, :stream]
    )

    :ok
  end
end
