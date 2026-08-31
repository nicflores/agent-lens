defmodule AgentLens.Boot do
  @moduledoc """
  One-shot startup work that has to happen before anything ingests data.

  Two jobs, in this order:

    1. **Ensure partitions exist.** PostgreSQL rejects a row that no partition
       covers, so the sweep has to get ahead of the poller rather than race it.
    2. **Sync the KPI catalog.** Rollups and the UI resolve definitions from the
       table, so it must reflect the configured modules before either runs.

  Building the registry is what refuses the boot on a bad KPI configuration.
  That happens here rather than lazily in a worker, so a typo in `requires/0`
  is a startup error naming the field instead of a `nil` crash at 3am.

  ## Why this blocks rather than running as a Task

  The work happens in `init/1`, so `Supervisor.start_link/2` does not proceed to
  the next child until it finishes. A `Task` would return immediately and let
  the rest of the tree start alongside it — including, in the next phase, the
  poller, which would then try to insert runs before their partition existed.
  PostgreSQL rejects a row that no partition covers, so that race would surface
  as ingestion errors on every deploy.

  `init/1` returns `:ignore` because there is nothing to supervise afterwards:
  the work is done and no process needs to linger. A failure here propagates out
  of `start_link/1` and stops the application, which is the intent.
  """

  use GenServer

  require Logger

  alias AgentLens.Kpi.Catalog
  alias AgentLens.Kpi.Registry
  alias AgentLens.Partitions.Manager

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl GenServer
  def init(opts) do
    :ok = run(opts)
    :ignore
  end

  @doc """
  Runs the startup sequence.

  ## Options

    * `:kpis` — KPI modules to register, defaulting to the configured list.
    * `:repo` — the repo to write through, for testing.
    * `:behind_days` / `:ahead_days` — how much partition runway to keep.

  """
  @spec run(keyword()) :: :ok
  def run(opts \\ []) do
    repo = Keyword.get(opts, :repo, AgentLens.Repo)

    registry =
      case Keyword.fetch(opts, :kpis) do
        {:ok, modules} -> Registry.build!(modules)
        :error -> Registry.load!()
      end

    :ok = Manager.ensure_current!(Keyword.take(opts, [:today, :behind_days, :ahead_days]), repo)
    {:ok, count} = Catalog.sync!(registry, repo)

    Logger.info("AgentLens boot: #{count} KPI definitions synced, partitions ensured")

    :ok
  end

  @doc """
  Whether the startup sequence should run automatically.

  Disabled in test, where the sandbox owns the connection and each test sets up
  exactly the state it needs.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    :agent_lens
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:enabled, true)
  end
end
