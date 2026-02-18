defmodule TradingDesk.Contracts.SapPositions do
  @moduledoc """
  SAP S/4HANA OData API client for ammonia contract positions and write-back.

  SAP is the system of record for all contract positions. Every solver run
  must have the latest open positions from SAP before executing.

  ## Read (OData GET) — Position Refresh

  Retrieves open contract positions with inbound/outbound deliveries for
  a product group. This data drives:
    - Volume obligation constraints in the solver
    - Penalty exposure calculations
    - Aggregate book position (long/short)

  OData endpoints (production):
    GET /sap/opu/odata/sap/API_CONTRACT_BALANCE/ContractBalanceSet
      ?$filter=MaterialGroup eq '{material_group}' and CompanyCode eq '1000'
      &$select=SoldToParty,ContractQuantity,OpenQuantity,DeliveredQuantity,
               UnitOfMeasure,IncotermsClassification,ContractType,
               PurchaseOrderDate,ContractValidityEndDate
      &$expand=to_Deliveries
      &$format=json

  ## Write (OData POST) — Contract & Delivery Creation

  When a trader decides to act on a solver outcome, they can push the
  action back to SAP:
    - Create a new purchase or sales contract
    - Create a delivery (inbound or outbound) under an existing contract

  OData endpoints (production):
    POST /sap/opu/odata/sap/API_SALES_CONTRACT_SRV/A_SalesContract
    POST /sap/opu/odata/sap/API_PURCHASEORDER_PROCESS_SRV/A_PurchaseOrder
    POST /sap/opu/odata/sap/API_OUTBOUND_DELIVERY_SRV/A_OutbDeliveryHeader
    POST /sap/opu/odata/sap/API_INBOUND_DELIVERY_SRV/A_InbDeliveryHeader

  Currently all calls return seeded data. When SAP connectivity is ready,
  swap the body of each function with the real OData call.
  """

  require Logger

  alias TradingDesk.Contracts.Store

  # ── OData Configuration ──────────────────────────────────

  @sap_base_url System.get_env("SAP_ODATA_BASE_URL") || "https://sap.trammo.com"
  @sap_client System.get_env("SAP_CLIENT") || "100"

  # Material group codes in SAP for each product group
  @material_groups %{
    ammonia: "AMMONIA",
    ammonia_domestic: "AMMONIA",
    ammonia_international: "AMMONIA",
    sulphur_international: "SULPHUR",
    petcoke: "PETCOKE",
    urea: "UREA",
    uan: "UAN"
  }

  # ── Seeded Positions (fallback until SAP is connected) ───

  @seed_positions %{
    "NGC Trinidad" => %{
      contract_number: "TRAMMO-LTP-2026-0101",
      sap_contract_id: "4600000101",
      total_qty_mt: 180_000,
      delivered_qty_mt: 30_000,
      open_qty_mt: 150_000,
      direction: :purchase,
      incoterm: :fob,
      period: :annual,
      product_group: :ammonia,
      deliveries_pending: 2,
      last_updated: ~U[2026-02-18 08:00:00Z]
    },
    "SABIC Agri-Nutrients" => %{
      contract_number: "TRAMMO-LTP-2026-0102",
      sap_contract_id: "4600000102",
      total_qty_mt: 150_000,
      delivered_qty_mt: 37_500,
      open_qty_mt: 112_500,
      direction: :purchase,
      incoterm: :fob,
      period: :annual,
      product_group: :ammonia,
      deliveries_pending: 3,
      last_updated: ~U[2026-02-18 08:00:00Z]
    },
    "Ameropa AG" => %{
      contract_number: "TRAMMO-P-2026-0103",
      sap_contract_id: "4600000103",
      total_qty_mt: 23_000,
      delivered_qty_mt: 0,
      open_qty_mt: 23_000,
      direction: :purchase,
      incoterm: :fob,
      period: :spot,
      product_group: :ammonia,
      deliveries_pending: 0,
      last_updated: ~U[2026-02-18 08:00:00Z]
    },
    "LSB Industries" => %{
      contract_number: "TRAMMO-DP-2026-0104",
      sap_contract_id: "4600000104",
      total_qty_mt: 32_000,
      delivered_qty_mt: 8_000,
      open_qty_mt: 24_000,
      direction: :purchase,
      incoterm: :fob,
      period: :annual,
      product_group: :ammonia,
      deliveries_pending: 1,
      last_updated: ~U[2026-02-18 08:00:00Z]
    },
    "Mosaic Company" => %{
      contract_number: "TRAMMO-LTS-2026-0105",
      sap_contract_id: "4600000105",
      total_qty_mt: 100_000,
      delivered_qty_mt: 25_000,
      open_qty_mt: 75_000,
      direction: :sale,
      incoterm: :cfr,
      period: :annual,
      product_group: :ammonia,
      deliveries_pending: 2,
      last_updated: ~U[2026-02-18 08:00:00Z]
    },
    "IFFCO" => %{
      contract_number: "TRAMMO-LTS-2026-0106",
      sap_contract_id: "4600000106",
      total_qty_mt: 120_000,
      delivered_qty_mt: 20_000,
      open_qty_mt: 100_000,
      direction: :sale,
      incoterm: :cfr,
      period: :annual,
      product_group: :ammonia,
      deliveries_pending: 3,
      last_updated: ~U[2026-02-18 08:00:00Z]
    },
    "OCP Group" => %{
      contract_number: "TRAMMO-S-2026-0107",
      sap_contract_id: "4600000107",
      total_qty_mt: 20_000,
      delivered_qty_mt: 0,
      open_qty_mt: 20_000,
      direction: :sale,
      incoterm: :cfr,
      period: :spot,
      product_group: :ammonia,
      deliveries_pending: 0,
      last_updated: ~U[2026-02-18 08:00:00Z]
    },
    "Nutrien StL" => %{
      contract_number: "TRAMMO-DS-2026-0108",
      sap_contract_id: "4600000108",
      total_qty_mt: 20_000,
      delivered_qty_mt: 5_000,
      open_qty_mt: 15_000,
      direction: :sale,
      incoterm: :fob,
      period: :annual,
      product_group: :ammonia,
      deliveries_pending: 1,
      last_updated: ~U[2026-02-18 08:00:00Z]
    },
    "Koch Fertilizer" => %{
      contract_number: "TRAMMO-DS-2026-0109",
      sap_contract_id: "4600000109",
      total_qty_mt: 16_000,
      delivered_qty_mt: 4_000,
      open_qty_mt: 12_000,
      direction: :sale,
      incoterm: :fob,
      period: :annual,
      product_group: :ammonia,
      deliveries_pending: 1,
      last_updated: ~U[2026-02-18 08:00:00Z]
    },
    "BASF SE" => %{
      contract_number: "TRAMMO-DAP-2026-0110",
      sap_contract_id: "4600000110",
      total_qty_mt: 15_000,
      delivered_qty_mt: 0,
      open_qty_mt: 15_000,
      direction: :sale,
      incoterm: :dap,
      period: :spot,
      product_group: :ammonia,
      deliveries_pending: 0,
      last_updated: ~U[2026-02-18 08:00:00Z]
    }
  }

  # ──────────────────────────────────────────────────────────
  # READ API — Position Refresh (OData GET)
  # ──────────────────────────────────────────────────────────

  @doc """
  Refresh open positions for a specific product group from SAP.

  Calls SAP OData API to get all open contracts with pending deliveries
  (inbound or outbound) for the given product group. Updates the Contract
  Store with latest open positions.

  In production this hits:
    GET {base_url}/sap/opu/odata/sap/API_CONTRACT_BALANCE/ContractBalanceSet
      ?$filter=MaterialGroup eq '{material_group}'
      &$expand=to_Deliveries
      &$format=json

  Returns {:ok, %{refreshed: count, positions: map}} or {:error, reason}.
  """
  def refresh_positions(product_group) do
    material_group = Map.get(@material_groups, product_group, to_string(product_group) |> String.upcase())

    Logger.info("SAP OData: refreshing positions for #{product_group} (MaterialGroup=#{material_group})")

    case odata_fetch_contract_balances(material_group, product_group) do
      {:ok, positions} ->
        # Update the Contract Store with fresh open positions
        updated_count = sync_positions_to_store(positions, product_group)

        Logger.info(
          "SAP OData: refreshed #{map_size(positions)} positions for #{product_group}, " <>
          "#{updated_count} store records updated"
        )

        {:ok, %{
          refreshed: map_size(positions),
          store_updated: updated_count,
          positions: positions,
          product_group: product_group,
          refreshed_at: DateTime.utc_now()
        }}

      {:error, reason} ->
        Logger.error("SAP OData: refresh failed for #{product_group}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Refresh open positions for ALL registered product groups.

  Calls refresh_positions/1 for each product group that has a material
  group mapping. Returns aggregate results.

  This is the on-demand full refresh — called when the trader wants
  to ensure the solver has the absolute latest from SAP across
  all product groups.
  """
  def refresh_all do
    Logger.info("SAP OData: full refresh across all product groups")

    results =
      @material_groups
      |> Map.keys()
      |> Enum.uniq_by(fn pg -> Map.get(@material_groups, pg) end)
      |> Enum.map(fn product_group ->
        {product_group, refresh_positions(product_group)}
      end)

    successes = Enum.filter(results, fn {_pg, result} -> match?({:ok, _}, result) end)
    failures = Enum.filter(results, fn {_pg, result} -> match?({:error, _}, result) end)

    total_refreshed =
      successes
      |> Enum.map(fn {_pg, {:ok, %{refreshed: n}}} -> n end)
      |> Enum.sum()

    Logger.info(
      "SAP OData: full refresh complete — #{length(successes)} product groups, " <>
      "#{total_refreshed} total positions, #{length(failures)} failures"
    )

    {:ok, %{
      product_groups: length(successes),
      total_refreshed: total_refreshed,
      failures: Enum.map(failures, fn {pg, {:error, reason}} -> {pg, reason} end),
      refreshed_at: DateTime.utc_now()
    }}
  end

  @doc """
  Fetch open positions for all ammonia contracts.

  In production, calls SAP OData API. Currently returns seeded data.
  Returns {:ok, positions_map} or {:error, reason}.
  """
  def fetch_positions do
    Logger.debug("SapPositions: returning seeded positions for 10 ammonia contracts")
    {:ok, @seed_positions}
  end

  @doc """
  Fetch open positions filtered by product group.
  """
  def fetch_positions(product_group) do
    {:ok, all} = fetch_positions()

    filtered =
      all
      |> Enum.filter(fn {_k, v} -> Map.get(v, :product_group, :ammonia) == product_group end)
      |> Map.new()

    {:ok, filtered}
  end

  @doc """
  Fetch open position for a single counterparty.
  """
  def fetch_position(counterparty) do
    case Map.get(@seed_positions, counterparty) do
      nil -> {:error, :not_found}
      pos -> {:ok, pos}
    end
  end

  @doc """
  Get the aggregate book summary from SAP positions.

  Returns:
    %{
      total_purchase_open: float,
      total_sale_open: float,
      net_position: float,       # positive = Trammo is long
      positions: map
    }
  """
  def book_summary do
    {:ok, positions} = fetch_positions()

    purchases = positions |> Enum.filter(fn {_k, v} -> v.direction == :purchase end)
    sales = positions |> Enum.filter(fn {_k, v} -> v.direction == :sale end)

    total_purchase = Enum.reduce(purchases, 0, fn {_k, v}, acc -> acc + v.open_qty_mt end)
    total_sale = Enum.reduce(sales, 0, fn {_k, v}, acc -> acc + v.open_qty_mt end)

    %{
      total_purchase_open: total_purchase,
      total_sale_open: total_sale,
      net_position: total_purchase - total_sale,
      positions: positions
    }
  end

  @doc """
  Get the aggregate book summary for a specific product group.
  """
  def book_summary(product_group) do
    {:ok, positions} = fetch_positions(product_group)

    purchases = positions |> Enum.filter(fn {_k, v} -> v.direction == :purchase end)
    sales = positions |> Enum.filter(fn {_k, v} -> v.direction == :sale end)

    total_purchase = Enum.reduce(purchases, 0, fn {_k, v}, acc -> acc + v.open_qty_mt end)
    total_sale = Enum.reduce(sales, 0, fn {_k, v}, acc -> acc + v.open_qty_mt end)

    %{
      total_purchase_open: total_purchase,
      total_sale_open: total_sale,
      net_position: total_purchase - total_sale,
      positions: positions,
      product_group: product_group
    }
  end

  # ──────────────────────────────────────────────────────────
  # WRITE API — Contract & Delivery Creation (OData POST)
  # ──────────────────────────────────────────────────────────

  @doc """
  Create a new contract in SAP based on a solver outcome.

  The trader reviews a solver result and decides to execute an action
  (e.g., "buy 10,000 MT from NGC Trinidad FOB"). This function pushes
  that decision to SAP as a new purchase or sales contract.

  In production, POSTs to:
    Purchase: POST {base_url}/sap/opu/odata/sap/API_PURCHASEORDER_PROCESS_SRV/A_PurchaseOrder
    Sale:     POST {base_url}/sap/opu/odata/sap/API_SALES_CONTRACT_SRV/A_SalesContract

  Params:
    %{
      counterparty: "NGC Trinidad",
      direction: :purchase | :sale,
      product_group: :ammonia,
      quantity_mt: 10_000,
      price_per_mt: 345.0,
      incoterm: :fob,
      delivery_point: "Point Lisas",
      validity_start: ~D[2026-03-01],
      validity_end: ~D[2026-12-31],
      notes: "Based on solver run abc123"
    }

  Returns {:ok, %{sap_contract_id: "...", status: :created}} or {:error, reason}.

  STUB — does not call SAP yet. Returns a simulated success.
  """
  def create_contract(params) do
    Logger.info(
      "SAP OData STUB: create_contract called — " <>
      "#{params[:direction]} #{params[:quantity_mt]} MT " <>
      "#{params[:product_group]} with #{params[:counterparty]}"
    )

    # TODO: Replace with real OData POST when SAP connectivity is ready
    #
    # endpoint = case params[:direction] do
    #   :purchase -> "#{@sap_base_url}/sap/opu/odata/sap/API_PURCHASEORDER_PROCESS_SRV/A_PurchaseOrder"
    #   :sale     -> "#{@sap_base_url}/sap/opu/odata/sap/API_SALES_CONTRACT_SRV/A_SalesContract"
    # end
    #
    # body = build_contract_payload(params)
    #
    # case Req.post(endpoint, json: body, headers: odata_headers()) do
    #   {:ok, %{status: 201, body: response}} ->
    #     {:ok, %{
    #       sap_contract_id: response["d"]["SalesContract"] || response["d"]["PurchaseOrder"],
    #       status: :created,
    #       created_at: DateTime.utc_now()
    #     }}
    #   {:ok, %{status: status, body: body}} ->
    #     {:error, {:sap_error, status, body}}
    #   {:error, reason} ->
    #     {:error, {:request_failed, reason}}
    # end

    {:ok, %{
      sap_contract_id: nil,
      status: :stub_not_connected,
      message: "SAP write-back not yet connected — contract would be created in SAP",
      params: params,
      requested_at: DateTime.utc_now()
    }}
  end

  @doc """
  Create a delivery (inbound or outbound) under an existing SAP contract.

  The trader decides to schedule a specific delivery against an open
  contract position. This pushes a delivery document to SAP.

  In production, POSTs to:
    Outbound: POST {base_url}/sap/opu/odata/sap/API_OUTBOUND_DELIVERY_SRV/A_OutbDeliveryHeader
    Inbound:  POST {base_url}/sap/opu/odata/sap/API_INBOUND_DELIVERY_SRV/A_InbDeliveryHeader

  Params:
    %{
      sap_contract_id: "4600000101",
      counterparty: "NGC Trinidad",
      direction: :purchase | :sale,
      quantity_mt: 23_000,
      vessel: "MT Gas Chem Beluga",
      loading_port: "Point Lisas",
      discharge_port: "Tampa",
      eta: ~D[2026-03-15],
      notes: "March cargo — solver run abc123"
    }

  Returns {:ok, %{delivery_id: "...", status: :created}} or {:error, reason}.

  STUB — does not call SAP yet. Returns a simulated success.
  """
  def create_delivery(params) do
    Logger.info(
      "SAP OData STUB: create_delivery called — " <>
      "#{params[:quantity_mt]} MT on contract #{params[:sap_contract_id]} " <>
      "to #{params[:discharge_port]}"
    )

    # TODO: Replace with real OData POST when SAP connectivity is ready
    #
    # endpoint = case params[:direction] do
    #   :purchase -> "#{@sap_base_url}/sap/opu/odata/sap/API_INBOUND_DELIVERY_SRV/A_InbDeliveryHeader"
    #   :sale     -> "#{@sap_base_url}/sap/opu/odata/sap/API_OUTBOUND_DELIVERY_SRV/A_OutbDeliveryHeader"
    # end
    #
    # body = build_delivery_payload(params)
    #
    # case Req.post(endpoint, json: body, headers: odata_headers()) do
    #   {:ok, %{status: 201, body: response}} ->
    #     {:ok, %{
    #       delivery_id: response["d"]["DeliveryDocument"],
    #       status: :created,
    #       created_at: DateTime.utc_now()
    #     }}
    #   {:ok, %{status: status, body: body}} ->
    #     {:error, {:sap_error, status, body}}
    #   {:error, reason} ->
    #     {:error, {:request_failed, reason}}
    # end

    {:ok, %{
      delivery_id: nil,
      status: :stub_not_connected,
      message: "SAP write-back not yet connected — delivery would be created in SAP",
      params: params,
      requested_at: DateTime.utc_now()
    }}
  end

  @doc """
  Check if SAP OData connectivity is available.

  Tests the OData service root with a $metadata request.
  Returns true if SAP responds, false if not configured or unreachable.
  """
  def connected? do
    # TODO: Replace with real connectivity check
    #
    # case Req.get("#{@sap_base_url}/sap/opu/odata/sap/API_CONTRACT_BALANCE/$metadata",
    #   headers: odata_headers(),
    #   receive_timeout: 5_000
    # ) do
    #   {:ok, %{status: 200}} -> true
    #   _ -> false
    # end

    false
  end

  # ──────────────────────────────────────────────────────────
  # OData Call Internals
  # ──────────────────────────────────────────────────────────

  defp odata_fetch_contract_balances(material_group, _product_group) do
    # TODO: Replace with real OData GET when SAP connectivity is ready
    #
    # url = "#{@sap_base_url}/sap/opu/odata/sap/API_CONTRACT_BALANCE/ContractBalanceSet"
    #
    # params = %{
    #   "$filter" => "MaterialGroup eq '#{material_group}' and CompanyCode eq '1000'",
    #   "$select" => Enum.join([
    #     "SoldToParty", "SoldToPartyName", "SalesContract", "PurchaseOrder",
    #     "ContractQuantity", "OpenQuantity", "DeliveredQuantity",
    #     "UnitOfMeasure", "IncotermsClassification", "ContractType",
    #     "PurchaseOrderDate", "ContractValidityEndDate"
    #   ], ","),
    #   "$expand" => "to_Deliveries($filter=DeliveryStatus ne 'C')",
    #   "$format" => "json",
    #   "sap-client" => @sap_client
    # }
    #
    # case Req.get(url, params: params, headers: odata_headers(), receive_timeout: 30_000) do
    #   {:ok, %{status: 200, body: %{"d" => %{"results" => results}}}} ->
    #     positions = parse_odata_positions(results)
    #     {:ok, positions}
    #
    #   {:ok, %{status: status, body: body}} ->
    #     Logger.error("SAP OData error #{status}: #{inspect(body)}")
    #     {:error, {:odata_error, status}}
    #
    #   {:error, reason} ->
    #     Logger.error("SAP OData request failed: #{inspect(reason)}")
    #     {:error, {:request_failed, reason}}
    # end

    Logger.debug("SAP OData STUB: returning seeded positions for MaterialGroup=#{material_group}")
    {:ok, @seed_positions}
  end

  defp sync_positions_to_store(positions, product_group) do
    Enum.reduce(positions, 0, fn {counterparty, pos}, count ->
      case Store.update_open_position(counterparty, product_group, pos.open_qty_mt) do
        {:ok, _} -> count + 1
        {:error, _} -> count
      end
    end)
  end

  # TODO: Uncomment when SAP connectivity is ready
  #
  # defp odata_headers do
  #   token = System.get_env("SAP_ODATA_TOKEN")
  #   user = System.get_env("SAP_ODATA_USER")
  #   pass = System.get_env("SAP_ODATA_PASS")
  #
  #   base = [
  #     {"Accept", "application/json"},
  #     {"Content-Type", "application/json"},
  #     {"sap-client", @sap_client},
  #     {"X-CSRF-Token", "Fetch"}
  #   ]
  #
  #   cond do
  #     token && token != "" ->
  #       [{"Authorization", "Bearer #{token}"} | base]
  #     user && pass ->
  #       encoded = Base.encode64("#{user}:#{pass}")
  #       [{"Authorization", "Basic #{encoded}"} | base]
  #     true ->
  #       base
  #   end
  # end
  #
  # defp parse_odata_positions(results) do
  #   Enum.reduce(results, %{}, fn row, acc ->
  #     counterparty = row["SoldToPartyName"] || row["SoldToParty"]
  #     contract_type = row["ContractType"]
  #     direction = if contract_type in ["K", "MK"], do: :purchase, else: :sale
  #
  #     contract_id = row["SalesContract"] || row["PurchaseOrder"]
  #     total = parse_odata_qty(row["ContractQuantity"])
  #     delivered = parse_odata_qty(row["DeliveredQuantity"])
  #     open = parse_odata_qty(row["OpenQuantity"])
  #
  #     incoterm = case row["IncotermsClassification"] do
  #       "FOB" -> :fob
  #       "CFR" -> :cfr
  #       "CIF" -> :cif
  #       "DAP" -> :dap
  #       "CPT" -> :cpt
  #       other -> String.downcase(other || "fob") |> String.to_atom()
  #     end
  #
  #     pending_deliveries = case row["to_Deliveries"] do
  #       %{"results" => dels} -> length(dels)
  #       _ -> 0
  #     end
  #
  #     Map.put(acc, counterparty, %{
  #       contract_number: contract_id,
  #       sap_contract_id: contract_id,
  #       total_qty_mt: total,
  #       delivered_qty_mt: delivered,
  #       open_qty_mt: open,
  #       direction: direction,
  #       incoterm: incoterm,
  #       period: if(total > 50_000, do: :annual, else: :spot),
  #       deliveries_pending: pending_deliveries,
  #       last_updated: DateTime.utc_now()
  #     })
  #   end)
  # end
  #
  # defp parse_odata_qty(nil), do: 0
  # defp parse_odata_qty(val) when is_number(val), do: val / 1.0
  # defp parse_odata_qty(val) when is_binary(val) do
  #   case Float.parse(val) do
  #     {f, _} -> f
  #     :error -> 0.0
  #   end
  # end
  #
  # defp build_contract_payload(params) do
  #   %{
  #     "SoldToParty" => params[:counterparty],
  #     "MaterialGroup" => Map.get(@material_groups, params[:product_group], "AMMONIA"),
  #     "ContractQuantity" => to_string(params[:quantity_mt]),
  #     "ContractQuantityUnit" => "MT",
  #     "IncotermsClassification" => params[:incoterm] |> to_string() |> String.upcase(),
  #     "ContractValidityStartDate" => "/Date(#{date_to_odata(params[:validity_start])})/",
  #     "ContractValidityEndDate" => "/Date(#{date_to_odata(params[:validity_end])})/"
  #   }
  # end
  #
  # defp build_delivery_payload(params) do
  #   %{
  #     "ReferenceSDDocument" => params[:sap_contract_id],
  #     "DeliveryQuantity" => to_string(params[:quantity_mt]),
  #     "DeliveryQuantityUnit" => "MT",
  #     "ShipToParty" => params[:counterparty]
  #   }
  # end
  #
  # defp date_to_odata(%Date{} = d) do
  #   d
  #   |> DateTime.new!(~T[00:00:00])
  #   |> DateTime.to_unix(:millisecond)
  # end
  # defp date_to_odata(_), do: 0
end
