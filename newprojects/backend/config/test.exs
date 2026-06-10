import Config

# Only in tests, remove the complexity from the password hashing algorithm
config :argon2_elixir, t_cost: 1, m_cost: 8

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :immo, Immo.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "immo_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :immo, ImmoWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "TZ3CNcSej5B9mDuoZPBV4YQJLbX8ay6o/yh/66LTJlLKPP/oUgqqxxM9yhuzE2Et",
  server: false

# In test we don't send emails
config :immo, Immo.Mailer, adapter: Swoosh.Adapters.Test

# §5.13 / D13 — billing gate default for tests. The matrix tests
# in P1-E2.3 set this explicitly per-axis; the default below keeps
# the gate inert for any test that does not opt in.
config :immo, :billing_enforced, false



# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

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
