defmodule AgentLens.Workers.RetentionWorker do
  @moduledoc """
  Enforces the retention clocks daily, and keeps the partition runway ahead of
  ingestion.

  The two belong together: the same job that drops what has aged out also
  provisions what is about to be needed. A missing future partition stops
  ingestion dead, so it is worth doing on the same schedule that is already
  guaranteed to run.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 3

  alias AgentLens.Partitions.Manager
  alias AgentLens.Retention

  @impl Oban.Worker
  def perform(%Oban.Job{args: _args}) do
    :ok = Manager.ensure_current!()
    result = Retention.run!()

    {:ok,
     %{
       run_partitions_dropped: length(result.runs),
       observation_partitions_dropped: length(result.observations),
       payloads_purged: result.payloads_purged,
       rollups_expired: result.rollups_expired
     }}
  end
end
