defmodule AgentLensTest do
  use ExUnit.Case, async: false

  test "starts a trace and records related events" do
    trace_id = AgentLens.start_trace("research-agent-run", attributes: %{agent: "researcher"})

    event =
      AgentLens.record(:llm_call,
        trace_id: trace_id,
        name: "summarize",
        duration_ms: 42,
        status: :ok,
        attributes: %{model: "example-model", input_tokens: 120, output_tokens: 48}
      )

    assert event.trace_id == trace_id
    assert event.type == :llm_call

    assert [^event | _] = AgentLens.recent_events(trace_id: trace_id, limit: 2)
  end
end
