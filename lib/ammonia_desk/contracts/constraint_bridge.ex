defmodule AmmoniaDesk.Contracts.ConstraintBridge do
  @moduledoc """
  Bridges approved contract clauses into solver variable bounds.

  Takes the active set of approved contracts for a product group and
  translates their clauses into modifications to the Variables struct
  that gets passed to the Zig solver via Port.

  Only approved, SAP-validated, non-expired contracts with loaded
  open positions are used. The Readiness gate must pass first.

  Contract clauses modify solver inputs in three ways:
    1. Tighten bounds  — min volume becomes a floor on inventory allocation
    2. Adjust prices   — contract prices override market spot prices
    3. Add penalties   — penalty costs reduce effective margins

  This module never loosens constraints — it only tightens them.
  If a contract says minimum 5,000 tons and the trader set 3,000,
  the contract wins (floor is raised to 5,000).
  """

  alias AmmoniaDesk.Contracts.{Store, Readiness, Contract}
  alias AmmoniaDesk.Variables

  require Logger

  @doc """
  Apply active contract constraints to a Variables struct.

  Returns {:ok, modified_vars, applied_clauses} if readiness passes.
  Returns {:not_ready, issues, report} if the product group isn't ready.
  """
  def apply_constraints(%Variables{} = vars, product_group) do
    case Readiness.check(product_group) do
      {:ready, _report} ->
        active = Store.get_active_set(product_group)
        {modified_vars, applied} = apply_active_contracts(vars, active)

        if length(applied) > 0 do
          Logger.info(
            "Applied #{length(applied)} contract constraint(s) for #{product_group}"
          )
        end

        {:ok, modified_vars, applied}

      {:not_ready, issues, report} ->
        {:not_ready, issues, report}
    end
  end

  @doc """
  Same as apply_constraints/2 but does not enforce readiness gate.
  Use only for what-if analysis, never for live trading decisions.
  """
  def apply_constraints_unchecked(%Variables{} = vars, product_group) do
    active = Store.get_active_set(product_group)
    {modified_vars, applied} = apply_active_contracts(vars, active)
    {:ok, modified_vars, applied}
  end

  @doc """
  Show what constraints would be applied without actually applying them.
  Useful for the UI to preview contract impact.
  """
  def preview_constraints(%Variables{} = vars, product_group) do
    active = Store.get_active_set(product_group)

    Enum.flat_map(active, fn contract ->
      (contract.clauses || [])
      |> Enum.filter(&applicable?/1)
      |> Enum.map(fn clause ->
        current = get_variable(vars, clause.parameter)
        proposed = compute_bound(clause, current)

        %{
          counterparty: contract.counterparty,
          clause_type: clause.type,
          parameter: clause.parameter,
          operator: clause.operator,
          clause_value: clause.value,
          current_value: current,
          proposed_value: proposed,
          would_change: current != proposed,
          penalty_exposure: clause.penalty_per_unit
        }
      end)
    end)
  end

  # --- Private: apply all active contracts ---

  defp apply_active_contracts(vars, contracts) do
    Enum.reduce(contracts, {vars, []}, fn contract, {v, applied} ->
      apply_contract(v, contract, applied)
    end)
  end

  defp apply_contract(vars, %Contract{} = contract, applied) do
    (contract.clauses || [])
    |> Enum.filter(&applicable?/1)
    |> Enum.reduce({vars, applied}, fn clause, {v, acc} ->
      case apply_clause(v, clause) do
        {:changed, new_vars} ->
          {new_vars, [%{
            counterparty: contract.counterparty,
            clause_id: clause.id,
            parameter: clause.parameter,
            original: get_variable(v, clause.parameter),
            applied: get_variable(new_vars, clause.parameter)
          } | acc]}

        :unchanged ->
          {v, acc}
      end
    end)
  end

  # --- Clause application logic ---

  defp apply_clause(vars, clause) do
    param = clause.parameter
    current = get_variable(vars, param)

    if is_nil(current) do
      :unchanged
    else
      new_value = compute_bound(clause, current)

      if new_value != current do
        {:changed, set_variable(vars, param, new_value)}
      else
        :unchanged
      end
    end
  end

  # Contract constraints only tighten, never loosen
  defp compute_bound(%{operator: :>=, value: min}, current) do
    max(current, min)
  end

  defp compute_bound(%{operator: :<=, value: max_val}, current) do
    min(current, max_val)
  end

  defp compute_bound(%{operator: :==, value: fixed}, _current) do
    fixed
  end

  defp compute_bound(%{operator: :between, value: lower, value_upper: upper}, current) do
    current |> max(lower) |> min(upper)
  end

  defp compute_bound(_clause, current), do: current

  # Only apply clauses that map to solver variables
  defp applicable?(%{parameter: nil}), do: false
  defp applicable?(%{parameter: :force_majeure}), do: false
  defp applicable?(%{parameter: :demurrage}), do: false
  defp applicable?(%{parameter: :late_delivery}), do: false
  defp applicable?(%{parameter: :volume_shortfall}), do: false
  defp applicable?(%{parameter: :delivery_window}), do: false
  defp applicable?(%{parameter: :total_volume}), do: false
  defp applicable?(%{parameter: :inventory}), do: false
  defp applicable?(%{parameter: :contract_price}), do: false
  defp applicable?(%{parameter: :freight_rate}), do: false
  defp applicable?(%{type: :condition}), do: false
  defp applicable?(_clause), do: true

  # --- Variable access helpers ---

  # Solver variables come from the product group frame config.
  # For backward compatibility, also accept the ammonia_domestic hardcoded list.
  @legacy_solver_variables [
    :river_stage, :lock_hrs, :temp_f, :wind_mph, :vis_mi, :precip_in,
    :inv_don, :inv_geis, :stl_outage, :mem_outage, :barge_count,
    :nola_buy, :sell_stl, :sell_mem, :fr_don_stl, :fr_don_mem,
    :fr_geis_stl, :fr_geis_mem, :nat_gas, :working_cap
  ]

  defp get_variable(%Variables{} = vars, param) when param in @legacy_solver_variables do
    Map.get(vars, param)
  end
  # Dynamic variable maps (any product group)
  defp get_variable(vars, param) when is_map(vars) and is_atom(param) do
    Map.get(vars, param)
  end
  defp get_variable(_, _), do: nil

  defp set_variable(%Variables{} = vars, param, value) when param in @legacy_solver_variables do
    Map.put(vars, param, value)
  end
  # Dynamic variable maps (any product group)
  defp set_variable(vars, param, value) when is_map(vars) and is_atom(param) do
    Map.put(vars, param, value)
  end
  defp set_variable(vars, _, _), do: vars
end
