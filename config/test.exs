import Config

# Only in tests, remove the complexity from the password hashing algorithm
config :bcrypt_elixir, :log_rounds, 1
config :ls, LS.Repo,
  database: Path.expand("../ls_test.db", __DIR__),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 1
config :ls, LSWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "test_only_secret_key_base_at_least_64_bytes_long_for_listsignal_testing_2026_xxx",
  server: false
config :ls, LS.Mailer, adapter: Swoosh.Adapters.Test
config :swoosh, :api_client, false
config :logger, level: :warning
config :ls, :stripe_client, nil
# Suppress pipeline processes during tests
config :ls, ls_role: "test"
