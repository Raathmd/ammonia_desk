defmodule AmmoniaDesk.Scenarios.Store do
  @moduledoc """
  Stores saved scenarios and their results.
  In production, backed by a database. For now, ETS.
  """
  use GenServer

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  def save(trader_id, name, variables, result) do
    GenServer.call(__MODULE__, {:save, trader_id, name, variables, result})
  end

  def list(trader_id) do
    GenServer.call(__MODULE__, {:list, trader_id})
  end

  def delete(trader_id, scenario_id) do
    GenServer.cast(__MODULE__, {:delete, trader_id, scenario_id})
  end

  @impl true
  def init(_) do
    table = :ets.new(:scenarios, [:set, :protected])
    {:ok, %{table: table, counter: 0}}
  end

  @impl true
  def handle_call({:save, trader_id, name, variables, result}, _from, state) do
    id = state.counter + 1
    scenario = %{
      id: id,
      trader_id: trader_id,
      name: name,
      variables: variables,
      result: result,
      saved_at: DateTime.utc_now()
    }
    :ets.insert(state.table, {{trader_id, id}, scenario})
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
  def handle_cast({:delete, trader_id, id}, state) do
    :ets.delete(state.table, {trader_id, id})
    {:noreply, state}
  end
end
