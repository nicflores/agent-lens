import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :agent_lens, AgentLens.Repo,
  username: System.get_env("PGUSER", "cora"),
  password: System.get_env("PGPASSWORD", "cora_local_dev_only"),
  hostname: System.get_env("PGHOST", "localhost"),
  port: String.to_integer(System.get_env("PGPORT", "5433")),
  database: "agent_lens_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :agent_lens, AgentLensWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "4qq4CW22XjmuNTeUjiRZ3DJ4woWwJk4kMhJoJ0CRP+0WbzNEd8Qq+bGmzzCKamfs",
  server: false

# Jobs are enqueued but never executed unless a test asks; the sandbox owns
# the connection, and a background queue draining against it would be a race.
config :agent_lens, Oban, testing: :manual

# The sandbox owns the connection in test, and each test sets up exactly the
# state it needs, so the startup sweep is driven explicitly instead.
config :agent_lens, AgentLens.Boot, enabled: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
