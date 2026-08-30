# AgentLens

AgentLens is an Elixir project for AI agent observability.

The goal is to make agent runs inspectable by capturing normalized trace events
for LLM calls, tool calls, planning steps, memory operations, evaluations, and
errors.

## Current capabilities

- OTP application scaffold (`mix new --sup`)
- In-memory event store (`AgentLens.Store`)
- Normalized event struct (`AgentLens.Event`)
- Public API for starting traces and recording events

## Quick start

```bash
cd agent_lens
mix test
iex -S mix
```

```elixir
trace_id = AgentLens.start_trace("support-agent-run", attributes: %{agent: "support"})

AgentLens.record(:tool_call,
  trace_id: trace_id,
  name: "lookup_customer",
  duration_ms: 18,
  status: :ok,
  attributes: %{customer_id: "cus_123"}
)

AgentLens.recent_events(trace_id: trace_id)
```

## Roadmap ideas

- OpenTelemetry integration
- Phoenix dashboard for live agent traces
- Persistent storage for runs and spans
- Token/cost tracking for LLM calls
- Tool-call waterfall views
- Prompt/response redaction controls
- Evaluation and regression tracking
