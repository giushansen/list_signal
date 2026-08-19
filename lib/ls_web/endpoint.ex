defmodule LSWeb.Endpoint do
  @moduledoc "Phoenix endpoint: TLS termination (behind Cloudflare), static assets, sessions."
  use Phoenix.Endpoint, otp_app: :ls

  @session_options [
    store: :cookie,
    key: "_ls_key",
    signing_salt: "ls_sign",
    same_site: "Lax"
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: [connect_info: [session: @session_options]]

  plug Plug.Static,
    at: "/",
    from: :ls,
    gzip: false,
    only: LSWeb.static_paths()

  if code_reloading? do
    socket "/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket
    plug Phoenix.LiveReloader
    plug Phoenix.CodeReloader
  end

  plug Phoenix.LiveDashboard.RequestLogger,
    param_key: "request_logger",
    cookie_key: "request_logger"

  plug Plug.RequestId
  # After Plug.Static (assets are cheap and must not be shed), before routing
  # and body parsing — a shed request should cost as little as possible.
  plug LSWeb.Plugs.OverloadGuard

  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library(),
    body_reader: {LSWeb.RawBodyReader, :read_body, []}

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug LSWeb.Router
end
