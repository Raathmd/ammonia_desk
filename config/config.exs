import Config

config :trading_desk, TradingDesk.Endpoint,
  url: [host: "localhost"],
  http: [port: 4000],
  secret_key_base: String.duplicate("nh3bargetrading", 6),
  live_view: [signing_salt: "nh3livebargedesk"],
  render_errors: [formats: [html: TradingDesk.ErrorHTML]],
  pubsub_server: TradingDesk.PubSub,
  server: true

config :trading_desk, TradingDesk.Repo,
  database: "trading_desk_#{Mix.env()}",
  username: System.get_env("PGUSER") || "postgres",
  password: System.get_env("PGPASSWORD") || "postgres",
  hostname: System.get_env("PGHOST") || "localhost",
  port: String.to_integer(System.get_env("PGPORT") || "5432"),
  pool_size: 10

config :trading_desk, ecto_repos: [TradingDesk.Repo]

config :logger, level: :info

config :phoenix, :json_library, Jason
