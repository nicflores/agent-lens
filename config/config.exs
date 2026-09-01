# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :agent_lens,
  ecto_repos: [AgentLens.Repo],
  generators: [timestamp_type: :utc_datetime]

# The KPI registry.
#
# This list is the whole extensibility seam: adding a KPI is one new module
# implementing `AgentLens.Kpi` plus one line here. Nothing else in the system
# needs to change — rollups and UI both read definitions rather than modules.
config :agent_lens, AgentLens.Kpi.Registry,
  kpis: [
    AgentLens.Kpis.SuccessRate,
    AgentLens.Kpis.LatencyP95,
    AgentLens.Kpis.Toxicity,
    AgentLens.Kpis.Sentiment,
    AgentLens.Kpis.Drift
  ]

# Background jobs.
#
# The rollup cadence is staggered rather than all-on-the-hour: each grain
# recomputes a window of recent buckets, so late observations are picked up
# without any job needing to know whether another has finished.
config :agent_lens, Oban,
  repo: AgentLens.Repo,
  queues: [rollups: 4, maintenance: 1, judge: 2],
  plugins: [
    {Oban.Plugins.Cron,
     crontab: [
       {"* * * * *", AgentLens.Workers.RollupWorker, args: %{"granularity" => "minute"}},
       {"7 * * * *", AgentLens.Workers.RollupWorker, args: %{"granularity" => "hour"}},
       {"20 0 * * *", AgentLens.Workers.RollupWorker, args: %{"granularity" => "day"}},
       # After the daily rollup, so the series it compares are complete.
       {"40 0 * * *", AgentLens.Workers.DerivedWorker},
       {"30 3 * * *", AgentLens.Workers.RetentionWorker}
     ]},
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7}
  ]

# The tool's own model access, pointed at a LiteLLM proxy so routing, keys and
# cost accounting stay where they already live. Falls back to a deterministic
# mock, so dev and test cost nothing.
config :agent_lens, :llm,
  client: AgentLens.LLM.Mock,
  model: "gpt-4o-mini"

# Configure the endpoint
config :agent_lens, AgentLensWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: AgentLensWeb.ErrorHTML, json: AgentLensWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: AgentLens.PubSub,
  live_view: [signing_salt: "BayRJQ5e"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  agent_lens: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  agent_lens: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
