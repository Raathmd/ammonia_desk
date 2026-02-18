defmodule TradingDesk.Scenarios.Store do
  @moduledoc """
  Stores saved scenarios and their results.

  Each scenario is linked to its `audit_id` — the SolveAudit record
  that captures exactly which contract versions and variable sources
  were active when the scenario was generated.
  """
  use GenServer

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @doc """
  Save a scenario with an audit trail link.

  The `audit_id` links this scenario to a SolveAudit record
  (same as the pipeline's run_id). Pass nil if no audit available.
  """
  def save(trader_id, name, variables, result, audit_id \\ nil) do
    GenServer.call(__MODULE__, {:save, trader_id, name, variables, result, audit_id})
  end

  def list(trader_id) do
    GenServer.call(__MODULE__, {:list, trader_id})
  end

  def delete(trader_id, scenario_id) do
    GenServer.cast(__MODULE__, {:delete, trader_id, scenario_id})
  end

  @doc "Get all scenarios linked to a specific audit record."
  def find_by_audit(audit_id) do
    GenServer.call(__MODULE__, {:find_by_audit, audit_id})
  end

  @impl true
  def init(_) do
    table = :ets.new(:scenarios, [:set, :protected])
    audit_index = :ets.new(:scenario_audits, [:bag, :protected])
    {:ok, %{table: table, audit_index: audit_index, counter: 0}}
  end

  @impl true
  def handle_call({:save, trader_id, name, variables, result, audit_id}, _from, state) do
    id = state.counter + 1
    scenario = %{
      id: id,
      trader_id: trader_id,
      name: name,
      variables: variables,
      result: result,
      audit_id: audit_id,
      saved_at: DateTime.utc_now()
    }
    :ets.insert(state.table, {{trader_id, id}, scenario})

    # Index by audit_id for reverse lookup
    if audit_id do
      :ets.insert(state.audit_index, {audit_id, {trader_id, id}})

      # Link the scenario back to the audit record
      link_to_audit(audit_id, id)
    end

    # Persist to Postgres (async)
    TradingDesk.DB.Writer.persist_scenario(scenario)

    {:reply, {:ok, scenario}, %{state | counter: id}}
  end

  @impl true
  def handle_call({:list, trader_id}, _from, state) do
    scenarios =
      :ets.match_object(state.table, {{trader_id, :_}, :_})
      |> Enum.map(fn {_key, scenario} -> scenario end)
      |> Enum.sort_by(& &1.saved_at, {:desc, DateTime})

    {:reply, scenarios, state}
  end

  @impl true
  def handle_call({:find_by_audit, audit_id}, _from, state) do
    scenarios =
      :ets.lookup(state.audit_index, audit_id)
      |> Enum.map(fn {_audit_id, {trader_id, scenario_id}} ->
        case :ets.lookup(state.table, {trader_id, scenario_id}) do
          [{_key, scenario}] -> scenario
          [] -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    {:reply, scenarios, state}
  end

  @impl true
  def handle_cast({:delete, trader_id, id}, state) do
    :ets.delete(state.table, {trader_id, id})
    {:noreply, state}
  end

  defp link_to_audit(audit_id, scenario_id) do
    case TradingDesk.Solver.SolveAuditStore.get(audit_id) do
      {:ok, audit} ->
        updated = %{audit | scenario_id: scenario_id}
        TradingDesk.Solver.SolveAuditStore.record(updated)
      _ ->
        :ok
    end
  end
end
