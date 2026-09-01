# AgentLens

An observability platform for AI agents: reads telemetry from LangSmith,
computes KPIs over time, stores them in PostgreSQL, and renders them per-agent
in a Phoenix LiveView dashboard.

## Read before changing anything

- **[AGENTS.md](AGENTS.md)** — Phoenix and Elixir conventions for this repo
- **[docs/backend-guidelines.md](docs/backend-guidelines.md)** — architecture and
  the invariants that keep the dashboard honest
- **[docs/frontend-guidelines.md](docs/frontend-guidelines.md)** — design system
  and UI rules

These record decisions that are easy to undo by accident, because the
alternatives all look reasonable. Several of them exist because the mistake was
already made once here and caught.

## The two rules that govern everything

1. **Absent is not zero.** `:skip` rather than `{:ok, 0.0}`; `:unknown` that
   never falls through to `:good`; an em dash rather than a `0`; a gap in a
   chart rather than an interpolated line. A dashboard that is confidently wrong
   is worse than one that is unavailable.
2. **Adding a KPI is one new module plus one config line.** Every abstraction in
   the backend exists to protect that, and an acceptance test enforces it.

## Running it

```bash
docker compose up -d    # PostgreSQL on port 5434
mix setup               # deps, database, assets
mix agent_lens.seed     # ~90 days of mock history with injected anomalies
mix phx.server          # http://localhost:4000
```

No LangSmith credentials are needed: with `LANGSMITH_API_KEY` unset the app runs
against a deterministic mock and the dashboard shows a "Mock data" badge.

## Quality gates

```bash
mix precommit    # compile --warnings-as-errors, unused deps, format, credo --strict, test
mix dialyzer
```

Both must be clean before committing.

## Layout

| Path | What |
|---|---|
| `lib/agent_lens/kpi/` | the pure domain — behaviour, definitions, thresholds, status |
| `lib/agent_lens/kpis/` | the KPI modules themselves |
| `lib/agent_lens/ingestion/` | pollers, importers, cursors |
| `lib/agent_lens/lang_smith/` | client behaviour, HTTP, mock, rate limiter |
| `lib/agent_lens/store/` | Ecto schemas |
| `lib/agent_lens/rollup.ex`, `rollup/derived.ex` | observations → buckets |
| `lib/agent_lens/query.ex` | the read path |
| `lib/agent_lens_web/live/` | the three LiveViews |
| `docs/` | the guidelines above |
| `langsmith-observability-spec.md` | the original design brief |
