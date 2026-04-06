import Config

if System.get_env("PHX_SERVER") || System.get_env("LS_ROLE") == "master" do
  config :ls, LSWeb.Endpoint, server: true
end

# Stripe config (all envs)
config :ls, :stripe_publishable_key, System.get_env("STRIPE_PUBLISHABLE_KEY")
config :ls, :stripe_secret_key, System.get_env("STRIPE_SECRET_KEY")
config :stripity_stripe, api_key: System.get_env("STRIPE_SECRET_KEY")
config :ls, :stripe_webhook_secret, System.get_env("STRIPE_WEBHOOK_SECRET")
config :ls, :stripe_pro_monthly_price_id, System.get_env("STRIPE_PRO_MONTHLY_PRICE_ID")
config :ls, :stripe_pro_yearly_price_id, System.get_env("STRIPE_PRO_YEARLY_PRICE_ID")

if config_env() == :prod do
  database_path = System.get_env("DATABASE_PATH") || Path.expand("../ls_prod.db", __DIR__)
  config :ls, LS.Repo, database: database_path

  secret_key_base = System.get_env("SECRET_KEY_BASE") || raise "set SECRET_KEY_BASE"
  host = System.get_env("PHX_HOST") || "localhost"
  port = String.to_integer(System.get_env("PORT") || "4000")

  config :ls, LSWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [ip: {0, 0, 0, 0}, port: port],
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

