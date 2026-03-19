import Config
config :ls, LS.Repo, database: Path.expand("../ls_test.db", __DIR__), pool_size: 1
config :ls, LSWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "test_only_secret_key_base_at_least_64_bytes_long_for_listsignal_testing_2026_xxx",
  server: false
config :ls, LS.Mailer, adapter: Swoosh.Adapters.Test
config :swoosh, :api_client, false
config :logger, level: :warning
