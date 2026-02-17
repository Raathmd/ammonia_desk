defmodule TradingDesk.Solver.Port do
  @moduledoc """
  Manages the generic Zig LP solver via an Erlang Port.

  ## Protocol (v2 — model descriptor driven)

  All product groups share a single `solver` binary. The LP topology is
  sent as a binary model descriptor with each request.

    Request:  <<cmd::8, payload::binary>>
      cmd 1 = single solve:   model_descriptor + variables (N f64s)
      cmd 2 = monte carlo:    n_scenarios::little-32 + model_descriptor + variables

    Response (single solve):
      <<status::8, n_routes::8, n_constraints::8,
        profit::f64, tons::f64, cost::f64, roi::f64,
        route_tons[R]::f64, route_profits[R]::f64, margins[R]::f64,
        shadow[C]::f64>>

    Response (monte carlo):
      <<status::8, n_vars::little-16,
        n_scenarios::little-32, n_feasible::little-32, n_infeasible::little-32,
        mean::f64, stddev::f64, p5::f64, p25::f64, p50::f64, p75::f64, p95::f64,
        min::f64, max::f64,
        sensitivity[V]::f64>>
  """
  use GenServer
  require Logger

  alias TradingDesk.ProductGroup
  alias TradingDesk.Solver.ModelDescriptor

  # Result struct from a single solve
  defmodule Result do
    defstruct [
      :status,        # :optimal | :infeasible | :error
      :profit,        # total gross profit
      :tons,          # total tons shipped
      :barges,        # total barges used (or vessels)
      :cost,          # total capital deployed
      :roi,           # return on capital %
      :product_group, # which product group this result is for
      route_tons: [],
      route_profits: [],
      margins: [],
      transits: [],
      shadow_prices: [],
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
      :product_group,
      sensitivity: [] # list of {variable_key, correlation} tuples, sorted by abs correlation
    ]
  end

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @doc """
  Solve a single scenario.

  Accepts:
    - `%Variables{}` struct (backward compat → ammonia_domestic)
    - `{product_group, variable_map}` — called as solve(pg, vars)
  """
  def solve(%TradingDesk.Variables{} = vars) do
    GenServer.call(__MODULE__, {:solve, :ammonia_domestic, vars}, 5_000)
  end

  def solve(product_group, vars) when is_atom(product_group) and is_map(vars) do
    GenServer.call(__MODULE__, {:solve, product_group, vars}, 5_000)
  end

  @doc """
  Solve with explicit objective mode.
  """
  def solve(product_group, vars, opts)
      when is_atom(product_group) and is_map(vars) and is_list(opts) do
    GenServer.call(__MODULE__, {:solve, product_group, vars, opts}, 5_000)
  end

  @doc """
  Run Monte Carlo around a center point.

  Accepts:
    - `(%Variables{}, n)` (backward compat → ammonia_domestic)
    - `(product_group, variable_map, n)` for any product group
  """
  def monte_carlo(%TradingDesk.Variables{} = center, n_scenarios \\ 1000) do
    GenServer.call(__MODULE__, {:monte_carlo, :ammonia_domestic, center, n_scenarios, []}, 30_000)
  end

  def monte_carlo(product_group, center, n_scenarios)
      when is_atom(product_group) and is_map(center) do
    GenServer.call(__MODULE__, {:monte_carlo, product_group, center, n_scenarios, []}, 30_000)
  end

  def monte_carlo(product_group, center, n_scenarios, opts)
      when is_atom(product_group) and is_map(center) and is_list(opts) do
    GenServer.call(__MODULE__, {:monte_carlo, product_group, center, n_scenarios, opts}, 30_000)
  end

  # --- GenServer callbacks ---

  @impl true
  def init(_) do
    port = start_solver()
    {:ok, %{port: port}}
  end

  @impl true
  def handle_call({:solve, product_group, vars}, from, state) do
    handle_call({:solve, product_group, vars, []}, from, state)
  end

  @impl true
  def handle_call({:solve, product_group, vars, opts}, _from, state) do
    state = ensure_solver(state)

    case state.port do
      nil ->
        {:reply, {:error, :solver_not_available}, state}

      port ->
        model_bin = ModelDescriptor.encode(product_group, opts)
        vars_bin = encode_variables(product_group, vars)
        payload = <<1::8, model_bin::binary, vars_bin::binary>>
        Port.command(port, payload)

        receive do
          {^port, {:data, response}} ->
            result = decode_solve_response(response, product_group)
            {:reply, {:ok, result}, state}
        after
          5_000 ->
            {:reply, {:error, :timeout}, state}
        end
    end
  end

  @impl true
  def handle_call({:monte_carlo, product_group, center, n, opts}, _from, state) do
    state = ensure_solver(state)

    case state.port do
      nil ->
        {:reply, {:error, :solver_not_available}, state}

      port ->
        model_bin = ModelDescriptor.encode(product_group, opts)
        vars_bin = encode_variables(product_group, center)
        payload = <<2::8, n::little-32, model_bin::binary, vars_bin::binary>>
        Port.command(port, payload)

        receive do
          {^port, {:data, response}} ->
            dist = decode_monte_carlo_response(response, product_group)
            {:reply, {:ok, dist}, state}
        after
          30_000 ->
            {:reply, {:error, :timeout}, state}
        end
    end
  end

  @impl true
  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    Logger.error("Solver exited with code #{code}, will restart on next request")
    {:noreply, %{state | port: nil}}
  end

  def handle_info({_port, {:exit_status, _code}}, state) do
    # Stale port exit
    {:noreply, state}
  end

  # --- Variable encoding ---

  defp encode_variables(:ammonia_domestic, %TradingDesk.Variables{} = vars) do
    # Backward compat: encode old Variables struct, then pad with defaults for new vars
    old_bin = TradingDesk.Variables.to_binary(vars)
    # New variables (demand_stl, demand_mem) were added after the original 20
    # Append their defaults
    defaults = ProductGroup.default_values(:ammonia_domestic)
    new_keys = ProductGroup.variable_keys(:ammonia_domestic) |> Enum.drop(20)
    extra = Enum.map(new_keys, fn k ->
      val = Map.get(defaults, k, 0.0)
      <<(val / 1.0)::float-little-64>>
    end) |> IO.iodata_to_binary()
    old_bin <> extra
  end

  defp encode_variables(product_group, vars) when is_map(vars) do
    TradingDesk.VariablesDynamic.to_binary(vars, product_group)
  end

  # --- Solver management ---

  defp ensure_solver(%{port: nil} = state) do
    %{state | port: start_solver()}
  end

  defp ensure_solver(state), do: state

  defp start_solver do
    solver = Path.join([File.cwd!(), "native", "solver"])

    if File.exists?(solver) do
      Port.open({:spawn_executable, solver}, [
        :binary,
        :exit_status,
        {:packet, 4}
      ])
    else
      Logger.warning("Solver binary not found at #{solver}")
      nil
    end
  end

  # --- Response decoders ---

  # v2 response: <<status::8, n_routes::8, n_constraints::8, profit, tons, cost, roi, ...>>
  defp decode_solve_response(<<0::8, n_routes::8, n_constraints::8, rest::binary>>, product_group) do
    {profit, rest} = decode_f64(rest)
    {tons, rest} = decode_f64(rest)
    {cost, rest} = decode_f64(rest)
    {roi, rest} = decode_f64(rest)

    {route_tons, rest} = decode_f64_array(rest, n_routes)
    {route_profits, rest} = decode_f64_array(rest, n_routes)
    {margins, rest} = decode_f64_array(rest, n_routes)
    {shadow_prices, _rest} = decode_f64_array(rest, n_constraints)

    # Compute transit times from frame for backward compat
    routes = ProductGroup.routes(product_group)
    transits = Enum.map(routes, fn r -> r[:typical_transit_days] || 0.0 end)

    # Derive barges/vessels from route_tons / unit_capacity
    barges =
      routes
      |> Enum.zip(route_tons)
      |> Enum.reduce(0.0, fn {r, tons_val}, acc ->
        cap = r[:unit_capacity] || 1500.0
        if tons_val > 0.5, do: acc + tons_val / cap, else: acc
      end)

    %Result{
      status: :optimal,
      product_group: product_group,
      profit: profit,
      tons: tons,
      barges: Float.ceil(barges, 1),
      cost: cost,
      roi: roi,
      eff_barge: if(barges > 0, do: profit / barges, else: 0.0),
      route_tons: route_tons,
      route_profits: route_profits,
      margins: margins,
      transits: transits,
      shadow_prices: shadow_prices
    }
  end

  defp decode_solve_response(<<1::8, _::binary>>, product_group) do
    %Result{status: :infeasible, product_group: product_group}
  end

  defp decode_solve_response(_, product_group) do
    %Result{status: :error, product_group: product_group}
  end

  # v2 MC response: <<0, n_vars::16, n_scenarios::32, n_feasible::32, n_infeasible::32, stats..., sensitivity[V]>>
  defp decode_monte_carlo_response(<<0::8, rest::binary>>, product_group) do
    var_keys = ProductGroup.variable_keys(product_group)
    thresholds = ProductGroup.signal_thresholds(product_group)

    <<
      n_vars::little-16,
      n_scenarios::little-32,
      n_feasible::little-32,
      n_infeasible::little-32,
      stats_rest::binary
    >> = rest

    {mean, stats_rest} = decode_f64(stats_rest)
    {stddev, stats_rest} = decode_f64(stats_rest)
    {p5, stats_rest} = decode_f64(stats_rest)
    {p25, stats_rest} = decode_f64(stats_rest)
    {p50, stats_rest} = decode_f64(stats_rest)
    {p75, stats_rest} = decode_f64(stats_rest)
    {p95, stats_rest} = decode_f64(stats_rest)
    {min_v, stats_rest} = decode_f64(stats_rest)
    {max_v, stats_rest} = decode_f64(stats_rest)

    # Read sensitivity values (one per variable)
    {sens_values, _rest} = decode_f64_array(stats_rest, n_vars)

    # Pad if solver returned fewer than we have keys
    sens_values = sens_values ++ List.duplicate(0.0, max(0, length(var_keys) - length(sens_values)))

    signal = classify_signal(p5, p25, p50, thresholds)

    sensitivity =
      Enum.zip(var_keys, sens_values)
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
      sensitivity: sensitivity,
      product_group: product_group
    }
  end

  defp decode_monte_carlo_response(_, product_group) do
    %Distribution{
      n_scenarios: 0, n_feasible: 0, n_infeasible: 0,
      mean: 0, stddev: 0, p5: 0, p25: 0, p50: 0,
      p75: 0, p95: 0, min: 0, max: 0, signal: :error,
      product_group: product_group
    }
  end

  defp classify_signal(p5, p25, p50, thresholds) do
    cond do
      p5 > (thresholds[:strong_go] || 50_000) -> :strong_go
      p25 > (thresholds[:go] || 50_000) -> :go
      p50 > (thresholds[:cautious] || 0) -> :cautious
      p50 > (thresholds[:weak] || 0) -> :weak
      true -> :no_go
    end
  end

  # --- Binary helpers ---

  defp decode_f64(<<val::float-little-64, rest::binary>>), do: {val, rest}
  defp decode_f64(<<>>), do: {0.0, <<>>}
  defp decode_f64(bin) when byte_size(bin) < 8, do: {0.0, <<>>}

  defp decode_f64_array(bin, count) do
    Enum.reduce(1..max(count, 1), {[], bin}, fn _, {acc, rest} ->
      if byte_size(rest) >= 8 do
        {val, rest2} = decode_f64(rest)
        {acc ++ [val], rest2}
      else
        {acc ++ [0.0], rest}
      end
    end)
  end
end
