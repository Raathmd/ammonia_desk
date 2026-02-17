defmodule AmmoniaDesk.Solver.Port do
  @moduledoc """
  Manages the Zig solver binary via an Erlang Port.

  Protocol:
    Request:  <<cmd::8, payload::binary>>
      cmd 1 = single solve (N f64s in, result out)
      cmd 2 = monte carlo (N f64s center + n_scenarios::32, distribution out)

    Response: <<status::8, payload::binary>>
      status 0 = ok
      status 1 = infeasible
      status 2 = error

  ## Multi-Product Group Support

  Each product group may have its own solver binary (e.g., `solver`, `solver_sulphur`).
  The port manages one solver process per product group. For product groups without
  a dedicated solver binary, the solve/mc functions return :not_available.

  The `solve/2` and `monte_carlo/3` functions accept either:
    - A Variables struct (backward compat, assumes :ammonia_domestic)
    - A {product_group, variable_map} tuple for dynamic product groups
  """
  use GenServer
  require Logger

  alias AmmoniaDesk.ProductGroup

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
    - `{product_group, variable_map}` tuple for any product group
  """
  def solve(%AmmoniaDesk.Variables{} = vars) do
    GenServer.call(__MODULE__, {:solve, :ammonia_domestic, vars}, 5_000)
  end

  def solve(product_group, vars) when is_atom(product_group) and is_map(vars) do
    GenServer.call(__MODULE__, {:solve, product_group, vars}, 5_000)
  end

  @doc """
  Run Monte Carlo around a center point.

  Accepts:
    - `(%Variables{}, n)` (backward compat → ammonia_domestic)
    - `(product_group, variable_map, n)` for any product group
  """
  def monte_carlo(%AmmoniaDesk.Variables{} = center, n_scenarios \\ 1000) do
    GenServer.call(__MODULE__, {:monte_carlo, :ammonia_domestic, center, n_scenarios}, 30_000)
  end

  def monte_carlo(product_group, center, n_scenarios)
      when is_atom(product_group) and is_map(center) do
    GenServer.call(__MODULE__, {:monte_carlo, product_group, center, n_scenarios}, 30_000)
  end

  # --- GenServer callbacks ---

  @impl true
  def init(_) do
    # Start with the ammonia solver (backward compat)
    ports = start_solver(:ammonia_domestic)
    {:ok, %{ports: ports}}
  end

  @impl true
  def handle_call({:solve, product_group, vars}, _from, state) do
    state = ensure_solver(product_group, state)

    case Map.get(state.ports, product_group) do
      nil ->
        {:reply, {:error, :solver_not_available}, state}

      port ->
        binary_vars = encode_variables(product_group, vars)
        payload = <<1::8, binary_vars::binary>>
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
  def handle_call({:monte_carlo, product_group, center, n}, _from, state) do
    state = ensure_solver(product_group, state)

    case Map.get(state.ports, product_group) do
      nil ->
        {:reply, {:error, :solver_not_available}, state}

      port ->
        binary_vars = encode_variables(product_group, center)
        payload = <<2::8, n::little-32, binary_vars::binary>>
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
  def handle_info({port, {:exit_status, code}}, state) do
    # Find which product group this port belongs to
    pg = Enum.find_value(state.ports, fn {pg, p} -> if p == port, do: pg end)
    Logger.error("Solver for #{pg || "unknown"} exited with code #{code}, restarting...")

    if pg do
      new_ports = Map.delete(state.ports, pg)
      {:noreply, %{state | ports: new_ports}}
    else
      {:stop, :solver_crashed, state}
    end
  end

  # --- Variable encoding ---

  defp encode_variables(:ammonia_domestic, %AmmoniaDesk.Variables{} = vars) do
    AmmoniaDesk.Variables.to_binary(vars)
  end

  defp encode_variables(product_group, vars) when is_map(vars) do
    AmmoniaDesk.VariablesDynamic.to_binary(vars, product_group)
  end

  # --- Solver management ---

  defp ensure_solver(product_group, state) do
    if Map.has_key?(state.ports, product_group) do
      state
    else
      new_ports = start_solver(product_group)
      %{state | ports: Map.merge(state.ports, new_ports)}
    end
  end

  defp start_solver(product_group) do
    frame = ProductGroup.frame(product_group)
    binary_name = if frame, do: frame[:solver_binary], else: nil

    if binary_name do
      solver = Path.join([File.cwd!(), "native", binary_name])

      if File.exists?(solver) do
        port = Port.open({:spawn_executable, solver}, [
          :binary,
          :exit_status,
          {:packet, 4}
        ])
        %{product_group => port}
      else
        Logger.warning("Solver binary not found at #{solver} for #{product_group}")
        %{}
      end
    else
      %{}
    end
  end

  # --- Response decoders ---

  defp decode_solve_response(<<0::8, payload::binary>>, product_group) do
    route_count = ProductGroup.route_count(product_group)
    constraint_count = length(ProductGroup.constraints(product_group))

    # Decode: profit, tons, barges, cost, eff_barge (5 f64s)
    # Then: route_tons[R], route_profits[R], margins[R], transits[R] (4R f64s)
    # Then: shadow_prices[C] (C f64s)
    {profit, rest} = decode_f64(payload)
    {tons, rest} = decode_f64(rest)
    {barges, rest} = decode_f64(rest)
    {cost, rest} = decode_f64(rest)
    {eff_barge, rest} = decode_f64(rest)

    {route_tons, rest} = decode_f64_array(rest, route_count)
    {route_profits, rest} = decode_f64_array(rest, route_count)
    {margins, rest} = decode_f64_array(rest, route_count)
    {transits, rest} = decode_f64_array(rest, route_count)
    {shadow_prices, _rest} = decode_f64_array(rest, constraint_count)

    roi = if cost > 0, do: profit / cost * 100, else: 0.0

    %Result{
      status: :optimal,
      product_group: product_group,
      profit: profit,
      tons: tons,
      barges: barges,
      cost: cost,
      roi: roi,
      eff_barge: eff_barge,
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

  defp decode_monte_carlo_response(<<0::8, payload::binary>>, product_group) do
    var_count = ProductGroup.variable_count(product_group)
    var_keys = ProductGroup.variable_keys(product_group)
    thresholds = ProductGroup.signal_thresholds(product_group)

    <<
      n_scenarios::little-32,
      n_feasible::little-32,
      n_infeasible::little-32,
      rest::binary
    >> = payload

    {mean, rest} = decode_f64(rest)
    {stddev, rest} = decode_f64(rest)
    {p5, rest} = decode_f64(rest)
    {p25, rest} = decode_f64(rest)
    {p50, rest} = decode_f64(rest)
    {p75, rest} = decode_f64(rest)
    {p95, rest} = decode_f64(rest)
    {min_v, rest} = decode_f64(rest)
    {max_v, rest} = decode_f64(rest)
    {_padding, rest} = decode_f64(rest)

    # Read sensitivity values (one per variable, up to what's available)
    {sens_values, _rest} = decode_f64_array(rest, min(var_count, div(byte_size(rest), 8)))

    # Pad if solver returned fewer sensitivity values than we have variables
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
