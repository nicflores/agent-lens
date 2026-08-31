defmodule AgentLens.CacheTest do
  use ExUnit.Case, async: false

  alias AgentLens.Cache

  setup do
    Cache.clear()
    :ok
  end

  describe "storing and reading" do
    test "round-trips a value" do
      :ok = Cache.put(:overview, %{agents: []})

      assert {:ok, %{agents: []}} = Cache.fetch(:overview)
    end

    test "reports a miss rather than raising" do
      assert :error = Cache.fetch(:nothing_here)
    end

    test "get/2 falls back to a default" do
      assert :fallback = Cache.get(:nothing_here, :fallback)
    end

    test "overwrites an existing entry" do
      :ok = Cache.put(:overview, :first)
      :ok = Cache.put(:overview, :second)

      assert {:ok, :second} = Cache.fetch(:overview)
    end

    test "deletes an entry" do
      :ok = Cache.put(:overview, :value)
      :ok = Cache.delete(:overview)

      assert :error = Cache.fetch(:overview)
    end
  end

  # The whole point of ETS here: a LiveView mount is a table lookup, not a
  # message to a process that could become a bottleneck under twenty dashboards.
  describe "reads bypass the owning process" do
    test "the table is public and readable directly" do
      :ok = Cache.put(:overview, :value)

      assert [{:overview, :value, _stored_at}] = :ets.lookup(Cache.table(), :overview)
    end

    test "reading does not send the owner a message" do
      :ok = Cache.put(:overview, :value)

      owner = Process.whereis(Cache)
      {:message_queue_len, before} = Process.info(owner, :message_queue_len)

      for _ <- 1..100, do: Cache.fetch(:overview)

      assert {:message_queue_len, ^before} = Process.info(owner, :message_queue_len)
    end
  end

  describe "staleness" do
    test "records when an entry was written" do
      :ok = Cache.put(:overview, :value)

      assert {:ok, %DateTime{}} = Cache.stored_at(:overview)
    end

    test "reports age so the UI can say how fresh what it shows is" do
      :ok = Cache.put(:overview, :value)

      assert Cache.age_seconds(:overview) >= 0
    end

    test "an absent entry has no age" do
      assert Cache.age_seconds(:nothing_here) == nil
    end
  end
end
