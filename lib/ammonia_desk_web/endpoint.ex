defmodule AmmoniaDesk.Endpoint do
  use Phoenix.Endpoint, otp_app: :ammonia_desk

  @session_options [
    store: :cookie,
    key: "_ammonia_desk_key",
    signing_salt: "nh3bargesalt"
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]]

  plug Plug.Static,
    at: "/",
    from: :ammonia_desk,
    gzip: false

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Jason

  plug Plug.Session, @session_options

  plug AmmoniaDesk.Router
end
