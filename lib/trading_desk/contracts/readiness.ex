defmodule TradingDesk.Contracts.Readiness do
  @moduledoc """
  Product group readiness gate.

  A trader CANNOT optimize with confidence until ALL of these are true
  for the target product group:

    1. All contracts in the product group are parsed and :approved
    2. SAP validation has passed for every approved contract
    3. Open positions are loaded for every counterparty (current, not stale)
    4. External API data is fresh (USGS, NOAA, USACE, EIA, internal)
    5. No contracts have expired

  This module provides a single `ready?/1` check that returns
  either :ready or a detailed list of blocking issues.

  Currency enforcement:
    - Open positions must be refreshed within the staleness window
    - API data must be within its polling interval
    - Expired contracts block optimization
  """

  alias TradingDesk.Contracts.Store

  require Logger

  # How old can open position data be before it's stale
  @position_staleness_minutes 30

  # API source freshness thresholds (must match Poller intervals)
  @api_freshness %{
    usgs: 20,       # minutes (poller is 15min, allow 5min grace)
    noaa: 35,       # minutes (poller is 30min)
    usace: 35,      # minutes
    eia: 65,         # minutes (poller is 60min)
    internal: 10     # minutes (poller is 5min)
  }

  @type readiness_result ::
    {:ready, readiness_report()}
    | {:not_ready, [blocking_issue()], readiness_report()}

  @type readiness_report :: %{
    product_group: atom(),
    total_contracts: non_neg_integer(),
    approved: non_neg_integer(),
    pending: non_neg_integer(),
    draft: non_neg_integer(),
    rejected: non_neg_integer(),
    sap_validated: non_neg_integer(),
    positions_loaded: non_neg_integer(),
    positions_stale: non_neg_integer(),
    expired: non_neg_integer(),
    apis_fresh: [atom()],
    apis_stale: [atom()],
    checked_at: DateTime.t()
  }

  @type blocking_issue :: %{
    category: atom(),
    message: String.t(),
    details: term()
  }

  @doc """
  Check if a product group is ready for optimization.

  Returns {:ready, report} if all gates pass.
  Returns {:not_ready, issues, report} with a list of blocking issues.
  """
  @spec check(atom()) :: readiness_result()
  def check(product_group) do
    active_contracts = Store.get_active_set(product_group)
    all_contracts = Store.list_by_product_group(product_group)
    api_timestamps = TradingDesk.Data.LiveState.last_updated()
    now = DateTime.utc_now()

    report = build_report(product_group, active_contracts, all_contracts, api_timestamps, now)
    issues = collect_issues(product_group, active_contracts, all_contracts, api_timestamps, now)

    if Enum.empty?(issues) do
      Logger.info("Readiness check PASSED for #{product_group}")
      {:ready, report}
    else
      Logger.warning(
        "Readiness check FAILED for #{product_group}: " <>
        "#{length(issues)} blocking issue(s)"
      )
      {:not_ready, issues, report}
    end
  end

  @doc """
  Quick boolean check — is the product group ready?
  """
  @spec ready?(atom()) :: boolean()
  def ready?(product_group) do
    case check(product_group) do
      {:ready, _} -> true
      _ -> false
    end
  end

  # --- Issue collection ---

  defp collect_issues(product_group, active_contracts, all_contracts, api_timestamps, now) do
    []
    |> check_contracts_exist(product_group, all_contracts)
    |> check_all_approved(product_group, all_contracts, active_contracts)
    |> check_sap_validated(active_contracts)
    |> check_open_positions(active_contracts, now)
    |> check_expired(active_contracts)
    |> check_api_freshness(api_timestamps, now)
  end

  defp check_contracts_exist(issues, product_group, all_contracts) do
    if Enum.empty?(all_contracts) do
      [%{
        category: :no_contracts,
        message: "No contracts found for product group #{product_group}",
        details: nil
      } | issues]
    else
      issues
    end
  end

  defp check_all_approved(issues, _pg, all_contracts, active_contracts) do
    # Every counterparty that has a contract must have an approved one
    all_counterparties =
      all_contracts
      |> Enum.map(& &1.counterparty)
      |> Enum.uniq()

    active_counterparties =
      active_contracts
      |> Enum.map(& &1.counterparty)
      |> Enum.uniq()

    missing = all_counterparties -- active_counterparties

    pending =
      all_contracts
      |> Enum.filter(&(&1.status == :pending_review))
      |> Enum.map(& &1.counterparty)
      |> Enum.uniq()

    draft =
      all_contracts
      |> Enum.filter(&(&1.status == :draft))
      |> Enum.map(& &1.counterparty)
      |> Enum.uniq()

    issues =
      if length(missing) > 0 do
        [%{
          category: :unapproved_contracts,
          message: "#{length(missing)} counterpart(ies) without approved contracts",
          details: missing
        } | issues]
      else
        issues
      end

    issues =
      if length(pending) > 0 do
        [%{
          category: :pending_review,
          message: "#{length(pending)} contract(s) awaiting legal review",
          details: pending
        } | issues]
      else
        issues
      end

    if length(draft) > 0 do
      [%{
        category: :draft_contracts,
        message: "#{length(draft)} contract(s) still in draft",
        details: draft
      } | issues]
    else
      issues
    end
  end

  defp check_sap_validated(issues, active_contracts) do
    unvalidated =
      active_contracts
      |> Enum.reject(& &1.sap_validated)
      |> Enum.map(& &1.counterparty)

    if length(unvalidated) > 0 do
      [%{
        category: :sap_not_validated,
        message: "#{length(unvalidated)} approved contract(s) not validated against SAP",
        details: unvalidated
      } | issues]
    else
      issues
    end
  end

  defp check_open_positions(issues, active_contracts, now) do
    missing =
      active_contracts
      |> Enum.filter(fn c -> is_nil(c.open_position) end)
      |> Enum.map(& &1.counterparty)

    stale =
      active_contracts
      |> Enum.filter(fn c ->
        c.open_position != nil and
          stale?(c.updated_at, now, @position_staleness_minutes)
      end)
      |> Enum.map(& &1.counterparty)

    issues =
      if length(missing) > 0 do
        [%{
          category: :missing_positions,
          message: "#{length(missing)} counterpart(ies) without open position data",
          details: missing
        } | issues]
      else
        issues
      end

    if length(stale) > 0 do
      [%{
        category: :stale_positions,
        message: "#{length(stale)} open position(s) are stale (>#{@position_staleness_minutes}min)",
        details: stale
      } | issues]
    else
      issues
    end
  end

  defp check_expired(issues, active_contracts) do
    expired =
      active_contracts
      |> Enum.filter(&TradingDesk.Contracts.Contract.expired?/1)
      |> Enum.map(fn c -> {c.counterparty, c.expiry_date} end)

    if length(expired) > 0 do
      [%{
        category: :expired_contracts,
        message: "#{length(expired)} active contract(s) have expired",
        details: expired
      } | issues]
    else
      issues
    end
  end

  defp check_api_freshness(issues, api_timestamps, now) do
    stale_apis =
      @api_freshness
      |> Enum.filter(fn {source, max_age_min} ->
        case Map.get(api_timestamps, source) do
          nil -> true  # never polled
          ts -> stale?(ts, now, max_age_min)
        end
      end)
      |> Enum.map(fn {source, _} -> source end)

    if length(stale_apis) > 0 do
      [%{
        category: :stale_apis,
        message: "#{length(stale_apis)} API data source(s) are stale",
        details: stale_apis
      } | issues]
    else
      issues
    end
  end

  # --- Report ---

  defp build_report(product_group, active_contracts, all_contracts, api_timestamps, now) do
    %{
      product_group: product_group,
      total_contracts: length(all_contracts),
      approved: Enum.count(all_contracts, &(&1.status == :approved)),
      pending: Enum.count(all_contracts, &(&1.status == :pending_review)),
      draft: Enum.count(all_contracts, &(&1.status == :draft)),
      rejected: Enum.count(all_contracts, &(&1.status == :rejected)),
      sap_validated: Enum.count(active_contracts, & &1.sap_validated),
      positions_loaded: Enum.count(active_contracts, &(not is_nil(&1.open_position))),
      positions_stale: Enum.count(active_contracts, fn c ->
        c.open_position != nil and stale?(c.updated_at, now, @position_staleness_minutes)
      end),
      expired: Enum.count(active_contracts, &TradingDesk.Contracts.Contract.expired?/1),
      apis_fresh: fresh_apis(api_timestamps, now),
      apis_stale: stale_apis(api_timestamps, now),
      checked_at: now
    }
  end

  defp fresh_apis(api_timestamps, now) do
    @api_freshness
    |> Enum.filter(fn {source, max_age_min} ->
      case Map.get(api_timestamps, source) do
        nil -> false
        ts -> not stale?(ts, now, max_age_min)
      end
    end)
    |> Enum.map(fn {source, _} -> source end)
  end

  defp stale_apis(api_timestamps, now) do
    @api_freshness
    |> Enum.filter(fn {source, max_age_min} ->
      case Map.get(api_timestamps, source) do
        nil -> true
        ts -> stale?(ts, now, max_age_min)
      end
    end)
    |> Enum.map(fn {source, _} -> source end)
  end

  defp stale?(timestamp, now, max_age_minutes) do
    DateTime.diff(now, timestamp, :second) > max_age_minutes * 60
  end
end
