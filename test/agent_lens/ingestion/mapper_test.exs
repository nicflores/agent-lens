defmodule AgentLens.Ingestion.MapperTest do
  use ExUnit.Case, async: true

  alias AgentLens.Ingestion.Mapper
  alias AgentLens.Kpi.Input

  defp payload(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => "run-1",
        "trace_id" => "trace-1",
        "parent_run_id" => nil,
        "name" => "agent_turn",
        "run_type" => "chain",
        "start_time" => ~U[2026-08-30 12:00:00.000000Z],
        "end_time" => ~U[2026-08-30 12:00:01.200000Z],
        "latency_ms" => 1200,
        "status" => "success",
        "error" => nil,
        "prompt_tokens" => 900,
        "completion_tokens" => 200,
        "total_cost" => 0.0057,
        "outputs" => %{"text" => "hello"},
        "extra" => %{"metadata" => %{"model" => "claude-opus-5"}}
      },
      overrides
    )
  end

  describe "to_run_attrs/2" do
    test "maps the flattened columns" do
      attrs = Mapper.to_run_attrs(payload(), "ws-support")

      assert attrs.langsmith_run_id == "run-1"
      assert attrs.trace_id == "trace-1"
      assert attrs.run_type == "chain"
      assert attrs.status == "success"
      assert attrs.prompt_tokens == 900
    end

    # Agent identity is the workspace we polled, not anything in the payload.
    test "takes agent_id from the workspace rather than the payload" do
      attrs = Mapper.to_run_attrs(payload(%{"agent_id" => "not-this"}), "ws-support")

      assert attrs.agent_id == "ws-support"
    end

    test "lifts the model out of nested metadata" do
      assert %{model: "claude-opus-5"} = Mapper.to_run_attrs(payload(), "ws-support")
    end

    test "retains the whole payload for KPIs added later" do
      attrs = Mapper.to_run_attrs(payload(), "ws-support")

      assert get_in(attrs.payload, ["outputs", "text"]) == "hello"
    end

    test "converts cost to a decimal so money is not stored as a float" do
      attrs = Mapper.to_run_attrs(payload(), "ws-support")

      assert Decimal.equal?(attrs.cost_usd, Decimal.from_float(0.0057))
    end

    # The real HTTP client returns ISO strings where the mock returns structs.
    test "parses ISO 8601 timestamps as well as DateTime structs" do
      attrs =
        payload(%{"start_time" => "2026-08-30T12:00:00.000000Z"})
        |> Mapper.to_run_attrs("ws-support")

      assert attrs.start_time == ~U[2026-08-30 12:00:00.000000Z]
    end

    test "derives latency from the timestamps when it is not reported" do
      attrs = payload(%{"latency_ms" => nil}) |> Mapper.to_run_attrs("ws-support")

      assert attrs.latency_ms == 1200
    end

    test "leaves latency nil for a run that has not finished" do
      attrs =
        payload(%{"latency_ms" => nil, "end_time" => nil}) |> Mapper.to_run_attrs("ws-support")

      assert attrs.latency_ms == nil
    end

    test "tolerates a payload missing optional fields" do
      minimal = %{"id" => "run-2", "start_time" => ~U[2026-08-30 12:00:00.000000Z]}
      attrs = Mapper.to_run_attrs(minimal, "ws-support")

      assert attrs.langsmith_run_id == "run-2"
      assert attrs.model == nil
      assert attrs.cost_usd == nil
    end
  end

  describe "to_input/2" do
    test "builds the struct the KPI behaviour computes from" do
      input =
        payload()
        |> Mapper.to_run_attrs("ws-support")
        |> Mapper.to_input(%{"kpi.toxicity" => 0.02})

      assert %Input.Run{} = input
      assert input.agent_id == "ws-support"
      assert input.latency_ms == 1200
      assert input.feedback == %{"kpi.toxicity" => 0.02}
    end

    test "carries the payload so payload-path KPIs can read it" do
      input = payload() |> Mapper.to_run_attrs("ws-support") |> Mapper.to_input()

      assert {:ok, "hello"} = Input.Run.fetch(input, {:payload, ["outputs", "text"]})
    end

    test "defaults to no feedback" do
      input = payload() |> Mapper.to_run_attrs("ws-support") |> Mapper.to_input()

      assert input.feedback == %{}
    end
  end

  describe "to_feedback_scores/1" do
    test "collapses feedback records into a key-to-score map" do
      records = [
        %{"run_id" => "run-1", "key" => "kpi.toxicity", "score" => 0.02},
        %{"run_id" => "run-1", "key" => "kpi.polarity", "score" => 0.4}
      ]

      assert %{"kpi.toxicity" => 0.02, "kpi.polarity" => 0.4} =
               Mapper.to_feedback_scores(records)
    end

    test "ignores records with no score" do
      records = [%{"run_id" => "r", "key" => "kpi.toxicity", "score" => nil}]

      assert %{} == Mapper.to_feedback_scores(records)
    end
  end
end
