defmodule TradingDesk.Repo do
  use Ecto.Repo,
    otp_app: :trading_desk,
    adapter: Ecto.Adapters.Postgres
end
