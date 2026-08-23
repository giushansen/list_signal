import Config

if System.get_env("PHX_SERVER") || System.get_env("LS_ROLE") == "master" do
  config :ls, LSWeb.Endpoint, server: true
end

# Stripe config (all envs)
# Pipeline 3 (verification). SEC EDGAR's fair-access policy requires a
# contact in the User-Agent; the same UA identifies us to every source.
config :ls, :sec_edgar_contact, System.get_env("SEC_EDGAR_CONTACT", "will@keybloc.io")

# Ops email: where infra/quality alerts and the weekly report go, and the
# From identity every ListSignal email shares (was hardcoded in UserNotifier).
config :ls, :mail_from, {"ListSignal", System.get_env("MAIL_FROM", "team@listsignal.com")}

config :ls, :alert_emails,
  (System.get_env("LS_ALERT_EMAILS", "will@listsignal.com")
   |> String.split(",", trim: true)
   |> Enum.map(&String.trim/1))
config :ls, :verification_dir, System.get_env("LS_VERIFICATION_DIR", "/home/ls/verification")

config :ls, :stripe_publishable_key, System.get_env("STRIPE_PUBLISHABLE_KEY")
config :ls, :stripe_secret_key, System.get_env("STRIPE_SECRET_KEY")
config :stripity_stripe, api_key: System.get_env("STRIPE_SECRET_KEY")
config :ls, :stripe_webhook_secret, System.get_env("STRIPE_WEBHOOK_SECRET")
config :ls, :stripe_pro_monthly_price_id, System.get_env("STRIPE_PRO_MONTHLY_PRICE_ID")
config :ls, :stripe_pro_yearly_price_id, System.get_env("STRIPE_PRO_YEARLY_PRICE_ID")
config :ls, :stripe_starter_monthly_price_id, System.get_env("STRIPE_STARTER_MONTHLY_PRICE_ID")
config :ls, :stripe_starter_yearly_price_id, System.get_env("STRIPE_STARTER_YEARLY_PRICE_ID")

# Umami analytics override — the default (public) website_id lives in config.exs;
# these let ops point at a different site or script host without a rebuild.
if id = System.get_env("UMAMI_WEBSITE_ID") do
  config :ls, :umami,
    website_id: id,
    src: System.get_env("UMAMI_SRC") || "https://stats.listsignal.com/script.js"
end

# Admin/monitoring panel allowlist (comma-separated emails). Empty = nobody.
config :ls, :admin_emails,
  (System.get_env("LS_ADMIN_EMAILS") || "")
  |> String.split(",", trim: true)
  |> Enum.map(fn e -> e |> String.trim() |> String.downcase() end)

if config_env() == :prod do
  database_path = System.get_env("DATABASE_PATH") || Path.expand("../ls_prod.db", __DIR__)
  config :ls, LS.Repo, database: database_path

  secret_key_base = System.get_env("SECRET_KEY_BASE") || raise "set SECRET_KEY_BASE"
  host = System.get_env("PHX_HOST") || "localhost"
  port = String.to_integer(System.get_env("PORT") || "4000")

  config :ls, LSWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    https: [
      ip: {0, 0, 0, 0},
      port: port,
      cipher_suite: :strong,
      certfile: System.get_env("SSL_CERT_FILE"),
      keyfile: System.get_env("SSL_KEY_FILE"),
      # Load shedding. Without a ceiling the server accepts every arriving
      # connection, spawns a process for each, and the BEAM grows until it
      # crosses its cgroup memory limit — at which point the kernel stalls
      # the whole VM and the watchdog restarts it. That is a 2026-08-19
      # outage (a 300-concurrent load test drove the BEAM to 6.3G) and it is
      # exactly what a front-page launch spike would do.
      #
      # 400 concurrent is far above real demand (cached pages serve at
      # ~120/s, so 400 in flight means something pathological); beyond it,
      # connections wait in the accept queue instead of consuming heap. A
      # queued request is slow. An OOM restart drops EVERY request.
      # Bandit rejects :max_connections in thousand_island_options (it owns
      # connection handling itself); the supported lever is num_acceptors,
      # which bounds how many sockets are accepted concurrently.
      thousand_island_options: [num_acceptors: 50]
    ],
    secret_key_base: secret_key_base

  config :ls, :dns_rewrite_on_redirect, host

  config :ls, LS.Mailer,
    adapter: Swoosh.Adapters.Mailgun,
    api_key: System.get_env("MAILGUN_API_KEY"),
    domain: System.get_env("MAILGUN_DOMAIN")
end

# Filter noisy TLS alerts from Erlang SSL module
:logger.add_primary_filter(:tls_filter, {
  fn
    %{msg: {:report, %{description: ~c"TLS" ++ _}}}, _extra -> :stop
    %{msg: {:string, msg}}, _extra when is_list(msg) ->
      if :string.find(msg, ~c"SERVER ALERT") != :nomatch, do: :stop, else: :ignore
    _, _ -> :ignore
  end,
  %{}
})

if config_env() != :test do
  :logger.add_primary_filter(:tls_filter, {fn _, _ -> :ignore end, %{}})
end
