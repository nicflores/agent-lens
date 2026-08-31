defmodule AgentLens.Ingestion.PollerTest do
  use AgentLens.DataCase, async: false

  alias AgentLens.Ingestion.Poller
  alias AgentLens.Repo
  alias AgentLens.Store.Run

  @workspace "ws-support"
  @now ~U[2026-08-30 00:00:00.000000Z]

  defp start_poller(extra \\ []) do
    opts =
      Keyword.merge(
        [workspace: @workspace, stream: :runs, now: @now, limit: 25, interval: :timer.hours(1)],
        extra
      )

    start_supervised!({Poller, opts})
  end

  describe "polling" do
    test "poll_now/1 ingests a page synchronously" do
      pid = start_poller()

      assert {:ok, result} = Poller.poll_now(pid)
      assert result.runs == 25
      assert Repo.aggregate(Run, :count) == 25
    end

    test "tracks what it has done" do
      pid = start_poller()
      {:ok, _} = Poller.poll_now(pid)

      state = Poller.state(pid)
      assert state.polls == 1
      assert state.workspace == @workspace
      assert state.stream == :runs
    end

    test "successive polls advance through the window" do
      pid = start_poller()

      {:ok, first} = Poller.poll_now(pid)
      {:ok, second} = Poller.poll_now(pid)

      assert DateTime.compare(second.watermark, first.watermark) == :gt
    end
  end

  describe "registration" do
    test "is addressable by workspace and stream" do
      start_poller()

      assert {:ok, result} = Poller.poll_now({@workspace, :runs})
      assert result.runs == 25
    end

    test "runs and feedback are separate processes" do
      runs = start_poller(stream: :runs)
      feedback = start_poller(stream: :feedback)

      refute runs == feedback
    end
  end

  describe "resilience" do
    defmodule FailingClient do
      @moduledoc false
      @behaviour AgentLens.LangSmith.Client

      @impl true
      def list_runs(_workspace, _opts), do: {:error, :timeout}

      @impl true
      def list_feedback(_workspace, _opts), do: {:error, :timeout}
    end

    # A LangSmith outage must not take down the poller. It records the failure,
    # backs off, and tries again.
    test "survives a failing client" do
      pid = start_poller(client: FailingClient)

      assert {:error, :timeout} = Poller.poll_now(pid)
      assert Process.alive?(pid)
      assert Poller.state(pid).failures == 1
    end

    test "recovers once the client works again" do
      pid = start_poller(client: FailingClient)
      {:error, :timeout} = Poller.poll_now(pid)

      :ok = Poller.set_client(pid, AgentLens.LangSmith.Mock)

      assert {:ok, _} = Poller.poll_now(pid)
      assert Poller.state(pid).failures == 0
    end
  end
end
