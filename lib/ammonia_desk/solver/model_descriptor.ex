defmodule AmmoniaDesk.Solver.ModelDescriptor do
  @moduledoc """
  Encodes a product group's frame definition into the binary model descriptor
  expected by the generic Zig LP solver.

  The model descriptor is sent with every solve request. It describes the
  LP topology (routes, constraints, perturbation specs) so the solver can
  build and solve the LP without any hardcoded product knowledge.

  ## Binary Format

      Header:
        n_vars::little-16, n_routes::8, n_constraints::8, obj_mode::8,
        lambda::float-little-64, profit_floor::float-little-64

      Routes (R times):
        sell_var_idx::8, buy_var_idx::8, freight_var_idx::8,
        transit_cost_per_day::float-little-64,
        base_transit_days::float-little-64,
        unit_capacity::float-little-64

      Constraints (C times):
        ctype::8, bound_var_idx::8, bound_min_var_idx::8,
        outage_var_idx::8, outage_factor::float-little-64,
        n_routes::8, route_indices::binary,
        [coefficients::binary if CT_CUSTOM]

      Perturbations (V times):
        stddev::float-little-64, lo::float-little-64, hi::float-little-64,
        n_corr::8, [var_idx::8 + coefficient::float-little-64 per correlation]
  """

  alias AmmoniaDesk.ProductGroup

  # Constraint type codes (must match solver.zig)
  @ct_supply  0
  @ct_demand  1
  @ct_fleet   2
  @ct_capital 3
  @ct_custom  4

  # Objective mode codes (must match solver.zig)
  @obj_max_profit    0
  @obj_min_cost      1
  @obj_max_roi       2
  @obj_cvar_adjusted 3
  @obj_min_risk      4

  # Sentinel for "no variable"
  @no_var 0xFF

  @doc """
  Encode a product group's frame into a binary model descriptor.

  ## Options
    * `:objective` - objective mode atom (default `:max_profit`)
    * `:lambda` - risk aversion parameter for CVaR modes (default 0.0)
    * `:profit_floor` - minimum profit for min_risk mode (default 0.0)
  """
  @spec encode(atom(), keyword()) :: binary()
  def encode(product_group, opts \\ []) do
    frame = ProductGroup.frame(product_group)
    variables = frame.variables
    routes = frame.routes
    constraints = frame.constraints

    # Build index maps: variable key → position, route key → position
    var_keys = Enum.map(variables, & &1.key)
    var_index = Map.new(Enum.with_index(var_keys))
    route_keys = Enum.map(routes, & &1.key)
    route_index = Map.new(Enum.with_index(route_keys))

    n_vars = length(variables)
    n_routes = length(routes)
    n_constraints = length(constraints)
    obj_mode = encode_objective(Keyword.get(opts, :objective, :max_profit))
    lambda = Keyword.get(opts, :lambda, 0.0) / 1.0
    profit_floor = Keyword.get(opts, :profit_floor, 0.0) / 1.0

    header = <<
      n_vars::little-16,
      n_routes::8,
      n_constraints::8,
      obj_mode::8,
      lambda::float-little-64,
      profit_floor::float-little-64
    >>

    routes_bin = encode_routes(routes, var_index)
    constraints_bin = encode_constraints(constraints, var_index, route_index, route_keys)
    perturbations_bin = encode_perturbations(variables, var_index)

    header <> routes_bin <> constraints_bin <> perturbations_bin
  end

  @doc """
  Return the variable index map for a product group.
  Useful for tests and debugging.
  """
  @spec variable_index(atom()) :: %{atom() => non_neg_integer()}
  def variable_index(product_group) do
    ProductGroup.variable_keys(product_group)
    |> Enum.with_index()
    |> Map.new()
  end

  # ── Routes ──────────────────────────────────────────────────

  defp encode_routes(routes, var_index) do
    routes
    |> Enum.map(fn route ->
      sell_idx = var_idx(var_index, route[:sell_variable])
      buy_idx = var_idx(var_index, route[:buy_variable])
      freight_idx = var_idx(var_index, route[:freight_variable])
      transit_cost = (route[:transit_cost_per_day] || 0.0) / 1.0
      transit_days = (route[:typical_transit_days] || 0.0) / 1.0
      unit_cap = (route[:unit_capacity] || 1500.0) / 1.0

      <<
        sell_idx::8,
        buy_idx::8,
        freight_idx::8,
        transit_cost::float-little-64,
        transit_days::float-little-64,
        unit_cap::float-little-64
      >>
    end)
    |> IO.iodata_to_binary()
  end

  # ── Constraints ─────────────────────────────────────────────

  defp encode_constraints(constraints, var_index, route_index, all_route_keys) do
    constraints
    |> Enum.map(fn con ->
      ctype = encode_constraint_type(con.type)
      bound_idx = var_idx(var_index, con[:bound_variable])
      bound_min_idx = var_idx(var_index, con[:bound_min_variable])
      outage_idx = var_idx(var_index, con[:outage_variable])
      outage_factor = (con[:outage_factor] || 0.5) / 1.0

      # Which routes does this constraint cover?
      con_route_keys = con[:routes] || all_route_keys
      n_con_routes = length(con_route_keys)

      route_idx_bytes =
        con_route_keys
        |> Enum.map(fn rk -> <<Map.get(route_index, rk, 0)::8>> end)
        |> IO.iodata_to_binary()

      # Custom constraints carry explicit coefficients
      custom_coeffs =
        if ctype == @ct_custom do
          (con[:coefficients] || [])
          |> Enum.map(fn c -> <<(c / 1.0)::float-little-64>> end)
          |> IO.iodata_to_binary()
        else
          <<>>
        end

      <<
        ctype::8,
        bound_idx::8,
        bound_min_idx::8,
        outage_idx::8,
        outage_factor::float-little-64,
        n_con_routes::8,
        route_idx_bytes::binary,
        custom_coeffs::binary
      >>
    end)
    |> IO.iodata_to_binary()
  end

  # ── Perturbations ───────────────────────────────────────────

  defp encode_perturbations(variables, var_index) do
    variables
    |> Enum.map(fn var_def ->
      pert = var_def[:perturbation] || %{}

      if var_def.type == :boolean do
        # Boolean: stddev=0, lo=flip_probability, hi=0, no correlations
        flip_prob = (pert[:flip_prob] || 0.0) / 1.0
        <<0.0::float-little-64, flip_prob::float-little-64, 0.0::float-little-64, 0::8>>
      else
        stddev = (pert[:stddev] || 0.0) / 1.0
        lo = (pert[:min] || var_def.min) / 1.0
        hi = (pert[:max] || var_def.max) / 1.0
        correlations = pert[:correlations] || []
        n_corr = length(correlations)

        corr_bin =
          correlations
          |> Enum.map(fn {var_key, coeff} ->
            idx = var_idx(var_index, var_key)
            <<idx::8, (coeff / 1.0)::float-little-64>>
          end)
          |> IO.iodata_to_binary()

        <<
          stddev::float-little-64,
          lo::float-little-64,
          hi::float-little-64,
          n_corr::8,
          corr_bin::binary
        >>
      end
    end)
    |> IO.iodata_to_binary()
  end

  # ── Helpers ─────────────────────────────────────────────────

  defp var_idx(_index, nil), do: @no_var
  defp var_idx(index, key), do: Map.get(index, key, @no_var)

  defp encode_objective(:max_profit), do: @obj_max_profit
  defp encode_objective(:min_cost), do: @obj_min_cost
  defp encode_objective(:max_roi), do: @obj_max_roi
  defp encode_objective(:cvar_adjusted), do: @obj_cvar_adjusted
  defp encode_objective(:min_risk), do: @obj_min_risk
  defp encode_objective(_), do: @obj_max_profit

  defp encode_constraint_type(:supply), do: @ct_supply
  defp encode_constraint_type(:demand_cap), do: @ct_demand
  defp encode_constraint_type(:fleet_constraint), do: @ct_fleet
  defp encode_constraint_type(:capital_constraint), do: @ct_capital
  defp encode_constraint_type(:custom), do: @ct_custom
  defp encode_constraint_type(_), do: @ct_supply
end
