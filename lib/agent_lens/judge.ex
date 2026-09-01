defmodule AgentLens.Judge do
  @moduledoc """
  The local judge tier: scores retained runs with our own model call.

  ## Why this exists at all when LangSmith judges for us

  Online evaluators only score traces going forward. Switch a new one on today
  and its chart begins today — no history, no baseline, and nothing for drift
  detection to compare against for a month. That is the worst possible moment
  to have added a KPI you care about.

  Retained payloads plus a prompt close that gap: the same KPI can be scored
  across everything still inside the retention window, so a KPI added on
  Tuesday has ninety days of history on Wednesday.

  In steady state this queue is mostly idle. It is a backfill escape hatch, not
  a second ingestion path.

  ## What it will not do

  It only judges runs whose payload survives. Retention purges payloads on a
  shorter clock than the rows, so a run older than that clock cannot be scored
  however much we would like to — and `kpi_definitions.first_observed_at` is
  where the series honestly begins.
  """

  require Logger

  alias AgentLens.Ingestion.Mapper
  alias AgentLens.Ingestion.RunImporter
  alias AgentLens.Kpi.Registry
  alias AgentLens.LLM.Client, as: LLM
  alias AgentLens.Repo

  @default_batch 50

  @typedoc "What a backfill pass did."
  @type result :: %{
          judged: non_neg_integer(),
          skipped: non_neg_integer(),
          failed: non_neg_integer(),
          unreachable: non_neg_integer()
        }

  @doc """
  Scores runs in a window that have no observation for this KPI yet.

  ## Options

    * `:batch` — how many runs to judge in one pass (default #{@default_batch})
    * `:llm` — the model client, defaulting to the configured one
    * `:registry`, `:repo`
  """
  @spec backfill(String.t(), atom(), DateTime.t(), DateTime.t(), keyword()) ::
          {:ok, result()} | {:error, term()}
  def backfill(agent_id, kpi_slug, from, to, opts \\ []) do
    registry = Keyword.get_lazy(opts, :registry, &Registry.load!/0)

    case Map.fetch(registry, kpi_slug) do
      :error ->
        {:error, {:unknown_kpi, kpi_slug}}

      {:ok, entry} ->
        judge_runs(entry, agent_id, from, to, opts)
    end
  end

  defp judge_runs(entry, agent_id, from, to, opts) do
    repo = Keyword.get(opts, :repo, Repo)
    llm = Keyword.get_lazy(opts, :llm, &LLM.impl/0)
    definition = entry.definition

    runs =
      unjudged_runs(
        repo,
        agent_id,
        definition,
        from,
        to,
        Keyword.get(opts, :batch, @default_batch)
      )

    {rows, tally} =
      Enum.reduce(runs, {[], %{judged: 0, skipped: 0, failed: 0, unreachable: 0}}, fn run,
                                                                                      {rows,
                                                                                       tally} ->
        case judge_one(entry, run, llm, opts) do
          {:ok, row} -> {[row | rows], bump(tally, :judged)}
          :skip -> {rows, bump(tally, :skipped)}
          :error -> {rows, bump(tally, :failed)}
        end
      end)

    written = RunImporter.insert_observations(Enum.reverse(rows), repo)

    Logger.info(
      "judge backfill #{definition.slug}/#{agent_id}: " <>
        "#{written} scored, #{tally.skipped} skipped, #{tally.failed} failed"
    )

    {:ok, %{tally | judged: written}}
  end

  defp judge_one(entry, run, llm, opts) do
    input = Mapper.to_input(run)

    with {:ok, prompt} <- prompt_for(entry.module, input),
         {:ok, completion} <- llm.complete(prompt, Keyword.take(opts, [:model, :temperature])),
         {:ok, score} <- entry.module.parse_score(completion.text) do
      {:ok, observation(entry.definition, run, score, completion.model)}
    else
      :skip ->
        :skip

      # A model that answers unparseably is a real failure, not a skip: the run
      # is still judgeable and should be retried, not silently written off.
      :error ->
        :error

      {:error, reason} ->
        Logger.warning("judge call failed for #{run.langsmith_run_id}: #{inspect(reason)}")
        :error
    end
  end

  defp prompt_for(module, input) do
    if function_exported?(module, :judge_prompt, 1) do
      module.judge_prompt(input)
    else
      :skip
    end
  end

  defp observation(definition, run, score, judge_model) do
    %{
      run_id: run.id,
      agent_id: run.agent_id,
      kpi_slug: Atom.to_string(definition.slug),
      value: score * 1.0,
      source: "judged",
      kpi_version: definition.version,
      judge_model: judge_model,
      metadata: %{},
      occurred_at: run.start_time
    }
  end

  # Only runs that still have their payload. Retention purges payloads sooner
  # than rows, and a run without one cannot be judged at any price.
  defp unjudged_runs(repo, agent_id, definition, from, to, limit) do
    %{rows: rows} =
      repo.query!(
        """
        SELECT r.id, r.langsmith_run_id, r.agent_id, r.start_time, r.payload
        FROM runs r
        LEFT JOIN kpi_observations o
          ON o.run_id = r.id
         AND o.kpi_slug = $2
         AND o.kpi_version = $5
         AND o.occurred_at = r.start_time
        WHERE r.agent_id = $1
          AND r.start_time >= $3
          AND r.start_time < $4
          AND o.id IS NULL
          AND r.payload <> '{}'::jsonb
        ORDER BY r.start_time
        LIMIT $6
        """,
        [agent_id, to_string(definition.slug), from, to, definition.version, limit]
      )

    Enum.map(rows, fn [id, langsmith_run_id, agent, start_time, payload] ->
      %{
        id: id,
        langsmith_run_id: langsmith_run_id,
        agent_id: agent,
        trace_id: nil,
        parent_run_id: nil,
        name: nil,
        run_type: nil,
        start_time: start_time,
        end_time: nil,
        latency_ms: nil,
        status: nil,
        error: nil,
        model: nil,
        prompt_tokens: nil,
        completion_tokens: nil,
        cost_usd: nil,
        payload: payload || %{}
      }
    end)
  end

  defp bump(tally, key), do: Map.update!(tally, key, &(&1 + 1))
end
