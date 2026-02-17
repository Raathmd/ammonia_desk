defmodule TradingDesk.Contracts.SapValidator do
  @moduledoc """
  Elixir-side comparison of extracted contract clauses against SAP data.

  SapClient retrieves the raw data from SAP (on-network only).
  This module does all the comparison logic locally on the BEAM.
  No data leaves the network.

  Compares extracted contract clauses against:
    - Counterparty identity
    - Contract prices vs SAP condition records
    - Volume commitments vs SAP scheduling agreements
    - Validity dates
    - Open positions (undelivered quantities)

  Organized by product group — all contracts in a product group
  can be validated in a single pass.
  """

  alias TradingDesk.Contracts.{Contract, SapClient, Store}

  require Logger

  @doc """
  Validate a single contract by fetching its SAP record and comparing.
  Returns {:ok, updated_contract} or {:error, reason}.
  """
  def validate(contract_id) do
    with {:ok, contract} <- Store.get(contract_id) do
      sap_result =
        if contract.sap_contract_id do
          SapClient.fetch_contract(contract.sap_contract_id)
        else
          SapClient.search_contract(contract.counterparty, contract.product_group)
        end

      case sap_result do
        {:ok, sap_record} ->
          discrepancies = compare(contract, sap_record)

          result = %{
            valid: no_critical_discrepancies?(discrepancies),
            sap_contract_id: sap_record[:contract_number],
            discrepancies: discrepancies,
            sap_fetched_at: sap_record[:fetched_at]
          }

          Store.update_sap_validation(contract_id, result)

        {:error, :sap_not_configured} ->
          Logger.warning("SAP not configured — manual validation required")
          result = %{
            valid: false,
            sap_contract_id: contract.sap_contract_id,
            discrepancies: [%{
              field: :sap_connection,
              severity: :medium,
              message: "SAP not configured — requires manual operations review"
            }],
            sap_fetched_at: DateTime.utc_now()
          }
          Store.update_sap_validation(contract_id, result)

        {:error, :not_found} ->
          result = %{
            valid: false,
            sap_contract_id: nil,
            discrepancies: [%{
              field: :contract,
              severity: :high,
              message: "Contract not found in SAP",
              contract_value: contract.sap_contract_id || contract.counterparty,
              sap_value: nil
            }],
            sap_fetched_at: DateTime.utc_now()
          }
          Store.update_sap_validation(contract_id, result)

        {:error, reason} ->
          {:error, {:sap_unreachable, reason}}
      end
    end
  end

  @doc """
  Validate all contracts in a product group against SAP.
  Retrieves SAP data for each counterparty and compares against
  extracted clauses. Runs concurrently on the BEAM.
  """
  def validate_product_group(product_group) do
    contracts = Store.list_by_product_group(product_group)
    to_validate = Enum.filter(contracts, &(&1.status in [:draft, :pending_review]))

    results =
      to_validate
      |> Task.async_stream(
        fn contract -> {contract.id, validate(contract.id)} end,
        max_concurrency: 4,
        timeout: 20_000
      )
      |> Enum.map(fn
        {:ok, result} -> result
        {:exit, reason} -> {:error, {:task_failed, reason}}
      end)

    succeeded = Enum.count(results, fn {_id, r} -> match?({:ok, _}, r) end)
    failed = Enum.count(results, fn {_id, r} -> not match?({:ok, _}, r) end)

    {:ok, %{
      product_group: product_group,
      total: length(to_validate),
      validated: succeeded,
      failed: failed,
      details: results
    }}
  end

  @doc """
  Refresh open positions for all counterparties in a product group
  from SAP, then update contract store.
  """
  def refresh_open_positions(product_group) do
    counterparties = Store.counterparties(product_group)
    result = SapClient.fetch_open_positions(counterparties, product_group)

    # Update each active contract with its current open position
    Enum.each(result.positions, fn {cp, pos} ->
      Store.update_open_position(cp, product_group, pos.open_quantity)
    end)

    {:ok, %{
      product_group: product_group,
      total: length(counterparties),
      succeeded: map_size(result.positions),
      failed: result.failed,
      fetched_at: result.fetched_at
    }}
  end

  # --- Comparison logic (all local Elixir) ---

  defp compare(%Contract{} = contract, sap_record) do
    []
    |> compare_counterparty(contract, sap_record)
    |> compare_prices(contract, sap_record)
    |> compare_volumes(contract, sap_record)
    |> compare_dates(contract, sap_record)
  end

  defp compare_counterparty(acc, contract, sap) do
    sap_name = sap[:vendor_name] || sap[:customer_name] || ""

    if sap_name != "" and normalize(contract.counterparty) != normalize(sap_name) do
      [%{
        field: :counterparty,
        severity: :high,
        message: "Counterparty name mismatch",
        contract_value: contract.counterparty,
        sap_value: sap_name
      } | acc]
    else
      acc
    end
  end

  defp compare_prices(acc, contract, sap) do
    contract_prices =
      (contract.clauses || [])
      |> Enum.filter(&(&1.type == :price_term))

    sap_conditions = sap[:condition_records] || []

    Enum.reduce(contract_prices, acc, fn clause, discrepancies ->
      sap_match = Enum.find(sap_conditions, fn sc -> sc[:parameter] == clause.parameter end)

      cond do
        is_nil(sap_match) ->
          [%{
            field: {:price, clause.parameter},
            severity: :medium,
            message: "Price term from contract not found in SAP conditions",
            contract_value: clause.value,
            sap_value: nil
          } | discrepancies]

        abs(clause.value - sap_match[:value]) > 0.01 ->
          [%{
            field: {:price, clause.parameter},
            severity: :high,
            message: "Price mismatch: contract=$#{clause.value}, SAP=$#{sap_match[:value]}",
            contract_value: clause.value,
            sap_value: sap_match[:value]
          } | discrepancies]

        true ->
          discrepancies
      end
    end)
  end

  defp compare_volumes(acc, contract, sap) do
    contract_obligations =
      (contract.clauses || [])
      |> Enum.filter(&(&1.type == :obligation and &1.unit == "tons"))

    sap_qty = sap[:target_quantity]

    if is_nil(sap_qty) or sap_qty == 0 do
      acc
    else
      Enum.reduce(contract_obligations, acc, fn clause, discrepancies ->
        if clause.value && abs(clause.value - sap_qty) / max(sap_qty, 1) > 0.05 do
          [%{
            field: {:volume, clause.parameter},
            severity: :high,
            message: "Volume differs >5%: contract=#{clause.value}t, SAP=#{sap_qty}t",
            contract_value: clause.value,
            sap_value: sap_qty
          } | discrepancies]
        else
          discrepancies
        end
      end)
    end
  end

  defp compare_dates(acc, contract, sap) do
    acc
    |> maybe_date(:contract_date, contract.contract_date, sap[:valid_from])
    |> maybe_date(:expiry_date, contract.expiry_date, sap[:valid_to])
  end

  defp maybe_date(acc, _field, nil, _sap), do: acc
  defp maybe_date(acc, _field, _contract, nil), do: acc
  defp maybe_date(acc, field, contract_date, sap_date) do
    if Date.compare(contract_date, sap_date) != :eq do
      [%{
        field: field,
        severity: :medium,
        message: "Date mismatch: contract=#{contract_date}, SAP=#{sap_date}",
        contract_value: contract_date,
        sap_value: sap_date
      } | acc]
    else
      acc
    end
  end

  defp no_critical_discrepancies?(discrepancies) do
    not Enum.any?(discrepancies, &(&1.severity == :high))
  end

  defp normalize(name) when is_binary(name), do: name |> String.trim() |> String.downcase()
  defp normalize(_), do: ""
end
