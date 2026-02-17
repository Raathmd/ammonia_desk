defmodule AmmoniaDesk.Data.API.Internal do
  @moduledoc """
  Internal systems API integration.

  Fetches operational data from the company's internal systems (ERP, SCADA,
  TMS, treasury). Maps to solver variables:

    - inv_don: Inventory at Donaldsonville terminal (tons)
    - inv_geis: Inventory at Geismar terminal (tons)
    - stl_outage: St. Louis dock outage status (boolean)
    - mem_outage: Memphis dock outage status (boolean)
    - barge_count: Available barges
    - working_cap: Available working capital ($)

  ## Data Sources

  1. **SAP S/4HANA** (ERP) — Inventory positions, working capital
     - MM module: material stock levels per storage location
     - FI module: available cash/credit lines

  2. **SCADA/Historian** (terminal ops) — Tank levels, dock status
     - OSIsoft PI or Honeywell PHD
     - Real-time tank levels, loading/unloading status

  3. **TMS** (Transportation Management) — Barge fleet status
     - Barge positions and availability
     - Loading schedules

  4. **Dock Management System** — Outage/maintenance schedules
     - Planned maintenance windows
     - Emergency shutdowns

  ## Authentication

  Configure via environment variables:
    - `SAP_API_URL`: SAP OData/REST endpoint
    - `SAP_API_KEY`: SAP authentication (OAuth2 or basic)
    - `SCADA_API_URL`: SCADA historian endpoint
    - `SCADA_API_KEY`: SCADA authentication
    - `INTERNAL_API_URL`: Unified internal API (if available)
    - `INTERNAL_API_KEY`: Unified API auth
  """

  require Logger

  @doc """
  Fetch all internal operational data.

  Returns `{:ok, %{inv_don: float, inv_geis: float, stl_outage: bool, mem_outage: bool,
                     barge_count: float, working_cap: float}}`
  or `{:error, reason}`.

  Queries multiple internal systems and merges results.
  """
  @spec fetch() :: {:ok, map()} | {:error, term()}
  def fetch do
    if unified_api_configured?() do
      fetch_unified()
    else
      fetch_individual_systems()
    end
  end

  # ──────────────────────────────────────────────────────────
  # UNIFIED INTERNAL API
  # ──────────────────────────────────────────────────────────

  defp fetch_unified do
    url = System.get_env("INTERNAL_API_URL")
    api_key = System.get_env("INTERNAL_API_KEY")

    full_url = "#{url}/api/trading/current-state?product_group=ammonia"

    headers = [
      {"Authorization", "Bearer #{api_key}"},
      {"Accept", "application/json"}
    ]

    case http_get(full_url, headers) do
      {:ok, body} -> parse_unified(body)
      {:error, _} = err -> err
    end
  end

  defp parse_unified(body) do
    case Jason.decode(body) do
      {:ok, data} when is_map(data) ->
        {:ok, %{
          inv_don: parse_num(data["inventory_donaldsonville"] || data["inv_don"]),
          inv_geis: parse_num(data["inventory_geismar"] || data["inv_geis"]),
          stl_outage: parse_bool(data["stl_dock_outage"] || data["stl_outage"]),
          mem_outage: parse_bool(data["mem_dock_outage"] || data["mem_outage"]),
          barge_count: parse_num(data["available_barges"] || data["barge_count"]),
          working_cap: parse_num(data["working_capital"] || data["working_cap"]),
          source: :unified_api,
          as_of: data["timestamp"]
        }}

      _ ->
        {:error, :parse_failed}
    end
  end

  # ──────────────────────────────────────────────────────────
  # INDIVIDUAL SYSTEM QUERIES
  # ──────────────────────────────────────────────────────────

  defp fetch_individual_systems do
    results = %{}

    # Inventory from SAP or SCADA
    results = case fetch_inventory() do
      {:ok, inv} -> Map.merge(results, inv)
      {:error, _} -> results
    end

    # Dock status
    results = case fetch_dock_status() do
      {:ok, docks} -> Map.merge(results, docks)
      {:error, _} -> results
    end

    # Barge availability
    results = case fetch_barge_fleet() do
      {:ok, barges} -> Map.merge(results, barges)
      {:error, _} -> results
    end

    # Working capital
    results = case fetch_working_capital() do
      {:ok, cap} -> Map.merge(results, cap)
      {:error, _} -> results
    end

    if map_size(results) > 0 do
      {:ok, Map.put(results, :source, :individual_systems)}
    else
      {:error, :all_systems_unavailable}
    end
  end

  @doc "Fetch inventory levels from SAP or SCADA."
  @spec fetch_inventory() :: {:ok, map()} | {:error, term()}
  def fetch_inventory do
    sap_url = System.get_env("SAP_API_URL")
    sap_key = System.get_env("SAP_API_KEY")

    if sap_url do
      url = "#{sap_url}/api/material/stock?plants=DON,GEIS&material=NH3"

      headers = [
        {"Authorization", "Bearer #{sap_key}"},
        {"Accept", "application/json"}
      ]

      case http_get(url, headers) do
        {:ok, body} ->
          case Jason.decode(body) do
            {:ok, %{"stocks" => stocks}} when is_list(stocks) ->
              inv = Enum.reduce(stocks, %{}, fn stock, acc ->
                plant = stock["plant"] || ""
                qty = parse_num(stock["unrestricted_qty"] || stock["available_qty"])

                cond do
                  String.contains?(String.upcase(plant), "DON") ->
                    Map.put(acc, :inv_don, qty)
                  String.contains?(String.upcase(plant), "GEIS") ->
                    Map.put(acc, :inv_geis, qty)
                  true -> acc
                end
              end)
              {:ok, inv}

            {:ok, data} when is_map(data) ->
              {:ok, %{
                inv_don: parse_num(data["don"] || data["donaldsonville"]),
                inv_geis: parse_num(data["geis"] || data["geismar"])
              }}

            _ -> {:error, :parse_failed}
          end

        {:error, _} = err -> err
      end
    else
      # Try SCADA as fallback
      fetch_inventory_scada()
    end
  end

  defp fetch_inventory_scada do
    scada_url = System.get_env("SCADA_API_URL")
    scada_key = System.get_env("SCADA_API_KEY")

    if scada_url do
      url = "#{scada_url}/api/tags/current?tags=DON.NH3.TANK_LEVEL,GEIS.NH3.TANK_LEVEL"

      headers = if scada_key do
        [{"Authorization", "Bearer #{scada_key}"}]
      else
        []
      end

      case http_get(url, headers) do
        {:ok, body} ->
          case Jason.decode(body) do
            {:ok, %{"values" => values}} when is_map(values) ->
              {:ok, %{
                inv_don: parse_num(values["DON.NH3.TANK_LEVEL"]),
                inv_geis: parse_num(values["GEIS.NH3.TANK_LEVEL"])
              }}
            _ -> {:error, :parse_failed}
          end
        {:error, _} = err -> err
      end
    else
      {:error, :scada_not_configured}
    end
  end

  @doc "Fetch dock outage status."
  @spec fetch_dock_status() :: {:ok, map()} | {:error, term()}
  def fetch_dock_status do
    sap_url = System.get_env("SAP_API_URL")
    sap_key = System.get_env("SAP_API_KEY")

    if sap_url do
      url = "#{sap_url}/api/maintenance/dock-status?locations=STL,MEM"

      headers = [
        {"Authorization", "Bearer #{sap_key}"},
        {"Accept", "application/json"}
      ]

      case http_get(url, headers) do
        {:ok, body} ->
          case Jason.decode(body) do
            {:ok, %{"docks" => docks}} when is_list(docks) ->
              status = Enum.reduce(docks, %{}, fn dock, acc ->
                loc = String.upcase(dock["location"] || "")
                outage = parse_bool(dock["outage"] || dock["is_down"])

                cond do
                  String.contains?(loc, "STL") or String.contains?(loc, "LOUIS") ->
                    Map.put(acc, :stl_outage, outage)
                  String.contains?(loc, "MEM") ->
                    Map.put(acc, :mem_outage, outage)
                  true -> acc
                end
              end)
              {:ok, status}

            _ -> {:error, :parse_failed}
          end

        {:error, _} = err -> err
      end
    else
      {:error, :sap_not_configured}
    end
  end

  @doc "Fetch barge fleet availability."
  @spec fetch_barge_fleet() :: {:ok, map()} | {:error, term()}
  def fetch_barge_fleet do
    tms_url = System.get_env("TMS_URL")
    tms_key = System.get_env("TMS_API_KEY")

    if tms_url do
      url = "#{tms_url}/api/fleet/available?product=ammonia"

      headers = if tms_key do
        [{"Authorization", "Bearer #{tms_key}"}, {"Accept", "application/json"}]
      else
        [{"Accept", "application/json"}]
      end

      case http_get(url, headers) do
        {:ok, body} ->
          case Jason.decode(body) do
            {:ok, %{"available_barges" => count}} when is_number(count) ->
              {:ok, %{barge_count: count / 1.0}}

            {:ok, %{"fleet" => fleet}} when is_list(fleet) ->
              available = Enum.count(fleet, fn b ->
                b["status"] in ["available", "ready", "idle"]
              end)
              {:ok, %{barge_count: available / 1.0}}

            _ -> {:error, :parse_failed}
          end

        {:error, _} = err -> err
      end
    else
      {:error, :tms_not_configured}
    end
  end

  @doc "Fetch available working capital."
  @spec fetch_working_capital() :: {:ok, map()} | {:error, term()}
  def fetch_working_capital do
    sap_url = System.get_env("SAP_API_URL")
    sap_key = System.get_env("SAP_API_KEY")

    if sap_url do
      url = "#{sap_url}/api/finance/working-capital?business_unit=TRADING"

      headers = [
        {"Authorization", "Bearer #{sap_key}"},
        {"Accept", "application/json"}
      ]

      case http_get(url, headers) do
        {:ok, body} ->
          case Jason.decode(body) do
            {:ok, data} when is_map(data) ->
              cap = parse_num(
                data["available_working_capital"] ||
                data["working_cap"] ||
                data["available_credit"]
              )

              if cap do
                {:ok, %{working_cap: cap}}
              else
                {:error, :no_capital_data}
              end

            _ -> {:error, :parse_failed}
          end

        {:error, _} = err -> err
      end
    else
      {:error, :sap_not_configured}
    end
  end

  # ──────────────────────────────────────────────────────────
  # HELPERS
  # ──────────────────────────────────────────────────────────

  defp unified_api_configured?, do: System.get_env("INTERNAL_API_URL") not in [nil, ""]

  defp parse_num(nil), do: nil
  defp parse_num(v) when is_number(v), do: v / 1.0
  defp parse_num(v) when is_binary(v) do
    case Float.parse(v) do
      {f, _} -> f
      :error -> nil
    end
  end

  defp parse_bool(nil), do: false
  defp parse_bool(v) when is_boolean(v), do: v
  defp parse_bool("true"), do: true
  defp parse_bool("false"), do: false
  defp parse_bool(1), do: true
  defp parse_bool(0), do: false
  defp parse_bool(_), do: false

  defp http_get(url, headers \\ []) do
    case Req.get(url, headers: headers, receive_timeout: 15_000) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        {:ok, body}

      {:ok, %{status: 200, body: body}} when is_map(body) ->
        {:ok, Jason.encode!(body)}

      {:ok, %{status: status}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, {:http_error, reason}}
    end
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  end
end
