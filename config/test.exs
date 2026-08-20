import Config

# Only in tests, remove the complexity from the password hashing algorithm
config :bcrypt_elixir, :log_rounds, 1
config :ls, LS.Repo,
  database: Path.expand("../ls_test.db", __DIR__),
  pool: Ecto.Adapters.SQL.Sandbox,
  # SQLite is single-writer: pool_size > 1 trades queue_timeout flakes for
  # "Database busy" lock contention, which is worse. Keep one connection and
  # let callers WAIT instead of being dropped — the suite was failing 10-15
  # random tests per run purely because a busy machine pushed checkout past
  # the 50ms default queue_target. A suite that fails randomly teaches people
  # to ignore red, which is worse than no suite at all.
  # ONE connection: SQLite serializes writers, so any pool > 1 turns
  # concurrent write transactions into "Database busy" failures (pool 3 and
  # pool 10 both proved it). The long queue makes callers WAIT for the single
  # connection instead of being dropped at the 50ms default. CH-heavy render
  # tests must CHECKIN the connection during their slow parts (see
  # public_nav_test) — holding it past 60s times out every queued setup.
  pool_size: 1,
  queue_target: 5_000,
  queue_interval: 30_000,
  busy_timeout: 15_000
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
# No analytics tag in test HTML (and never a prod beacon from CI).
config :ls, :umami, website_id: nil
config :ls, sentinel_enabled: false
config :ls, cache_await_ms: 1_000
