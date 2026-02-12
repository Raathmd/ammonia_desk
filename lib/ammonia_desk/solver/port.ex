defmodule AmmoniaDesk.Solver.Port do
  @moduledoc """
  Manages the Zig solver binary via an Erlang Port.
  
  Protocol:
    Request:  <<cmd::8, payload::binary>>
      cmd 1 = single solve (20 f64s in, result out)
      cmd 2 = monte carlo (20 f64s center + n_scenarios::32, distribution out)
  
    Response: <<status::8, payload::binary>>
      status 0 = ok
      status 1 = infeasible
      status 2 = error
  """
  use GenServer
  require Logger

  # Result struct from a single solve
  defmodule Result do
    defstruct [
      :status,        # :optimal | :infeasible | :error
      :profit,        # total gross profit
      :tons,          # total tons shipped
      :barges,        # total barges used
      :cost,          # total capital deployed
      :roi,           # return on capital %
      route_tons: [0.0, 0.0, 0.0, 0.0],
      route_profits: [0.0, 0.0, 0.0, 0.0],
      margins: [0.0, 0.0, 0.0, 0.0],
      transits: [0.0, 0.0, 0.0, 0.0],
      shadow_prices: [0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
      eff_barge: 0.0
    ]
  end

  # Monte Carlo distribution result
  defmodule Distribution do
    defstruct [
      :n_scenarios,
      :n_feasible,
      :n_infeasible,
      :mean,
      :stddev,
      :p5,
      :p25,
      :p50,
      :p75,
      :p95,
      :min,
      :max,
      :signal,        # :strong_go | :go | :cautious | :weak | :no_go
      sensitivity: [] # list of {variable_key, correlation} tuples, sorted by abs correlation
    ]
  end

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @doc "Solve a single scenario — returns Result"
  def solve(%AmmoniaDesk.Variables{} = vars) do
    GenServer.call(__MODULE__, {:solve, vars}, 5_000)
  end

  @doc "Run Monte Carlo around a center point — returns Distribution"
  def monte_carlo(%AmmoniaDesk.Variables{} = center, n_scenarios \\ 1000) do
    GenServer.call(__MODULE__, {:monte_carlo, center, n_scenarios}, 30_000)
  end

  # --- GenServer callbacks ---

  @impl true
  def init(_) do
    solver = Path.join([File.cwd!(), "native", "solver"])

    unless File.exists?(solver) do
      Logger.warning("Solver binary not found at #{solver}, attempting build...")
      System.cmd("zig", ["build-exe", "solver.zig", "-lc"],
        cd: Path.join(File.cwd!(), "native"))
    end

    port = Port.open({:spawn_executable, solver}, [
      :binary,
      :exit_status,
      {:packet, 4}
    ])

    {:ok, %{port: port}}
  end

  @impl true
  def handle_call({:solve, vars}, _from, %{port: port} = state) do
    payload = <<1::8, AmmoniaDesk.Variables.to_binary(vars)::binary>>
    Port.command(port, payload)

    receive do
      {^port, {:data, response}} ->
        result = decode_solve_response(response)
        {:reply, {:ok, result}, state}
    after
      5_000 ->
        {:reply, {:error, :timeout}, state}
    end
  end

  @impl true
  def handle_call({:monte_carlo, center, n}, _from, %{port: port} = state) do
    payload = <<2::8, n::little-32, AmmoniaDesk.Variables.to_binary(center)::binary>>
    Port.command(port, payload)

    receive do
      {^port, {:data, response}} ->
        dist = decode_monte_carlo_response(response)
        {:reply, {:ok, dist}, state}
    after
      30_000 ->
        {:reply, {:error, :timeout}, state}
    end
  end

  @impl true
  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    Logger.error("Solver exited with code #{code}, restarting...")
    {:stop, :solver_crashed, state}
  end

  # --- Response decoders ---

  defp decode_solve_response(<<0::8, payload::binary>>) do
    <<
      profit::float-little-64,
      tons::float-little-64,
      barges::float-little-64,
      cost::float-little-64,
      eff_barge::float-little-64,
      rt0::float-little-64, rt1::float-little-64, rt2::float-little-64, rt3::float-little-64,
      rp0::float-little-64, rp1::float-little-64, rp2::float-little-64, rp3::float-little-64,
      mg0::float-little-64, mg1::float-little-64, mg2::float-little-64, mg3::float-little-64,
      tr0::float-little-64, tr1::float-little-64, tr2::float-little-64, tr3::float-little-64,
      sp0::float-little-64, sp1::float-little-64, sp2::float-little-64, sp3::float-little-64,
      sp4::float-little-64, sp5::float-little-64
    >> = payload

    roi = if cost > 0, do: profit / cost * 100, else: 0.0

    %Result{
      status: :optimal,
      profit: profit,
      tons: tons,
      barges: barges,
      cost: cost,
      roi: roi,
      eff_barge: eff_barge,
      route_tons: [rt0, rt1, rt2, rt3],
      route_profits: [rp0, rp1, rp2, rp3],
      margins: [mg0, mg1, mg2, mg3],
      transits: [tr0, tr1, tr2, tr3],
      shadow_prices: [sp0, sp1, sp2, sp3, sp4, sp5]
    }
  end

  defp decode_solve_response(<<1::8, _::binary>>) do
    %Result{status: :infeasible}
  end

  defp decode_solve_response(_) do
    %Result{status: :error}
  end

  defp decode_monte_carlo_response(<<0::8, payload::binary>>) do
    <<
      n_scenarios::little-32,
      n_feasible::little-32,
      n_infeasible::little-32,
      mean::float-little-64,
      stddev::float-little-64,
      p5::float-little-64,
      p25::float-little-64,
      p50::float-little-64,
      p75::float-little-64,
      p95::float-little-64,
      min_v::float-little-64,
      max_v::float-little-64,
      _padding::float-little-64,
      # 20 sensitivity values (Pearson correlations)
      s01::float-little-64,
      s02::float-little-64,
      s03::float-little-64,
      s04::float-little-64,
      s05::float-little-64,
      s06::float-little-64,
      s07::float-little-64,
      s08::float-little-64,
      s09::float-little-64,
      s10::float-little-64,
      s11::float-little-64,
      s12::float-little-64,
      s13::float-little-64,
      s14::float-little-64,
      s15::float-little-64,
      s16::float-little-64,
      s17::float-little-64,
      s18::float-little-64,
      s19::float-little-64,
      s20::float-little-64,
      _rest::binary
    >> = payload

    signal = cond do
      p5 > 50_000 -> :strong_go
      p25 > 50_000 -> :go
      p50 > 50_000 -> :cautious
      p50 > 0 -> :weak
      true -> :no_go
    end

    # Map sensitivity values to variable keys (same order as Input struct in Zig)
    # Return as list of {key, correlation} tuples, sorted by absolute value, top 6
    variable_keys = [
      :river_stage, :lock_hrs, :temp_f, :wind_mph, :vis_mi, :precip_in,
      :inv_don, :inv_geis, :stl_outage, :mem_outage, :barge_count,
      :nola_buy, :sell_stl, :sell_mem, :fr_don_stl, :fr_don_mem,
      :fr_geis_stl, :fr_geis_mem, :nat_gas, :working_cap
    ]

    sens_values = [
      s01, s02, s03, s04, s05, s06, s07, s08, s09, s10,
      s11, s12, s13, s14, s15, s16, s17, s18, s19, s20
    ]

    sensitivity =
      Enum.zip(variable_keys, sens_values)
      |> Enum.sort_by(fn {_k, v} -> abs(v) end, :desc)
      |> Enum.take(6)

    %Distribution{
      n_scenarios: n_scenarios,
      n_feasible: n_feasible,
      n_infeasible: n_infeasible,
      mean: mean,
      stddev: stddev,
      p5: p5,
      p25: p25,
      p50: p50,
      p75: p75,
      p95: p95,
      min: min_v,
      max: max_v,
      signal: signal,
      sensitivity: sensitivity
    }
  end

  defp decode_monte_carlo_response(_) do
    %Distribution{
      n_scenarios: 0, n_feasible: 0, n_infeasible: 0,
      mean: 0, stddev: 0, p5: 0, p25: 0, p50: 0,
      p75: 0, p95: 0, min: 0, max: 0, signal: :error
    }
  end
end
