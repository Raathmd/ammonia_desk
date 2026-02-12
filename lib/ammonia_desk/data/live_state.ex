defmodule AmmoniaDesk.Data.LiveState do
  @moduledoc """
  Holds the current live values for all 18 variables.
  Updated by the Poller, read by LiveView and AutoRunner.
  """
  use GenServer

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @doc "Get current live values as a Variables struct"
  def get do
    GenServer.call(__MODULE__, :get)
  end

  @doc "Get the timestamp of last update per source"
  def last_updated do
    GenServer.call(__MODULE__, :last_updated)
  end

  @doc "Update variables from a data source"
  def update(source, data) do
    GenServer.cast(__MODULE__, {:update, source, data})
  end

  @impl true
  def init(_) do
    state = %{
      vars: %AmmoniaDesk.Variables{
        river_stage: 14.2, lock_hrs: 20.0, temp_f: 28.0, wind_mph: 18.0,
        vis_mi: 0.5, precip_in: 1.2,
        inv_don: 12_000.0, inv_geis: 8_000.0,
        stl_outage: true, mem_outage: false, barge_count: 14.0,
        nola_buy: 320.0, sell_stl: 410.0, sell_mem: 385.0,
        fr_don_stl: 55.0, fr_don_mem: 32.0, fr_geis_stl: 58.0, fr_geis_mem: 34.0,
        nat_gas: 2.80, working_cap: 4_200_000.0
      },
      updated_at: %{}
    }
    {:ok, state}
  end

  @impl true
  def handle_call(:get, _from, state) do
    {:reply, state.vars, state}
  end

  @impl true
  def handle_call(:last_updated, _from, state) do
    {:reply, state.updated_at, state}
  end

  @impl true
  def handle_cast({:update, source, data}, state) do
    new_vars = merge_data(state.vars, data)
    new_updated = Map.put(state.updated_at, source, DateTime.utc_now())
    {:noreply, %{state | vars: new_vars, updated_at: new_updated}}
  end

  defp merge_data(vars, data) when is_map(data) do
    Enum.reduce(data, vars, fn {key, value}, acc ->
      if Map.has_key?(acc, key) and not is_nil(value) do
        Map.put(acc, key, value)
      else
        acc
      end
    end)
  end
end
