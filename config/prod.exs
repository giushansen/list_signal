import Config
config :ls, LSWeb.Endpoint, cache_static_manifest: "priv/static/cache_manifest.json"
config :swoosh, api_client: Swoosh.ApiClient.Hackney
config :logger, level: :info
