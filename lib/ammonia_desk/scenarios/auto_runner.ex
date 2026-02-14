defmodule AmmoniaDesk.Scenarios.AutoRunner do
  @moduledoc """
  Runs Monte Carlo simulations when live data changes materially.
  Only reruns when variable deltas exceed configured thresholds.
  """
  use GenServer
  require Logger

  # Minimum change thresholds to trigger a rerun
  @thresholds %{
    river_stage: 1.0,     # ft
    lock_hrs: 2.0,        # hrs
    temp_f: 3.0,          # °F
    wind_mph: 3.0,        # mph
    vis_mi: 1.0,          # mi
    precip_in: 0.3,       # in
    inv_don: 500.0,       # tons
    inv_geis: 500.0,      # tons
    stl_outage: 0.5,      # boolean flip
    mem_outage: 0.5,      # boolean flip
    barge_count: 1.0,     # barges
    nola_buy: 5.0,        # $/ton
    sell_stl: 5.0,        # $/ton
    sell_mem: 5.0,        # $/ton
    fr_don_stl: 3.0,      # $/ton
    fr_don_mem: 2.0,      # $/ton
    fr_geis_stl: 3.0,     # $/ton
    fr_geis_mem: 2.0,     # $/ton
    nat_gas: 0.15,        # $/MMBtu
    working_cap: 100_000  # $
  }

  @default_n_scenarios 1000
  @max_interval :timer.minutes(60)

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  def latest, do: GenServer.call(__MODULE__, :latest)
  def run_now, do: GenServer.cast(__MODULE__, :run_now)

  def history, do: GenServer.call(__MODULE__, :history)

  @impl true
  def init(_) do
    if Phoenix.PubSub.node_name(AmmoniaDesk.PubSub) do
      Phoenix.PubSub.subscribe(AmmoniaDesk.PubSub, "live_data")
    end

    # First run after 5 seconds
    Process.send_after(self(), :run, 5_000)

    # Max interval fallback
    Process.send_after(self(), :scheduled_run, @max_interval)

    {:ok, %{
      n_scenarios: @default_n_scenarios,
      latest_result: nil,
      last_center: nil,
      running: false,
      history: []
    }}
  end

  # Live data changed — check if delta is material
  @impl true
  def handle_info({:data_updated, _source}, state) do
    current = AmmoniaDesk.Data.LiveState.get()

    if state.last_center == nil or material_change?(state.last_center, current) do
      Logger.info("AutoRunner: material delta detected, rerunning")
      {:noreply, do_run(state)}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(:run, state) do
    {:noreply, do_run(state)}
  end

  @impl true
  def handle_info(:scheduled_run, state) do
    # Periodic fallback even if no deltas
    Process.send_after(self(), :scheduled_run, @max_interval)
    {:noreply, do_run(state)}
  end

  @impl true
  def handle_cast(:run_now, state) do
    {:noreply, do_run(state)}
  end

  @impl true
  def handle_call(:latest, _from, state) do
    {:reply, state.latest_result, state}
  end

  @impl true
  def handle_call(:history, _from, state) do
    {:reply, state.history, state}
  end

  defp do_run(state) do
    live_vars = AmmoniaDesk.Data.LiveState.get()
    triggers = detect_triggers(state.last_center, live_vars)

    # Pipeline: check contracts → ingest changes → monte carlo
    pipeline_result =
      AmmoniaDesk.Solver.Pipeline.monte_carlo(live_vars,
        product_group: :ammonia,
        n_scenarios: state.n_scenarios,
        caller_ref: :auto_runner
      )

    # Unwrap pipeline envelope — the solver result is nested under :result
    solve_result = case pipeline_result do
      {:ok, %{result: dist}} -> {:ok, dist}
      {:error, _} = err -> err
    end

    case solve_result do
      {:ok, distribution} ->
        result = %{
          distribution: distribution,
          center: live_vars,
          timestamp: DateTime.utc_now(),
          triggers: triggers,
          explanation: nil  # filled async
        }

        # Broadcast result immediately (no waiting for Claude)
        Phoenix.PubSub.broadcast(
          AmmoniaDesk.PubSub,
          "auto_runner",
          {:auto_result, result}
        )

        # Spawn explanation — broadcasts update when ready
        spawn(fn ->
          case AmmoniaDesk.Analyst.explain_agent(result) do
            {:ok, text} ->
              Phoenix.PubSub.broadcast(
                AmmoniaDesk.PubSub,
                "auto_runner",
                {:auto_explanation, text}
              )
            _ -> :ok
          end
        end)

        # Add to history (keep last 20)
        new_history = [result | state.history] |> Enum.take(20)

        trigger_msg = if length(triggers) > 0 do
          " (triggered by #{Enum.map_join(triggers, ", ", & &1.key)})"
        else
          " (scheduled)"
        end

        Logger.info(
          "AutoRunner: #{distribution.n_feasible}/#{distribution.n_scenarios} feasible, " <>
          "mean=$#{round(distribution.mean)}, signal=#{distribution.signal}" <> trigger_msg
        )

        %{state | latest_result: result, last_center: live_vars, running: false, history: new_history}

      {:error, reason} ->
        Logger.error("AutoRunner failed: #{inspect(reason)}")
        %{state | running: false}
    end
  end

  defp material_change?(old, new) do
    Enum.any?(@thresholds, fn {key, threshold} ->
      old_val = to_float(Map.get(old, key))
      new_val = to_float(Map.get(new, key))
      abs(new_val - old_val) >= threshold
    end)
  end

  defp to_float(true), do: 1.0
  defp to_float(false), do: 0.0
  defp to_float(v) when is_number(v), do: v / 1
  defp to_float(_), do: 0.0

  defp detect_triggers(nil, _new), do: []
  defp detect_triggers(old, new) do
    @thresholds
    |> Enum.filter(fn {key, threshold} ->
      old_val = to_float(Map.get(old, key))
      new_val = to_float(Map.get(new, key))
      abs(new_val - old_val) >= threshold
    end)
    |> Enum.map(fn {key, _threshold} ->
      %{
        key: key,
        old: Map.get(old, key),
        new: Map.get(new, key)
      }
    end)
  end
end
