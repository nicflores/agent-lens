defmodule AgentLens.Workers.JudgeWorker do
  @moduledoc """
  Runs a judge backfill for one agent and KPI, one batch at a time.

  Enqueued on demand rather than on a cron: backfilling is something you decide
  to do after adding a KPI, not a thing that should happen quietly in the
  background. Each job judges a batch and enqueues its own successor while
  there is still work, so a ninety-day backfill is many small jobs that can be
  paused, retried and rate-limited individually rather than one that either
  finishes or does not.
  """

  use Oban.Worker, queue: :judge, max_attempts: 3

  alias AgentLens.Judge

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    agent_id = Map.fetch!(args, "agent_id")
    slug = String.to_existing_atom(Map.fetch!(args, "kpi_slug"))
    {:ok, from, _} = DateTime.from_iso8601(Map.fetch!(args, "from"))
    {:ok, to, _} = DateTime.from_iso8601(Map.fetch!(args, "to"))
    batch = Map.get(args, "batch", 50)

    case Judge.backfill(agent_id, slug, from, to, batch: batch) do
      {:ok, %{judged: 0} = result} ->
        {:ok, Map.put(result, :done, true)}

      {:ok, result} ->
        # More to do: queue the next batch rather than looping here, so the
        # work stays interruptible.
        {:ok, _job} = args |> new() |> Oban.insert()
        {:ok, Map.put(result, :done, false)}

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Enqueues a backfill.

  ## Example

      AgentLens.Workers.JudgeWorker.enqueue("ws-support", :toxicity,
        from: ~U[2026-06-01 00:00:00Z],
        to: DateTime.utc_now()
      )
  """
  @spec enqueue(String.t(), atom(), keyword()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(agent_id, kpi_slug, opts) do
    %{
      "agent_id" => agent_id,
      "kpi_slug" => to_string(kpi_slug),
      "from" => opts |> Keyword.fetch!(:from) |> DateTime.to_iso8601(),
      "to" => opts |> Keyword.fetch!(:to) |> DateTime.to_iso8601(),
      "batch" => Keyword.get(opts, :batch, 50)
    }
    |> new()
    |> Oban.insert()
  end
end
