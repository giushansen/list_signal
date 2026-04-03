import Config

config :ls,
  ecto_repos: [LS.Repo],
  generators: [timestamp_type: :utc_datetime, binary_id: true]

config :ls, LS.Repo,
  database: Path.expand("../ls_#{config_env()}.db", __DIR__),
  pool_size: 5,
  stacktrace: true,
  show_sensitive_data_on_connection_error: true

config :ls, LSWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: LSWeb.ErrorHTML, json: LSWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: LS.PubSub,
  live_view: [signing_salt: "ls_salt_2026"]

config :ls, LS.Mailer, adapter: Swoosh.Adapters.Local

config :logger, :console,
  format: "$time [$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, Jason

# ML — Nx/EXLA configuration
config :nx, default_backend: EXLA.Backend
config :exla, default_client: :host

config :swoosh, :api_client, false

config :ssl,
  session_cache_server_max: 10_000,
  session_cache_client_max: 50_000,
  session_lifetime: 3600,
  protocol_version: [:"tlsv1.3", :"tlsv1.2"]

config :esbuild,
  version: "0.17.11",
  ls: [
    args: ~w(js/app.js --bundle --target=es2017 --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

config :tailwind,
  version: "3.4.3",
  ls: [
    args: ~w(--config=tailwind.config.js --input=css/app.css --output=../priv/static/assets/app.css),
    cd: Path.expand("../assets", __DIR__)
  ]

import_config "#{config_env()}.exs"

# Suppress noisy TLS/SSL warnings from Erlang during HTTP crawling
config :logger,
  handle_otp_reports: true,
  handle_sasl_reports: false

config :logger, :console,
  metadata: [:request_id],
  format: "$time $metadata[$level] $message\n"
config :logger, level: :info
