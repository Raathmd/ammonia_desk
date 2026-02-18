defmodule TradingDesk.Contracts.ConstraintBridge do
  @moduledoc """
  Bridges approved contract clauses into solver variable bounds.

  Takes the active set of approved contracts for a product group and
  translates their clauses into modifications to the Variables struct
  that gets passed to the Zig solver via Port.

  Only approved, SAP-validated, non-expired contracts with loaded
  open positions are used. The Readiness gate must pass first.

  Contract clauses modify solver inputs in four ways:
    1. Tighten bounds     — min volume becomes a floor on inventory allocation
    2. Adjust prices      — contract prices override market spot prices
    3. Add penalty costs  — penalty $/ton reduces effective margin
    4. Frame constraints  — Incoterm + delivery windows shape feasible region

  The bridge produces two outputs:
    - Modified Variables struct (tightened bounds for the solver)
    - Penalty schedule (per-counterparty penalty exposure for the objective)

  This module never loosens constraints — it only tightens them.
  If a contract says minimum 5,000 tons and the trader set 3,000,
  the contract wins (floor is raised to 5,000).
  """

  alias TradingDesk.Contracts.{Store, Readiness, Contract}
  alias TradingDesk.Variables

  require Logger

  # ──────────────────────────────────────────────────────────
  # PUBLIC API
  # ──────────────────────────────────────────────────────────

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

  @doc """
  Build the penalty schedule: per-counterparty penalty exposure from
  all active contracts. The solver uses this to reduce effective margin
  on routes that risk triggering penalties.

  Returns a list of:
    %{counterparty, penalty_type, rate_per_ton, open_qty, max_exposure,
      incoterm, direction}
  """
  def penalty_schedule(product_group) do
    active = Store.get_active_set(product_group)

    Enum.flat_map(active, fn contract ->
      penalties = extract_penalty_clauses(contract)
      incoterm = extract_incoterm(contract)
      open_qty = contract.open_position || 0

      Enum.map(penalties, fn {penalty_type, rate} ->
        %{
          counterparty: contract.counterparty,
          counterparty_type: contract.counterparty_type,
          penalty_type: penalty_type,
          rate_per_ton: rate,
          open_qty: open_qty,
          max_exposure: rate * open_qty,
          incoterm: incoterm,
          direction: contract.template_type,
          family_id: contract.family_id
        }
      end)
    end)
  end

  @doc """
  Compute the aggregate open book for Trammo across all active contracts.

  Returns:
    %{
      total_purchase_obligation: float,  # MT still owed to Trammo by suppliers
      total_sale_obligation: float,      # MT Trammo still owes to customers
      net_open_position: float,          # purchase - sale (positive = long)
      by_counterparty: [%{counterparty, direction, incoterm, contract_qty,
                          open_qty, penalty_exposure}],
      total_penalty_exposure: float      # worst-case penalty across all contracts
    }
  """
  def aggregate_open_book(product_group) do
    active = Store.get_active_set(product_group)

    by_counterparty =
      Enum.map(active, fn contract ->
        incoterm = extract_incoterm(contract)
        contract_qty = extract_contract_qty(contract)
        open_qty = contract.open_position || 0
        penalties = extract_penalty_clauses(contract)
        penalty_exposure = Enum.reduce(penalties, 0.0, fn {_type, rate}, acc ->
          acc + rate * abs(open_qty)
        end)

        direction = case contract.counterparty_type do
          :supplier -> :purchase
          :customer -> :sale
          _ -> contract.template_type
        end

        %{
          counterparty: contract.counterparty,
          direction: direction,
          incoterm: incoterm,
          term_type: contract.term_type,
          contract_qty: contract_qty,
          open_qty: open_qty,
          penalty_exposure: penalty_exposure,
          family_id: contract.family_id
        }
      end)

    purchases = Enum.filter(by_counterparty, &(&1.direction == :purchase))
    sales = Enum.filter(by_counterparty, &(&1.direction == :sale))

    total_purchase = Enum.reduce(purchases, 0.0, &(&1.open_qty + &2))
    total_sale = Enum.reduce(sales, 0.0, &(&1.open_qty + &2))
    total_penalty = Enum.reduce(by_counterparty, 0.0, &(&1.penalty_exposure + &2))

    %{
      total_purchase_obligation: total_purchase,
      total_sale_obligation: total_sale,
      net_open_position: total_purchase - total_sale,
      by_counterparty: by_counterparty,
      total_penalty_exposure: total_penalty
    }
  end

  # ──────────────────────────────────────────────────────────
  # PRIVATE: apply all active contracts
  # ──────────────────────────────────────────────────────────

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
            clause_type: clause.clause_id,
            parameter: clause.parameter,
            original: get_variable(v, clause.parameter),
            applied: get_variable(new_vars, clause.parameter),
            penalty_per_unit: clause.penalty_per_unit,
            incoterm: extract_incoterm(contract)
          } | acc]}

        :unchanged ->
          {v, acc}
      end
    end)
  end

  # ──────────────────────────────────────────────────────────
  # CLAUSE APPLICATION LOGIC
  # ──────────────────────────────────────────────────────────

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

  # ──────────────────────────────────────────────────────────
  # APPLICABILITY — which clauses can modify solver variables
  # ──────────────────────────────────────────────────────────
  #
  # The solver frame has these direct variables:
  #   :nola_buy, :sell_stl, :sell_mem — prices
  #   :inv_don, :inv_geis             — inventory levels
  #   :fr_don_stl, :fr_don_mem, etc.  — freight rates
  #   :working_cap                    — working capital constraint
  #   :barge_count                    — capacity
  #
  # Clauses that map to these are directly applicable.
  # Clauses that produce penalty schedules (demurrage, shortfall,
  # late delivery) are NOT directly applied as bounds — instead they
  # feed penalty_schedule/1 which the solver reads as cost adjustments.
  # Force majeure and delivery windows are conditions, not bounds.

  defp applicable?(%{parameter: nil}), do: false
  # Penalty clauses feed penalty_schedule, not direct variable bounds
  defp applicable?(%{parameter: :demurrage}), do: false
  defp applicable?(%{parameter: :late_delivery}), do: false
  defp applicable?(%{parameter: :volume_shortfall}), do: false
  # Condition/scheduling clauses — not direct solver variables
  defp applicable?(%{parameter: :force_majeure}), do: false
  defp applicable?(%{parameter: :delivery_window}), do: false
  # Aggregate quantities — the solver uses route-level variables instead
  defp applicable?(%{parameter: :total_volume}), do: false
  defp applicable?(%{parameter: :inventory}), do: false
  # Generic references — only specific price/freight variables are applicable
  defp applicable?(%{parameter: :contract_price}), do: false
  defp applicable?(%{parameter: :freight_rate}), do: false
  defp applicable?(%{parameter: :insurance}), do: false
  # Anything typed as :condition doesn't set bounds
  defp applicable?(%{type: :condition}), do: false
  defp applicable?(_clause), do: true

  # ──────────────────────────────────────────────────────────
  # HELPERS — extract structured data from contracts
  # ──────────────────────────────────────────────────────────

  defp extract_incoterm(%Contract{incoterm: incoterm}) when not is_nil(incoterm), do: incoterm
  defp extract_incoterm(%Contract{clauses: clauses}) when is_list(clauses) do
    case Enum.find(clauses, &(&1.clause_id == "INCOTERMS")) do
      %{extracted_fields: %{incoterm_rule: rule}} when not is_nil(rule) ->
        rule |> String.downcase() |> String.to_atom()
      _ -> nil
    end
  end
  defp extract_incoterm(_), do: nil

  defp extract_contract_qty(%Contract{clauses: clauses}) when is_list(clauses) do
    case Enum.find(clauses, &(&1.clause_id == "QUANTITY_TOLERANCE")) do
      %{value: qty} when is_number(qty) -> qty
      _ -> 0.0
    end
  end
  defp extract_contract_qty(_), do: 0.0

  defp extract_penalty_clauses(%Contract{clauses: clauses}) when is_list(clauses) do
    penalties = []

    penalties =
      case Enum.find(clauses, &(&1.clause_id == "PENALTY_VOLUME_SHORTFALL")) do
        %{penalty_per_unit: rate} when is_number(rate) and rate > 0 ->
          [{:volume_shortfall, rate} | penalties]
        _ -> penalties
      end

    penalties =
      case Enum.find(clauses, &(&1.clause_id == "PENALTY_LATE_DELIVERY")) do
        %{penalty_per_unit: rate} when is_number(rate) and rate > 0 ->
          [{:late_delivery, rate} | penalties]
        _ -> penalties
      end

    penalties =
      case Enum.find(clauses, &(&1.clause_id == "LAYTIME_DEMURRAGE")) do
        %{penalty_per_unit: rate} when is_number(rate) and rate > 0 ->
          [{:demurrage, rate} | penalties]
        _ -> penalties
      end

    penalties
  end
  defp extract_penalty_clauses(_), do: []

  # ──────────────────────────────────────────────────────────
  # VARIABLE ACCESS HELPERS
  # ──────────────────────────────────────────────────────────

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
