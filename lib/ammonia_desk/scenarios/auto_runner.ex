defmodule AmmoniaDesk.Scenarios.AutoRunner do
  @moduledoc """
  Runs Monte Carlo simulations when live data deltas exceed admin-configured thresholds.

  Key behaviors:
    - Thresholds are sourced from `DeltaConfig` (admin-configurable per product group)
    - Only re-solves when |current - baseline| > threshold for ANY variable
    - Respects cooldown interval (min_solve_interval_ms) to prevent rapid-fire
    - Every auto-solve is committed to BSV chain with full payload + trigger details
    - Maintains a baseline (last solved values) to compute deltas against
  """
  use GenServer
  require Logger

  alias AmmoniaDesk.Config.DeltaConfig
  alias AmmoniaDesk.Chain.AutoSolveCommitter

  @default_n_scenarios 1000

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  def latest, do: GenServer.call(__MODULE__, :latest)
  def run_now, do: GenServer.cast(__MODULE__, :run_now)
  def history, do: GenServer.call(__MODULE__, :history)

  @doc "Get the current baseline values (what the last solve used)."
  def baseline, do: GenServer.call(__MODULE__, :baseline)

  @impl true
  def init(_) do
    if Phoenix.PubSub.node_name(AmmoniaDesk.PubSub) do
      Phoenix.PubSub.subscribe(AmmoniaDesk.PubSub, "live_data")
      Phoenix.PubSub.subscribe(AmmoniaDesk.PubSub, "delta_config")
    end

    # First run after 5 seconds
    Process.send_after(self(), :initial_run, 5_000)

    # Scheduled fallback — uses DeltaConfig interval
    schedule_fallback()

    {:ok, %{
      latest_result: nil,
      last_center: nil,
      running: false,
      history: [],
      last_solve_at: nil
    }}
  end

  # ──────────────────────────────────────────────────────────
  # DATA UPDATE — delta check against configured thresholds
  # ──────────────────────────────────────────────────────────

  @impl true
  def handle_info({:data_updated, _source}, %{running: true} = state) do
    # Already running a solve — skip
    {:noreply, state}
  end

  @impl true
  def handle_info({:data_updated, _source}, state) do
    config = get_config()

    unless config[:enabled] do
      {:noreply, state}
    else
      current = AmmoniaDesk.Data.LiveState.get()
      thresholds = config[:thresholds] || %{}

      if state.last_center == nil or material_change?(state.last_center, current, thresholds) do
        # Check cooldown
        if cooldown_elapsed?(state.last_solve_at, config[:min_solve_interval_ms]) do
          Logger.info("AutoRunner: material delta detected, rerunning")
          {:noreply, do_run(state, config)}
        else
          Logger.debug("AutoRunner: delta detected but cooldown active, skipping")
          {:noreply, state}
        end
      else
        {:noreply, state}
      end
    end
  end

  @impl true
  def handle_info(:initial_run, state) do
    config = get_config()

    if config[:enabled] do
      {:noreply, do_run(state, config)}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(:scheduled_run, state) do
    schedule_fallback()
    config = get_config()

    if config[:enabled] do
      {:noreply, do_run(state, config)}
    else
      {:noreply, state}
    end
  end

  # Config changed — update behavior immediately
  @impl true
  def handle_info({:delta_config, _event, _payload}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_cast(:run_now, state) do
    {:noreply, do_run(state, get_config())}
  end

  @impl true
  def handle_call(:latest, _from, state) do
    {:reply, state.latest_result, state}
  end

  @impl true
  def handle_call(:history, _from, state) do
    {:reply, state.history, state}
  end

  @impl true
  def handle_call(:baseline, _from, state) do
    {:reply, state.last_center, state}
  end

  # ──────────────────────────────────────────────────────────
  # SOLVE EXECUTION
  # ──────────────────────────────────────────────────────────

  defp do_run(state, config) do
    live_vars = AmmoniaDesk.Data.LiveState.get()
    thresholds = config[:thresholds] || %{}
    n_scenarios = config[:n_scenarios] || @default_n_scenarios
    product_group = config[:product_group] || :ammonia

    # Detect which variables triggered the re-solve (with delta details)
    trigger_details = detect_trigger_details(state.last_center, live_vars, thresholds)

    # Pipeline: check contracts -> ingest changes -> monte carlo
    pipeline_result =
      AmmoniaDesk.Solver.Pipeline.monte_carlo(live_vars,
        product_group: product_group,
        n_scenarios: n_scenarios,
        caller_ref: :auto_runner,
        trigger: :auto_runner
      )

    solve_result = case pipeline_result do
      {:ok, %{result: dist} = envelope} -> {:ok, dist, envelope}
      {:error, _} = err -> err
    end

    case solve_result do
      {:ok, distribution, envelope} ->
        result = %{
          distribution: distribution,
          center: live_vars,
          timestamp: DateTime.utc_now(),
          triggers: trigger_details,
          trigger_keys: Enum.map(trigger_details, & &1.key),
          explanation: nil,
          audit_id: envelope[:audit_id]
        }

        # Commit to BSV chain — full payload with trigger details
        chain_commit_async(result, live_vars, product_group, trigger_details, envelope)

        # Broadcast result immediately
        Phoenix.PubSub.broadcast(
          AmmoniaDesk.PubSub,
          "auto_runner",
          {:auto_result, result}
        )

        # Spawn explanation
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

        new_history = [result | state.history] |> Enum.take(20)

        trigger_msg = if length(trigger_details) > 0 do
          keys = Enum.map_join(trigger_details, ", ", & &1.key)
          " (triggered by #{keys})"
        else
          " (scheduled)"
        end

        Logger.info(
          "AutoRunner: #{distribution.n_feasible}/#{distribution.n_scenarios} feasible, " <>
          "mean=$#{round(distribution.mean)}, signal=#{distribution.signal}" <> trigger_msg
        )

        %{state |
          latest_result: result,
          last_center: live_vars,
          running: false,
          history: new_history,
          last_solve_at: DateTime.utc_now()
        }

      {:error, reason} ->
        Logger.error("AutoRunner failed: #{inspect(reason)}")
        %{state | running: false}
    end
  end

  # ──────────────────────────────────────────────────────────
  # DELTA DETECTION
  # ──────────────────────────────────────────────────────────

  defp material_change?(old, new, thresholds) do
    Enum.any?(thresholds, fn {key, threshold} ->
      old_val = to_float(Map.get(old, key))
      new_val = to_float(Map.get(new, key))
      abs(new_val - old_val) >= threshold
    end)
  end

  @doc false
  def detect_trigger_details(nil, _new, _thresholds), do: []
  def detect_trigger_details(old, new, thresholds) do
    thresholds
    |> Enum.filter(fn {key, threshold} ->
      old_val = to_float(Map.get(old, key))
      new_val = to_float(Map.get(new, key))
      abs(new_val - old_val) >= threshold
    end)
    |> Enum.map(fn {key, threshold} ->
      old_val = to_float(Map.get(old, key))
      new_val = to_float(Map.get(new, key))

      %{
        key: key,
        variable_index: DeltaConfig.variable_index(key),
        baseline_value: old_val,
        current_value: new_val,
        threshold: threshold,
        delta: new_val - old_val
      }
    end)
    |> Enum.sort_by(fn t -> abs(t.delta / max(t.threshold, 0.001)) end, :desc)
  end

  defp to_float(true), do: 1.0
  defp to_float(false), do: 0.0
  defp to_float(v) when is_number(v), do: v / 1
  defp to_float(_), do: 0.0

  # ──────────────────────────────────────────────────────────
  # CHAIN COMMIT
  # ──────────────────────────────────────────────────────────

  defp chain_commit_async(result, variables, product_group, trigger_details, envelope) do
    Task.Supervisor.start_child(
      AmmoniaDesk.Contracts.TaskSupervisor,
      fn ->
        AutoSolveCommitter.commit(
          result: result,
          variables: variables,
          product_group: product_group,
          trigger_details: trigger_details,
          audit_id: envelope[:audit_id],
          distribution: result.distribution
        )
      end
    )
  end

  # ──────────────────────────────────────────────────────────
  # HELPERS
  # ──────────────────────────────────────────────────────────

  defp get_config do
    try do
      DeltaConfig.get(:ammonia)
    rescue
      _ -> %{enabled: true, thresholds: default_thresholds(), n_scenarios: 1000,
             min_solve_interval_ms: :timer.minutes(5), product_group: :ammonia}
    end
  end

  defp cooldown_elapsed?(nil, _interval), do: true
  defp cooldown_elapsed?(last_solve_at, interval) do
    elapsed = DateTime.diff(DateTime.utc_now(), last_solve_at, :millisecond)
    elapsed >= (interval || :timer.minutes(5))
  end

  defp schedule_fallback do
    interval = try do
      config = DeltaConfig.get(:ammonia)
      config[:min_solve_interval_ms] || :timer.minutes(60)
    rescue
      _ -> :timer.minutes(60)
    end

    # Scheduled fallback at 12x the cooldown interval (or 60 min)
    Process.send_after(self(), :scheduled_run, max(interval * 12, :timer.minutes(60)))
  end

  defp default_thresholds do
    %{
      river_stage: 0.5, lock_hrs: 2.0, temp_f: 5.0, wind_mph: 3.0,
      vis_mi: 1.0, precip_in: 0.5, inv_don: 500.0, inv_geis: 500.0,
      stl_outage: 0.5, mem_outage: 0.5, barge_count: 1.0,
      nola_buy: 2.0, sell_stl: 2.0, sell_mem: 2.0,
      fr_don_stl: 1.0, fr_don_mem: 1.0, fr_geis_stl: 1.0, fr_geis_mem: 1.0,
      nat_gas: 0.10, working_cap: 100_000.0
    }
  end
end
