import Config

config :ammonia_desk, AmmoniaDesk.Endpoint,
  url: [host: "localhost"],
  http: [port: 4000],
  secret_key_base: String.duplicate("nh3bargetrading", 6),
  live_view: [signing_salt: "nh3livebargedesk"],
  render_errors: [formats: [html: AmmoniaDesk.ErrorHTML]],
  pubsub_server: AmmoniaDesk.PubSub,
  server: true

config :logger, level: :info

config :phoenix, :json_library, Jason
