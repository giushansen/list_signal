import Config

if System.get_env("PHX_SERVER") || System.get_env("LS_ROLE") == "master" do
  config :ls, LSWeb.Endpoint, server: true
end

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
end
