defmodule TradingDesk.Contracts.SapPositions do
  @moduledoc """
  SAP open positions API client for ammonia contracts.

  In production, calls SAP S/4HANA OData API to get open quantities per
  contract. For now, returns seeded positions matching the 10 seed contracts.

  The open position for each counterparty is the contractual quantity
  remaining to be delivered/lifted in the current period. This drives:
    - Volume obligation constraints in the solver
    - Penalty exposure calculations
    - Aggregate book position (long/short)

  API endpoint (production):
    GET /sap/opu/odata/sap/API_CONTRACT_BALANCE/ContractBalanceSet
    ?$filter=MaterialGroup eq 'AMMONIA' and CompanyCode eq '1000'
    &$select=SoldToParty,ContractQuantity,OpenQuantity,UnitOfMeasure

  Returns list of %{counterparty, contract_number, open_qty_mt, total_qty_mt,
    delivered_qty_mt, period, last_updated}
  """

  require Logger

  @seed_positions %{
    "NGC Trinidad" => %{
      contract_number: "TRAMMO-LTP-2026-0101",
      total_qty_mt: 180_000,
      delivered_qty_mt: 30_000,
      open_qty_mt: 150_000,
      direction: :purchase,
      incoterm: :fob,
      period: :annual,
      last_updated: ~U[2026-02-18 08:00:00Z]
    },
    "SABIC Agri-Nutrients" => %{
      contract_number: "TRAMMO-LTP-2026-0102",
      total_qty_mt: 150_000,
      delivered_qty_mt: 37_500,
      open_qty_mt: 112_500,
      direction: :purchase,
      incoterm: :fob,
      period: :annual,
      last_updated: ~U[2026-02-18 08:00:00Z]
    },
    "Ameropa AG" => %{
      contract_number: "TRAMMO-P-2026-0103",
      total_qty_mt: 23_000,
      delivered_qty_mt: 0,
      open_qty_mt: 23_000,
      direction: :purchase,
      incoterm: :fob,
      period: :spot,
      last_updated: ~U[2026-02-18 08:00:00Z]
    },
    "LSB Industries" => %{
      contract_number: "TRAMMO-DP-2026-0104",
      total_qty_mt: 32_000,
      delivered_qty_mt: 8_000,
      open_qty_mt: 24_000,
      direction: :purchase,
      incoterm: :fob,
      period: :annual,
      last_updated: ~U[2026-02-18 08:00:00Z]
    },
    "Mosaic Company" => %{
      contract_number: "TRAMMO-LTS-2026-0105",
      total_qty_mt: 100_000,
      delivered_qty_mt: 25_000,
      open_qty_mt: 75_000,
      direction: :sale,
      incoterm: :cfr,
      period: :annual,
      last_updated: ~U[2026-02-18 08:00:00Z]
    },
    "IFFCO" => %{
      contract_number: "TRAMMO-LTS-2026-0106",
      total_qty_mt: 120_000,
      delivered_qty_mt: 20_000,
      open_qty_mt: 100_000,
      direction: :sale,
      incoterm: :cfr,
      period: :annual,
      last_updated: ~U[2026-02-18 08:00:00Z]
    },
    "OCP Group" => %{
      contract_number: "TRAMMO-S-2026-0107",
      total_qty_mt: 20_000,
      delivered_qty_mt: 0,
      open_qty_mt: 20_000,
      direction: :sale,
      incoterm: :cfr,
      period: :spot,
      last_updated: ~U[2026-02-18 08:00:00Z]
    },
    "Nutrien StL" => %{
      contract_number: "TRAMMO-DS-2026-0108",
      total_qty_mt: 20_000,
      delivered_qty_mt: 5_000,
      open_qty_mt: 15_000,
      direction: :sale,
      incoterm: :fob,
      period: :annual,
      last_updated: ~U[2026-02-18 08:00:00Z]
    },
    "Koch Fertilizer" => %{
      contract_number: "TRAMMO-DS-2026-0109",
      total_qty_mt: 16_000,
      delivered_qty_mt: 4_000,
      open_qty_mt: 12_000,
      direction: :sale,
      incoterm: :fob,
      period: :annual,
      last_updated: ~U[2026-02-18 08:00:00Z]
    },
    "BASF SE" => %{
      contract_number: "TRAMMO-DAP-2026-0110",
      total_qty_mt: 15_000,
      delivered_qty_mt: 0,
      open_qty_mt: 15_000,
      direction: :sale,
      incoterm: :dap,
      period: :spot,
      last_updated: ~U[2026-02-18 08:00:00Z]
    }
  }

  @doc """
  Fetch open positions for all ammonia contracts.

  In production, calls SAP OData API. Currently returns seeded data.
  Returns {:ok, positions_map} or {:error, reason}.
  """
  def fetch_positions do
    # TODO: Replace with real SAP OData call when ready
    # url = "#{sap_base_url()}/sap/opu/odata/sap/API_CONTRACT_BALANCE/ContractBalanceSet"
    # params = %{"$filter" => "MaterialGroup eq 'AMMONIA'", "$select" => "..."}
    # case Req.get(url, params: params, headers: sap_headers()) do ...

    Logger.debug("SapPositions: returning seeded positions for 10 ammonia contracts")
    {:ok, @seed_positions}
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
end
