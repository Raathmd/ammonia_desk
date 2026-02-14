defmodule AmmoniaDesk.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: AmmoniaDesk.PubSub},
      AmmoniaDesk.Data.LiveState,
      AmmoniaDesk.Data.Poller,
      AmmoniaDesk.Solver.Port,
      AmmoniaDesk.Solver.SolveAuditStore,
      AmmoniaDesk.Scenarios.Store,
      AmmoniaDesk.Scenarios.AutoRunner,
      AmmoniaDesk.Contracts.Store,
      AmmoniaDesk.Contracts.CurrencyTracker,
      AmmoniaDesk.Contracts.NetworkScanner,
      {Task.Supervisor, name: AmmoniaDesk.Contracts.TaskSupervisor},
      AmmoniaDesk.Endpoint
    ]

    opts = [strategy: :one_for_one, name: AmmoniaDesk.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
