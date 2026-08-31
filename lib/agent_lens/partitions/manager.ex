defmodule AgentLens.Partitions.Manager do
  @moduledoc """
  Creates and drops the partitions described by `AgentLens.Partitions`.

  Two responsibilities:

    * **Ahead of ingestion.** PostgreSQL rejects a row that no partition covers,
      so the sweep that creates upcoming partitions has to run before the data
      arrives, not alongside it.
    * **Retention.** Dropping a partition removes its rows and their index
      entries in constant time, which is why retention is `DROP TABLE` here
      rather than a `DELETE` over millions of rows.

  ## On string interpolation in the SQL below

  Partition names and bounds cannot be bound parameters — PostgreSQL does not
  accept placeholders for identifiers or in `FOR VALUES`. Every interpolated
  value is derived from `AgentLens.Partitions`, which builds names from a fixed
  format string and bounds from `DateTime` structs. Nothing here originates in
  user input or a LangSmith payload.
  """

  alias AgentLens.Partitions
  alias AgentLens.Repo

  @typedoc "An existing partition, as reported by the database."
  @type existing :: %{name: String.t(), from: DateTime.t(), to: DateTime.t()}

  @doc "Creates one partition if it does not already exist."
  @spec ensure!(Partitions.spec(), Ecto.Repo.t()) :: :ok
  def ensure!(spec, repo \\ Repo) do
    repo.query!("""
    CREATE TABLE IF NOT EXISTS #{spec.name}
      PARTITION OF #{spec.table}
      FOR VALUES FROM ('#{bound(spec.from)}') TO ('#{bound(spec.to)}')
    """)

    :ok
  end

  @doc "Creates every partition needed to cover a date range."
  @spec ensure_range!(
          Partitions.table(),
          Date.t() | DateTime.t(),
          Date.t() | DateTime.t(),
          Ecto.Repo.t()
        ) ::
          :ok
  def ensure_range!(table, from, to, repo \\ Repo) do
    table
    |> Partitions.specs(from, to)
    |> Enum.each(&ensure!(&1, repo))
  end

  @doc """
  Creates partitions around today for every partitioned table.

  Runs at boot and on a cron. `ahead` matters more than `behind`: a missing
  future partition stops ingestion dead, while a missing past one only affects
  backfill.
  """
  @spec ensure_current!(keyword(), Ecto.Repo.t()) :: :ok
  def ensure_current!(opts \\ [], repo \\ Repo) do
    today = Keyword.get(opts, :today, Date.utc_today())
    behind = Keyword.get(opts, :behind_days, 14)
    ahead = Keyword.get(opts, :ahead_days, 28)

    Enum.each(Map.keys(Partitions.strategies()), fn table ->
      ensure_range!(table, Date.add(today, -behind), Date.add(today, ahead), repo)
    end)
  end

  @doc """
  Lists a table's existing partitions with their bounds.

  The bounds are parsed by PostgreSQL rather than by us: the regex extracts the
  literal from the partition expression and the cast turns it into a timestamp,
  so Postgrex hands back a `DateTime`.
  """
  @spec list(Partitions.table(), Ecto.Repo.t()) :: [existing()]
  def list(table, repo \\ Repo) do
    %{rows: rows} =
      repo.query!(
        """
        SELECT c.relname,
               (regexp_match(pg_get_expr(c.relpartbound, c.oid), 'FROM \\(''([^'']+)''\\)'))[1]::timestamptz,
               (regexp_match(pg_get_expr(c.relpartbound, c.oid), 'TO \\(''([^'']+)''\\)'))[1]::timestamptz
        FROM pg_class c
        JOIN pg_inherits i ON i.inhrelid = c.oid
        JOIN pg_class parent ON parent.oid = i.inhparent
        WHERE parent.relname = $1 AND c.relispartition
        ORDER BY 2
        """,
        [to_string(table)]
      )

    Enum.map(rows, fn [name, from, to] -> %{name: name, from: from, to: to} end)
  end

  @doc """
  Drops every partition that ends at or before `cutoff`, returning their names.

  A partition is only dropped once its whole range is past the cutoff, so the
  bucket containing the cutoff itself is kept.
  """
  @spec drop_before!(Partitions.table(), Date.t() | DateTime.t(), Ecto.Repo.t()) :: [String.t()]
  def drop_before!(table, cutoff, repo \\ Repo) do
    boundary = as_datetime(cutoff)

    table
    |> list(repo)
    |> Enum.filter(&(DateTime.compare(&1.to, boundary) != :gt))
    |> Enum.map(fn partition ->
      repo.query!("DROP TABLE IF EXISTS #{partition.name}")
      partition.name
    end)
  end

  defp as_datetime(%DateTime{} = datetime), do: datetime
  defp as_datetime(%Date{} = date), do: DateTime.new!(date, ~T[00:00:00], "Etc/UTC")

  defp bound(datetime), do: DateTime.to_iso8601(datetime)
end
