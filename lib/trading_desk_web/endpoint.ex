defmodule TradingDesk.Endpoint do
  use Phoenix.Endpoint, otp_app: :trading_desk

  @session_options [
    store: :cookie,
    key: "_trading_desk_key",
    signing_salt: "nh3bargesalt"
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]]

  plug Plug.Static,
    at: "/",
    from: :trading_desk,
    gzip: false

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Jason

  plug Plug.Session, @session_options

  plug TradingDesk.Router
end
