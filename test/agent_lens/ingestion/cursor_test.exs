defmodule AgentLens.Ingestion.CursorTest do
  use AgentLens.DataCase, async: false

  alias AgentLens.Ingestion.Cursor

  @workspace "ws-support"

  describe "fetch/2 before anything has been ingested" do
    test "returns no watermark for an unknown workspace" do
      assert nil == Cursor.watermark(@workspace, :runs)
    end

    test "creates the row on first advance rather than requiring seeding" do
      at = ~U[2026-08-30 12:00:00.000000Z]
      assert :ok = Cursor.advance!(@workspace, :runs, at)

      assert DateTime.compare(Cursor.watermark(@workspace, :runs), at) == :eq
    end
  end

  describe "advance!/3" do
    test "moves the watermark forward" do
      :ok = Cursor.advance!(@workspace, :runs, ~U[2026-08-30 12:00:00.000000Z])
      :ok = Cursor.advance!(@workspace, :runs, ~U[2026-08-30 13:00:00.000000Z])

      assert DateTime.compare(
               Cursor.watermark(@workspace, :runs),
               ~U[2026-08-30 13:00:00.000000Z]
             ) == :eq
    end

    # A page that happens to contain only older records must not rewind the
    # cursor and cause the same window to be re-read forever.
    test "never moves the watermark backwards" do
      :ok = Cursor.advance!(@workspace, :runs, ~U[2026-08-30 13:00:00.000000Z])
      :ok = Cursor.advance!(@workspace, :runs, ~U[2026-08-30 12:00:00.000000Z])

      assert DateTime.compare(
               Cursor.watermark(@workspace, :runs),
               ~U[2026-08-30 13:00:00.000000Z]
             ) == :eq
    end

    test "clears a previous failure once a poll succeeds" do
      :ok = Cursor.record_failure!(@workspace, :runs, "boom")
      :ok = Cursor.advance!(@workspace, :runs, ~U[2026-08-30 12:00:00.000000Z])

      state = Cursor.get(@workspace, :runs)
      assert state.consecutive_failures == 0
      assert state.last_error == nil
    end
  end

  describe "independent streams" do
    # The reason there are two cursors: feedback lands after the run it attaches
    # to, so a shared watermark would either stall runs or skip feedback.
    test "runs and feedback advance independently" do
      :ok = Cursor.advance!(@workspace, :runs, ~U[2026-08-30 13:00:00.000000Z])
      :ok = Cursor.advance!(@workspace, :feedback, ~U[2026-08-30 09:00:00.000000Z])

      assert DateTime.compare(
               Cursor.watermark(@workspace, :runs),
               ~U[2026-08-30 13:00:00.000000Z]
             ) == :eq

      assert DateTime.compare(
               Cursor.watermark(@workspace, :feedback),
               ~U[2026-08-30 09:00:00.000000Z]
             ) == :eq
    end

    test "workspaces do not share a cursor" do
      :ok = Cursor.advance!("ws-a", :runs, ~U[2026-08-30 13:00:00.000000Z])

      assert nil == Cursor.watermark("ws-b", :runs)
    end
  end

  describe "record_failure!/3" do
    test "counts consecutive failures" do
      :ok = Cursor.record_failure!(@workspace, :runs, "timeout")
      :ok = Cursor.record_failure!(@workspace, :runs, "timeout")

      assert %{consecutive_failures: 2, last_error: "timeout"} = Cursor.get(@workspace, :runs)
    end

    test "leaves the watermark untouched, so a failed poll retries the window" do
      at = ~U[2026-08-30 12:00:00.000000Z]
      :ok = Cursor.advance!(@workspace, :runs, at)
      :ok = Cursor.record_failure!(@workspace, :runs, "timeout")

      assert DateTime.compare(Cursor.watermark(@workspace, :runs), at) == :eq
    end
  end

  describe "poll_since/3" do
    test "falls back to the backfill start when there is no watermark" do
      now = ~U[2026-08-30 12:00:00.000000Z]
      since = Cursor.poll_since(@workspace, :runs, now: now, backfill_days: 90)

      assert DateTime.compare(since, DateTime.add(now, -90, :day)) == :eq
    end

    # Records can be updated after creation, so each poll re-reads a little
    # behind the watermark rather than starting exactly at it.
    test "re-reads an overlap window behind the watermark" do
      :ok = Cursor.advance!(@workspace, :runs, ~U[2026-08-30 12:00:00.000000Z])

      since = Cursor.poll_since(@workspace, :runs, overlap_seconds: 300)

      assert DateTime.compare(since, ~U[2026-08-30 11:55:00.000000Z]) == :eq
    end
  end
end
