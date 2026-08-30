defmodule AgentLens.Kpi.InputTest do
  use ExUnit.Case, async: true

  alias AgentLens.Kpi.Input

  defp run do
    %Input.Run{
      langsmith_run_id: "run-1",
      agent_id: "ws-support",
      status: "success",
      latency_ms: 1200,
      payload: %{
        "outputs" => %{"text" => "hello"},
        "extra" => %{"metadata" => %{"model" => "claude-opus-5"}}
      },
      feedback: %{"kpi.toxicity" => 0.02}
    }
  end

  describe "Run.fetch/2 reads through the same vocabulary requires/0 declares" do
    test "reads a flattened column" do
      assert {:ok, 1200} = Input.Run.fetch(run(), :latency_ms)
      assert {:ok, "success"} = Input.Run.fetch(run(), :status)
    end

    test "reads a nested payload path" do
      assert {:ok, "hello"} = Input.Run.fetch(run(), {:payload, ["outputs", "text"]})

      assert {:ok, "claude-opus-5"} =
               Input.Run.fetch(run(), {:payload, ["extra", "metadata", "model"]})
    end

    test "reads a feedback score" do
      assert {:ok, 0.02} = Input.Run.fetch(run(), {:feedback, "kpi.toxicity"})
    end

    test "returns :error for an absent payload path rather than nil" do
      assert :error = Input.Run.fetch(run(), {:payload, ["outputs", "missing"]})
      assert :error = Input.Run.fetch(run(), {:payload, ["nope", "deeper"]})
    end

    test "returns :error for an absent feedback key" do
      assert :error = Input.Run.fetch(run(), {:feedback, "kpi.groundedness"})
    end

    test "returns :error when a column is present on the struct but unset" do
      assert :error = Input.Run.fetch(run(), :cost_usd)
    end

    test "does not walk into a non-map partway down a payload path" do
      assert :error = Input.Run.fetch(run(), {:payload, ["outputs", "text", "deeper"]})
    end
  end

  describe "Window accessors" do
    setup do
      window = %Input.Window{
        agent_id: "ws-support",
        bucket_start: ~U[2026-08-30 00:00:00Z],
        bucket_end: ~U[2026-08-31 00:00:00Z],
        granularity: :day,
        current: %{latency_ms: [100.0, 200.0]},
        baseline: %{latency_ms: [90.0, 110.0]}
      }

      %{window: window}
    end

    test "reads the current series for a slug", %{window: window} do
      assert [100.0, 200.0] = Input.Window.current(window, :latency_ms)
    end

    test "reads the baseline series for a slug", %{window: window} do
      assert [90.0, 110.0] = Input.Window.baseline(window, :latency_ms)
    end

    test "returns an empty series for an absent slug rather than nil", %{window: window} do
      assert [] = Input.Window.current(window, :toxicity)
      assert [] = Input.Window.baseline(window, :toxicity)
    end
  end
end
