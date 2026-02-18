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

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", TradingDesk do
    pipe_through :browser
    live "/", ScenarioLive
    live "/contracts", ContractsLive
  end

  # SAP integration endpoints
  scope "/api/sap", TradingDeskWeb do
    pipe_through :api

    # SAP calls this when a contract position changes
    post "/ping", SapWebhookController, :ping

    # Health check for SAP refresh scheduler
    get "/status", SapWebhookController, :status
  end
end
