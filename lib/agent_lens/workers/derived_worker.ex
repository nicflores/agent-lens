defmodule AgentLens.Workers.DerivedWorker do
  @moduledoc """
  Runs the derived pass once a day, after the day's buckets have settled.

  Derived KPIs are triggered by bucket close rather than run arrival, so this is
  a scheduled job rather than part of ingestion. It runs after the daily rollup
  so the series it compares against are complete.
  """

  use Oban.Worker, queue: :rollups, max_attempts: 3

  alias AgentLens.Rollup.Derived

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    as_of =
      case args["as_of"] do
        nil -> DateTime.utc_now()
        value -> value |> DateTime.from_iso8601() |> elem(1)
      end

    opts =
      []
      |> maybe_put(:current_days, args["current_days"])
      |> maybe_put(:baseline_days, args["baseline_days"])

    {:ok, written} = Derived.run!(as_of, opts)

    {:ok, %{buckets: written}}
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
