defmodule AgentLens.Partitions do
  @moduledoc """
  Declarative range partitions for the two high-volume tables.

  `runs` is partitioned weekly by `start_time`, `kpi_observations` monthly by
  `occurred_at`. Keeping the hot tables small is what lets plain PostgreSQL do
  this job without a time-series extension, and it makes retention a
  `DROP TABLE` of one partition rather than a `DELETE` of millions of rows.

  The partition-naming and boundary arithmetic here is pure. Anything touching
  the database is in `AgentLens.Partitions.Manager`.
  """

  @strategies %{runs: :weekly, kpi_observations: :monthly}

  @typedoc "A partition to create: its name and its half-open `[from, to)` bounds."
  @type spec :: %{
          table: atom(),
          name: String.t(),
          from: DateTime.t(),
          to: DateTime.t()
        }

  @typedoc "Tables that are partitioned."
  @type table :: :runs | :kpi_observations

  @doc "The tables under partition management, and how each is bucketed."
  @spec strategies() :: %{table() => :weekly | :monthly}
  def strategies, do: @strategies

  @doc """
  The partition that a given date or timestamp belongs to.

  ## Examples

      iex> AgentLens.Partitions.spec(:runs, ~D[2026-08-31]).name
      "runs_2026w36"

      iex> AgentLens.Partitions.spec(:kpi_observations, ~D[2026-08-31]).name
      "kpi_observations_2026m08"

  """
  @spec spec(table(), Date.t() | DateTime.t()) :: spec()
  def spec(table, %DateTime{} = datetime), do: spec(table, DateTime.to_date(datetime))

  def spec(table, %Date{} = date) do
    case Map.fetch(@strategies, table) do
      {:ok, :weekly} -> weekly_spec(table, date)
      {:ok, :monthly} -> monthly_spec(table, date)
      :error -> raise ArgumentError, "#{inspect(table)} is not a partitioned table"
    end
  end

  @doc """
  Every partition needed to cover a date range, oldest first.

  Returns `[]` when the range is inverted, so a caller that computed its bounds
  backwards creates nothing rather than something surprising.
  """
  @spec specs(table(), Date.t() | DateTime.t(), Date.t() | DateTime.t()) :: [spec()]
  def specs(table, from, to) do
    from_date = to_date(from)
    to_date = to_date(to)

    if Date.compare(from_date, to_date) == :gt do
      []
    else
      collect(table, from_date, to_date, [])
    end
  end

  defp collect(table, cursor, final, acc) do
    current = spec(table, cursor)
    acc = [current | acc]
    next = DateTime.to_date(current.to)

    if Date.compare(next, final) == :gt do
      Enum.reverse(acc)
    else
      collect(table, next, final, acc)
    end
  end

  defp weekly_spec(table, date) do
    monday = Date.beginning_of_week(date, :monday)
    {iso_year, iso_week} = :calendar.iso_week_number(Date.to_erl(date))

    %{
      table: table,
      name: "#{table}_#{iso_year}w#{pad(iso_week)}",
      from: midnight(monday),
      to: midnight(Date.add(monday, 7))
    }
  end

  defp monthly_spec(table, date) do
    first = Date.beginning_of_month(date)

    %{
      table: table,
      name: "#{table}_#{date.year}m#{pad(date.month)}",
      from: midnight(first),
      to: first |> Date.end_of_month() |> Date.add(1) |> midnight()
    }
  end

  defp to_date(%DateTime{} = datetime), do: DateTime.to_date(datetime)
  defp to_date(%Date{} = date), do: date

  defp midnight(date), do: DateTime.new!(date, ~T[00:00:00], "Etc/UTC")

  defp pad(number), do: number |> Integer.to_string() |> String.pad_leading(2, "0")
end
