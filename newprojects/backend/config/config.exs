# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

# §10.1 path 3 — public-tier rate limits (Hammer buckets). The
# defaults are the spec values; tests can override per-bucket
# at runtime. Each entry is `{max_hits, scale_ms}`.
#
# Buckets are referenced by name from `ImmoWeb.Plugs.RateLimit`
# callers — `search`, `geo`, `inquiries` per the §10.1 row.
config :immo, :public_rate_limits,
  search: {60, 60_000},
  geo: {120, 60_000},
  inquiries: {5, 60_000}

# §10.1 path 3 — CORS exact-origin allowlist. Site origins only;
# no wildcards. Overridden in `config/runtime.exs` from
# `PUBLIC_ALLOWED_ORIGINS` (comma-separated). The dev/test env
# gets a local-friendly default so the §6.3 release-gate checks
# (preflight passes for an allowlisted origin, gets no
# `access-control-allow-*` headers for any other origin) can
# run without a runtime env.
config :immo, :public_allowed_origins, []

# Public-tier cache-control defaults (per route, opt-in from
# the controller via `put_resp_header/2` later). These are the
# §6.3 conventions wired in the plug.
config :immo, :public_cache_control,
  search: "private, no-store",
  geo: "public, s-maxage=60, stale-while-revalidate=600"

config :immo, :scopes,
  user: [
    module: Immo.Accounts.Scope,
    assign_key: :current_scope,
    access_path: [:user, :id],
    schema_key: :user_id,
    schema_type: :id,
    schema_table: :users,
    test_data_fixture: Immo.AccountsFixtures,
    test_setup_helper: :register_and_log_in_user
  ]

config :immo,
  ecto_repos: [Immo.Repo],
  generators: [timestamp_type: :utc_datetime]

# Configure the endpoint
config :immo, ImmoWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: ImmoWeb.ErrorHTML, json: ImmoWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Immo.PubSub,
  live_view: [signing_salt: "JLEx4On7"]

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :immo, Immo.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  immo: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  immo: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# §10.1 / §13 — Logger redaction of authorization headers and token
# values. The filter function lives in Immo.LoggerRedaction (testable
# in isolation) and is referenced by name so the rules evolve with
# the test suite, not as a config-string that's invisible to CI.
config :logger, :filter, [
  {Immo.LoggerRedaction, :filtering}
]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
