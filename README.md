# AgentLens

An observability platform for AI agents. AgentLens reads agent telemetry from
[LangSmith](https://smith.langchain.com), computes KPIs over time, stores them in Postgres, and
renders them per-agent in a Phoenix LiveView dashboard.

## Core idea: three kinds of KPI

"KPI" covers three things with very different cost profiles, and each gets its own scheduler and
backpressure story.

| Kind | Cost | Computed |
|---|---|---|
| `:extracted` | free — arithmetic on the run payload | inline during ingest, on every run |
| `:judged` | a model call, so money and seconds | sampled, asynchronous, retried |
| `:derived` | cheap, but needs other KPIs' rollups | on bucket close |

A fourth *source* (not a fourth kind) is `:imported` — scores LangSmith's own online evaluators
computed, pulled in through the feedback API. These land in the same table as judged values and
flow through the same rollup path.

## Agent identity

Agent identity is the **LangSmith workspace**: each agent traces into its own workspace, so the
workspace id is the dimension every KPI slices by. One org-scoped API key covers every workspace.

## Adding a KPI

This is the extensibility seam, and it is deliberately one file plus one line.

1. Write a module implementing the `AgentLens.Kpi` behaviour.
2. Add it to the `:kpis` list under `config :agent_lens, AgentLens.Kpi.Registry` in
   `config/config.exs`.

Nothing else changes. Rollups and UI both read definitions from the registry rather than knowing
about modules, so a new KPI propagates to both without either being modified. `mix test` includes
an acceptance test that enforces this.

## Getting started

Requires Elixir 1.17+, Erlang/OTP 26+, and a reachable PostgreSQL.

```bash
mix setup             # deps, database, assets
mix agent_lens.seed   # ~90 days of mock history, with anomalies
mix phx.server        # http://localhost:4000
```

`mix agent_lens.seed` backfills every configured workspace from the mock client — roughly 21,600
runs and 50,000 observations per agent. It is safe to re-run; everything upserts on its natural key.
Automatic polling is off by default so `mix test` and `mix run` stay fast; enable it with
`config :agent_lens, AgentLens.Ingestion, enabled: true`.

Database connection defaults to `localhost:5433` and can be overridden with the standard
`PGHOST` / `PGPORT` / `PGUSER` / `PGPASSWORD` environment variables.

## Configuration

Dev and test run against a **mock LangSmith client** by default: no API key, no network. The mock
is deterministic — the same window returns identical data every time — so it doubles as the fixture
set for drift detection rather than being mere filler. It injects three findable events, exposed
symbolically via `AgentLens.LangSmith.Mock.anomalies/0`:

| Anomaly | What it looks like |
|---|---|
| Latency spike | ~1.2s → ~7s for four days, with errors rising alongside, then recovers |
| Toxicity regression | 0.02 → 0.16 at a simulated model version change, and does **not** recover |
| Cost creep | Per-run cost drifting steadily upward across the window |

| Variable | Default | Notes |
|---|---|---|
| `LANGSMITH_CLIENT` | `mock` (`http` in prod) | selects the client implementation |
| `LANGSMITH_API_KEY` | — | required only when the client is `http` |
| `LANGSMITH_ENDPOINT` | `https://api.smith.langchain.com` | override for self-hosted |
| `LANGSMITH_WORKSPACES` | — | comma-separated workspace ids, one per agent |

## Quality gates

```bash
mix precommit       # compile --warnings-as-errors, unused deps, format, credo, test
mix dialyzer
```

## Status

Phase 0 (scaffold) and Phase 1 (domain core) of an eight-phase build. The domain core is pure —
no database, no HTTP, no processes on the data path. Ingestion, rollups, and the dashboard follow.
