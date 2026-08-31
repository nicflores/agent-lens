defmodule AgentLens.Ingestion.FeedbackImporter do
  @moduledoc """
  Imports LangSmith evaluator scores as `:imported` observations.

  ## Why this has its own cursor

  Feedback is written *after* the run it attaches to. Sharing a watermark with
  run ingestion would either drag runs along behind a slow evaluator or advance
  past feedback that had not been written yet.

  ## Orphan feedback

  A poll can legitimately see a score for a run this system has not stored yet.
  Those records are skipped, and — importantly — the watermark only advances as
  far as the newest record that was actually matched. Advancing past an orphan
  would lose that score permanently, because nothing would ever read that window
  again.

  The trade-off is that feedback for a run that never arrives holds the cursor
  back. That is the safer failure: it retries and reports `orphans` rather than
  silently dropping data.
  """

  import Ecto.Query

  alias AgentLens.Ingestion.Mapper
  alias AgentLens.Ingestion.RunImporter
  alias AgentLens.Kpi.Extraction
  alias AgentLens.Kpi.Registry
  alias AgentLens.Repo
  alias AgentLens.Store.Run

  @typedoc "What one page of feedback ingestion did."
  @type result :: %{
          observations: non_neg_integer(),
          orphans: non_neg_integer(),
          watermark: DateTime.t() | nil
        }

  @doc """
  Imports a page of feedback records for one workspace.

  ## Options

    * `:registry` — the KPI registry, defaulting to the configured one
    * `:repo`
  """
  @spec import(String.t(), [map()], keyword()) :: {:ok, result()}
  def import(workspace, items, opts \\ [])

  def import(_workspace, [], _opts),
    do: {:ok, %{observations: 0, orphans: 0, watermark: nil}}

  def import(workspace, items, opts) do
    repo = Keyword.get(opts, :repo, Repo)
    registry = Keyword.get_lazy(opts, :registry, &Registry.load!/0)

    by_run = Enum.group_by(items, & &1["run_id"])
    runs = lookup_runs(workspace, Map.keys(by_run), repo)

    {matched, orphaned} =
      Enum.split_with(by_run, fn {run_id, _records} -> Map.has_key?(runs, run_id) end)

    rows =
      Enum.flat_map(matched, fn {run_id, records} ->
        run = Map.fetch!(runs, run_id)

        %{
          langsmith_run_id: run.langsmith_run_id,
          agent_id: run.agent_id,
          trace_id: nil,
          parent_run_id: nil,
          name: nil,
          run_type: nil,
          start_time: run.start_time,
          end_time: nil,
          latency_ms: nil,
          status: nil,
          error: nil,
          model: nil,
          prompt_tokens: nil,
          completion_tokens: nil,
          cost_usd: nil,
          payload: %{}
        }
        |> Mapper.to_input(Mapper.to_feedback_scores(records))
        |> then(&Extraction.from_feedback(registry, &1, run_id: run.id))
      end)

    count = RunImporter.insert_observations(rows, repo)

    {:ok,
     %{
       observations: count,
       orphans: orphaned |> Enum.flat_map(fn {_id, records} -> records end) |> length(),
       watermark: matched_watermark(matched)
     }}
  end

  # Only as far as we actually got. Anything newer than this either was matched
  # (and is included) or is an orphan we intend to retry.
  defp matched_watermark([]), do: nil

  defp matched_watermark(matched) do
    matched
    |> Enum.flat_map(fn {_run_id, records} -> Enum.map(records, & &1["created_at"]) end)
    |> Enum.map(&normalize/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.max(DateTime, fn -> nil end)
  end

  defp normalize(%DateTime{} = datetime), do: datetime

  defp normalize(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      {:error, _reason} -> nil
    end
  end

  defp normalize(_other), do: nil

  defp lookup_runs(_workspace, [], _repo), do: %{}

  defp lookup_runs(workspace, langsmith_run_ids, repo) do
    from(r in Run,
      where: r.agent_id == ^workspace and r.langsmith_run_id in ^langsmith_run_ids,
      select: %{
        id: r.id,
        langsmith_run_id: r.langsmith_run_id,
        agent_id: r.agent_id,
        start_time: r.start_time
      }
    )
    |> repo.all()
    |> Map.new(&{&1.langsmith_run_id, &1})
  end
end
