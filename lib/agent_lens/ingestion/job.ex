defmodule AgentLens.Ingestion.Job do
  @moduledoc """
  One poll cycle: read a page from LangSmith, import it, move the cursor.

  Kept separate from `AgentLens.Ingestion.Poller` so the work can be tested and
  driven without a running process or a timer. The poller is only scheduling;
  this is the actual ingestion.
  """

  require Logger

  alias AgentLens.Ingestion.Cursor
  alias AgentLens.Ingestion.FeedbackImporter
  alias AgentLens.Ingestion.RunImporter
  alias AgentLens.LangSmith.Client
  alias AgentLens.Repo

  @default_limit 500
  @default_max_pages 500

  @typedoc "The outcome of one page."
  @type page_result :: %{
          optional(:runs) => non_neg_integer(),
          optional(:orphans) => non_neg_integer(),
          observations: non_neg_integer(),
          watermark: DateTime.t() | nil,
          has_more?: boolean()
        }

  @doc """
  Reads and imports one page for a workspace and stream.

  On failure the cursor is left where it was and the error recorded, so the same
  window is retried rather than skipped.

  ## Options

    * `:client` — the LangSmith client, defaulting to the configured one
    * `:limit` — page size
    * `:registry`, `:repo`, `:now`, and the `Cursor.poll_since/3` options
  """
  @spec run_once(String.t(), Cursor.stream(), keyword()) ::
          {:ok, page_result()} | {:error, term()}
  def run_once(workspace, stream, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)
    client = Keyword.get_lazy(opts, :client, &Client.impl/0)
    since = Cursor.poll_since(workspace, stream, opts)

    read_opts =
      [since: since, limit: Keyword.get(opts, :limit, @default_limit)]
      |> maybe_put(:now, Keyword.get(opts, :now))

    case fetch(client, stream, workspace, read_opts) do
      {:ok, page} ->
        {:ok, result} = import_page(stream, workspace, page.items, opts)
        advance(workspace, stream, result.watermark, repo)

        {:ok, Map.put(result, :has_more?, page.has_more?)}

      {:error, reason} ->
        :ok = Cursor.record_failure!(workspace, stream, inspect(reason), repo)
        Logger.warning("ingestion #{stream} failed for #{workspace}: #{inspect(reason)}")

        {:error, reason}
    end
  end

  @doc """
  Repeatedly polls until the window is exhausted, capped by `:max_pages`.

  Stops early if a page fails to move the cursor forward. Without that check,
  feedback whose runs have not arrived would be re-read indefinitely: the page
  reports more results, but nothing in it can be imported.
  """
  @spec drain(String.t(), Cursor.stream(), keyword()) :: {:ok, map()} | {:error, term()}
  def drain(workspace, stream, opts \\ []) do
    max_pages = Keyword.get(opts, :max_pages, @default_max_pages)
    repo = Keyword.get(opts, :repo, Repo)

    do_drain(workspace, stream, opts, repo, max_pages, blank_summary())
  end

  defp do_drain(_workspace, _stream, _opts, _repo, 0, summary), do: {:ok, summary}

  defp do_drain(workspace, stream, opts, repo, remaining, summary) do
    before = Cursor.watermark(workspace, stream, repo)

    case run_once(workspace, stream, opts) do
      {:ok, result} ->
        summary = accumulate(summary, result)
        progressed? = advanced?(before, Cursor.watermark(workspace, stream, repo))

        if result.has_more? and progressed? do
          do_drain(workspace, stream, opts, repo, remaining - 1, summary)
        else
          {:ok, summary}
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp blank_summary, do: %{pages: 0, runs: 0, observations: 0, orphans: 0}

  defp accumulate(summary, result) do
    %{
      pages: summary.pages + 1,
      runs: summary.runs + Map.get(result, :runs, 0),
      observations: summary.observations + result.observations,
      orphans: summary.orphans + Map.get(result, :orphans, 0)
    }
  end

  defp advanced?(_before, nil), do: false
  defp advanced?(nil, _after), do: true
  defp advanced?(before, later), do: DateTime.compare(later, before) == :gt

  defp fetch(client, :runs, workspace, opts), do: client.list_runs(workspace, opts)
  defp fetch(client, :feedback, workspace, opts), do: client.list_feedback(workspace, opts)

  defp import_page(:runs, workspace, items, opts),
    do: RunImporter.import(workspace, items, opts)

  defp import_page(:feedback, workspace, items, opts),
    do: FeedbackImporter.import(workspace, items, opts)

  defp advance(_workspace, _stream, nil, _repo), do: :ok

  defp advance(workspace, stream, watermark, repo),
    do: Cursor.advance!(workspace, stream, watermark, repo)

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
