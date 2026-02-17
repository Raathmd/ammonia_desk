defmodule TradingDesk.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      TradingDesk.Repo,
      TradingDesk.DB.SnapshotLog,
      {Phoenix.PubSub, name: TradingDesk.PubSub},
      TradingDesk.Config.DeltaConfig,
      TradingDesk.Data.LiveState,
      TradingDesk.Data.Poller,
      TradingDesk.Solver.Port,
      TradingDesk.Solver.SolveAuditStore,
      TradingDesk.Scenarios.Store,
      TradingDesk.Scenarios.AutoRunner,
      TradingDesk.Contracts.Store,
      TradingDesk.Contracts.CurrencyTracker,
      TradingDesk.Contracts.NetworkScanner,
      {Task.Supervisor, name: TradingDesk.Contracts.TaskSupervisor},
      TradingDesk.Endpoint
    ]

    opts = [strategy: :one_for_one, name: TradingDesk.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
