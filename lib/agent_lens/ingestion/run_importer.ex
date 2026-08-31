defmodule AgentLens.Ingestion.RunImporter do
  @moduledoc """
  Writes a page of LangSmith runs, computing extracted KPIs inline.

  Extraction happens here rather than in a follow-up pass because extracted
  KPIs are pure arithmetic on a payload already in memory. Deferring them would
  buy nothing and add a queue that could fall behind.

  Everything is upserted. Each poll deliberately re-reads a window behind its
  watermark — runs can be updated after creation — so importing the same page
  twice has to converge rather than accumulate.
  """

  import Ecto.Query

  alias AgentLens.Ingestion.Mapper
  alias AgentLens.Kpi.Extraction
  alias AgentLens.Kpi.Registry
  alias AgentLens.Partitions.Manager
  alias AgentLens.Repo
  alias AgentLens.Store.KpiObservation
  alias AgentLens.Store.Run

  @run_replaceable [
    :end_time,
    :latency_ms,
    :status,
    :error,
    :model,
    :prompt_tokens,
    :completion_tokens,
    :cost_usd,
    :payload,
    :updated_at
  ]

  @typedoc "What one page of ingestion did."
  @type result :: %{
          runs: non_neg_integer(),
          observations: non_neg_integer(),
          watermark: DateTime.t() | nil
        }

  @doc """
  Imports a page of run payloads for one workspace.

  ## Options

    * `:registry` — the KPI registry, defaulting to the configured one
    * `:repo`
  """
  @spec import(String.t(), [map()], keyword()) :: {:ok, result()}
  def import(workspace, items, opts \\ [])

  def import(_workspace, [], _opts),
    do: {:ok, %{runs: 0, observations: 0, watermark: nil}}

  def import(workspace, items, opts) do
    repo = Keyword.get(opts, :repo, Repo)
    registry = Keyword.get_lazy(opts, :registry, &Registry.load!/0)

    attrs = Enum.map(items, &Mapper.to_run_attrs(&1, workspace))

    :ok = ensure_partitions(attrs, repo)

    stored = upsert_runs(attrs, repo)
    observations = upsert_observations(attrs, stored, registry, repo)

    {:ok,
     %{
       runs: map_size(stored),
       observations: observations,
       watermark: attrs |> Enum.map(& &1.start_time) |> Enum.max(DateTime, fn -> nil end)
     }}
  end

  # Backfill reaches further back than the boot sweep provisions, and PostgreSQL
  # rejects a row no partition covers. Make room for the batch before writing it.
  defp ensure_partitions(attrs, repo) do
    times = Enum.map(attrs, & &1.start_time)

    Manager.ensure_range!(
      :runs,
      Enum.min(times, DateTime),
      Enum.max(times, DateTime),
      repo
    )

    Manager.ensure_range!(
      :kpi_observations,
      Enum.min(times, DateTime),
      Enum.max(times, DateTime),
      repo
    )
  end

  defp upsert_runs(attrs, repo) do
    now = DateTime.utc_now()

    entries =
      Enum.map(attrs, fn attr ->
        attr
        |> Map.take([
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
        ])
        |> Map.merge(%{inserted_at: now, updated_at: now})
      end)

    {_count, returned} =
      repo.insert_all(Run, entries,
        on_conflict: {:replace, @run_replaceable},
        conflict_target: [:langsmith_run_id, :start_time],
        returning: [:id, :langsmith_run_id]
      )

    Map.new(returned, &{&1.langsmith_run_id, &1.id})
  end

  defp upsert_observations(attrs, stored, registry, repo) do
    rows =
      Enum.flat_map(attrs, fn attr ->
        case Map.fetch(stored, attr.langsmith_run_id) do
          {:ok, run_id} ->
            attr
            |> Mapper.to_input()
            |> then(&Extraction.from_run(registry, &1, run_id: run_id))

          :error ->
            []
        end
      end)

    insert_observations(rows, repo)
  end

  @doc """
  Upserts observation rows, deduping on the natural key.

  The dedupe index is partial (`WHERE run_id IS NOT NULL`), so the conflict
  target has to name the predicate as well as the columns for PostgreSQL to
  match it.
  """
  @spec insert_observations([map()], Ecto.Repo.t()) :: non_neg_integer()
  def insert_observations(rows, repo \\ Repo)

  def insert_observations([], _repo), do: 0

  def insert_observations(rows, repo) do
    now = DateTime.utc_now()
    entries = Enum.map(rows, &Map.put(&1, :computed_at, now))

    {count, _returned} =
      repo.insert_all(KpiObservation, entries,
        on_conflict:
          from(o in KpiObservation,
            update: [set: [value: fragment("EXCLUDED.value"), computed_at: ^now]]
          ),
        conflict_target:
          {:unsafe_fragment,
           "(run_id, kpi_slug, kpi_version, occurred_at) WHERE run_id IS NOT NULL"}
      )

    count
  end
end
