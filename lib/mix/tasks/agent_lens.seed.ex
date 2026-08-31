defmodule Mix.Tasks.AgentLens.Seed do
  @shortdoc "Backfills the database from the configured LangSmith client"

  @moduledoc """
  Drains every configured workspace into the database.

      mix agent_lens.seed
      mix agent_lens.seed --workspace ws-support --max-pages 10

  Against the mock client this produces roughly ninety days of history per
  workspace, including the injected latency spike, toxicity regression and cost
  creep — enough for the dashboard to show something worth looking at and for
  drift detection to have something to find.

  Safe to re-run: everything is upserted on its natural key.

  ## Options

    * `--workspace` — seed one workspace instead of all (repeatable)
    * `--limit` — page size (default 1000)
    * `--max-pages` — cap per workspace and stream (default 500)
  """

  use Mix.Task

  alias AgentLens.Ingestion.Cursor
  alias AgentLens.Ingestion.Job
  alias AgentLens.LangSmith.Client

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {parsed, _rest, _invalid} =
      OptionParser.parse(args,
        strict: [workspace: :keep, limit: :integer, max_pages: :integer],
        aliases: [w: :workspace]
      )

    workspaces =
      case Keyword.get_values(parsed, :workspace) do
        [] -> Client.workspaces()
        given -> given
      end

    opts = [
      limit: Keyword.get(parsed, :limit, 1_000),
      max_pages: Keyword.get(parsed, :max_pages, 500)
    ]

    if workspaces == [] do
      Mix.shell().error("No workspaces configured. Set LANGSMITH_WORKSPACES.")
    else
      Mix.shell().info(
        "Seeding #{length(workspaces)} workspace(s) via #{inspect(Client.impl())}\n"
      )

      Enum.each(workspaces, &seed_workspace(&1, opts))
    end
  end

  defp seed_workspace(workspace, opts) do
    Mix.shell().info("#{workspace}")

    # Runs first: feedback references them, and feedback whose run is missing is
    # deliberately left for a later pass rather than dropped.
    for stream <- Cursor.streams() do
      started = System.monotonic_time(:millisecond)

      case Job.drain(workspace, stream, opts) do
        {:ok, summary} ->
          elapsed = System.monotonic_time(:millisecond) - started

          Mix.shell().info(
            "  #{String.pad_trailing(to_string(stream), 9)} " <>
              "#{summary.pages} pages, #{summary.runs} runs, " <>
              "#{summary.observations} observations, #{summary.orphans} orphaned (#{elapsed}ms)"
          )

        {:error, reason} ->
          Mix.shell().error("  #{stream} failed: #{inspect(reason)}")
      end
    end

    Mix.shell().info("")
  end
end
