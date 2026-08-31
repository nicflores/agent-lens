defmodule AgentLens.Workers.RollupWorker do
  @moduledoc """
  Recomputes recent buckets at one granularity.

  Deliberately recomputes a *window* rather than only the bucket that just
  closed. Observations arrive late — a run can be updated after creation, and
  imported feedback lands well after the run it scores — so a bucket computed
  once at the moment it closed would permanently under-count. Rollups are
  upserted, so recomputing is cheap and converges.
  """

  use Oban.Worker, queue: :rollups, max_attempts: 3

  alias AgentLens.Rollup

  # How far back each grain recomputes, in buckets.
  @lookback %{minute: 15, hour: 6, day: 3}

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    granularity = granularity!(args["granularity"])
    now = Map.get(args, "now") |> parse_now()

    span = Rollup.seconds_per_bucket(granularity)
    to = now |> Rollup.bucket_start(granularity) |> DateTime.add(span)
    from = DateTime.add(to, -(@lookback[granularity] + 1) * span)

    {:ok, written} = Rollup.run!(granularity, from, to)

    {:ok, %{granularity: granularity, buckets: written}}
  end

  # Job args round-trip through the database as JSON, so never String.to_atom
  # them; the grain must be one we already know about.
  defp granularity!(value) when is_binary(value) do
    granularity = String.to_existing_atom(value)

    if granularity in Rollup.granularities() do
      granularity
    else
      raise ArgumentError, "unknown rollup granularity #{inspect(value)}"
    end
  rescue
    ArgumentError ->
      reraise ArgumentError, "unknown rollup granularity #{inspect(value)}", __STACKTRACE__
  end

  defp parse_now(nil), do: DateTime.utc_now()

  defp parse_now(value) when is_binary(value) do
    {:ok, datetime, _offset} = DateTime.from_iso8601(value)
    datetime
  end
end
