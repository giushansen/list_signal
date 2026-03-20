import Config

config :ls, LS.Repo, database: Path.expand("../ls_dev.db", __DIR__)

config :ls, LSWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "dev_only_secret_key_base_at_least_64_bytes_long_for_listsignal_2026_xxxxxxxxxxx",
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:ls, ~w(--sourcemap=inline --watch)]},
    tailwind: {Tailwind, :install_and_run, [:ls, ~w(--watch)]}
  ]

config :ls, LSWeb.Endpoint,
  live_reload: [
    patterns: [
      ~r"priv/static/(?!uploads/).*(js|css|png|jpeg|jpg|gif|svg)$",
      ~r"lib/ls_web/(controllers|live|components)/.*(ex|heex)$"
    ]
  ]

config :swoosh, :api_client, false
config :phoenix, :plug_init_mode, :runtime
config :logger, level: :info

# Suppress Erlang TLS noise from crawling random domains
config :logger, :console,
  format: "$time [$level] $message\n",
  metadata: [:request_id]

config :logger,
  handle_otp_reports: true,
  handle_sasl_reports: false

# Filter out :notice level TLS alerts (normal when crawling)
config :logger, compile_time_purge_matching: [
  [module: :tls_record, level_lower_than: :warning],
  [module: :tls_dtls_connection, level_lower_than: :warning]
]
