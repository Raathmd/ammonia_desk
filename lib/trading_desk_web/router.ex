defmodule TradingDesk.Router do
  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, {TradingDesk.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  scope "/", TradingDesk do
    pipe_through :browser
    live "/", ScenarioLive
    live "/contracts", ContractsLive
  end
end
