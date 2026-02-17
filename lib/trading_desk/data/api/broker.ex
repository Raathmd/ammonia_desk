defmodule TradingDesk.Data.API.Broker do
  @moduledoc """
  Barge freight rate API integration.

  Fetches freight rates from barge brokers for the four route combinations:
    - fr_don_stl: Donaldsonville → St. Louis ($/ton)
    - fr_don_mem: Donaldsonville → Memphis ($/ton)
    - fr_geis_stl: Geismar → St. Louis ($/ton)
    - fr_geis_mem: Geismar → Memphis ($/ton)

  ## Data Sources

  Barge freight rates come from:

  1. **ACI (American Commercial Inland)** — Major barge carrier
     Internal rate API for contracted/spot rates

  2. **Ingram Barge Company** — Rate sheet/API

  3. **ACBL (American Commercial Barge Line)** — Rate feed

  4. **MarineTraffic/Vesseltracker** — AIS data for market intel

  5. **Internal broker system** — Custom TMS (Transportation Management)

  Freight rates fluctuate based on:
    - Fuel costs (diesel/bunker)
    - Barge availability (tight/loose market)
    - River conditions (draft restrictions, delays)
    - Seasonal demand patterns
    - Backhaul availability

  ## Authentication

  Configure via environment variables:
    - `BROKER_API_URL`: Freight rate feed endpoint
    - `BROKER_API_KEY`: Authentication key
    - `TMS_URL`: Internal TMS endpoint
    - `TMS_API_KEY`: TMS authentication
  """

  require Logger

  # Route definitions
  @routes %{
    don_stl: %{
      origin: "Donaldsonville, LA",
      dest: "St. Louis, MO",
      variable: :fr_don_stl,
      river_miles: 1050,
      typical_range: {40.0, 130.0}
    },
    don_mem: %{
      origin: "Donaldsonville, LA",
      dest: "Memphis, TN",
      variable: :fr_don_mem,
      river_miles: 600,
      typical_range: {20.0, 80.0}
    },
    geis_stl: %{
      origin: "Geismar, LA",
      dest: "St. Louis, MO",
      variable: :fr_geis_stl,
      river_miles: 1060,
      typical_range: {42.0, 135.0}
    },
    geis_mem: %{
      origin: "Geismar, LA",
      dest: "Memphis, TN",
      variable: :fr_geis_mem,
      river_miles: 610,
      typical_range: {22.0, 85.0}
    }
  }

  @doc """
  Fetch current freight rates for all routes.

  Returns `{:ok, %{fr_don_stl: float, fr_don_mem: float, fr_geis_stl: float, fr_geis_mem: float}}`
  or `{:error, reason}`.

  Tries: broker API → TMS → last known rates.
  """
  @spec fetch() :: {:ok, map()} | {:error, term()}
  def fetch do
    cond do
      broker_configured?() ->
        fetch_broker_api()

      tms_configured?() ->
        fetch_tms()

      true ->
        Logger.warning("Broker: no freight rate feed configured")
        {:error, :no_feed_configured}
    end
  end

  # ──────────────────────────────────────────────────────────
  # BROKER API
  # ──────────────────────────────────────────────────────────

  @doc "Fetch rates from broker API."
  @spec fetch_broker_api() :: {:ok, map()} | {:error, term()}
  def fetch_broker_api do
    url = System.get_env("BROKER_API_URL")
    api_key = System.get_env("BROKER_API_KEY")

    headers = [
      {"Authorization", "Bearer #{api_key}"},
      {"Accept", "application/json"}
    ]

    case http_get(url, headers) do
      {:ok, body} -> parse_broker_response(body)
      {:error, _} = err -> err
    end
  end

  defp parse_broker_response(body) do
    case Jason.decode(body) do
      {:ok, %{"rates" => rates}} when is_list(rates) ->
        mapped = Enum.reduce(rates, %{}, fn rate, acc ->
          origin = normalize_location(rate["origin"] || "")
          dest = normalize_location(rate["destination"] || "")
          price = parse_num(rate["rate"] || rate["price_per_ton"])

          route_key = match_route(origin, dest)

          if route_key && price do
            variable = @routes[route_key].variable
            Map.put(acc, variable, price)
          else
            acc
          end
        end)

        if map_size(mapped) > 0 do
          {:ok, Map.merge(%{source: :broker_api, as_of: DateTime.utc_now()}, mapped)}
        else
          {:error, :no_matching_routes}
        end

      {:ok, data} when is_map(data) ->
        # Direct field mapping
        result = %{
          fr_don_stl: parse_num(data["don_stl"] || data["fr_don_stl"]),
          fr_don_mem: parse_num(data["don_mem"] || data["fr_don_mem"]),
          fr_geis_stl: parse_num(data["geis_stl"] || data["fr_geis_stl"]),
          fr_geis_mem: parse_num(data["geis_mem"] || data["fr_geis_mem"]),
          source: :broker_api
        }

        {:ok, result}

      _ ->
        {:error, :parse_failed}
    end
  end

  # ──────────────────────────────────────────────────────────
  # TMS (Transportation Management System)
  # ──────────────────────────────────────────────────────────

  @doc "Fetch from internal TMS."
  @spec fetch_tms() :: {:ok, map()} | {:error, term()}
  def fetch_tms do
    url = System.get_env("TMS_URL") || ""
    api_key = System.get_env("TMS_API_KEY")

    tms_url = "#{url}/api/rates/current?product=ammonia&mode=barge"

    headers = if api_key do
      [{"Authorization", "Bearer #{api_key}"}, {"Accept", "application/json"}]
    else
      [{"Accept", "application/json"}]
    end

    case http_get(tms_url, headers) do
      {:ok, body} -> parse_tms_response(body)
      {:error, _} = err -> err
    end
  end

  defp parse_tms_response(body) do
    case Jason.decode(body) do
      {:ok, %{"rates" => rates}} when is_map(rates) ->
        {:ok, %{
          fr_don_stl: parse_num(rates["DON-STL"]),
          fr_don_mem: parse_num(rates["DON-MEM"]),
          fr_geis_stl: parse_num(rates["GEIS-STL"]),
          fr_geis_mem: parse_num(rates["GEIS-MEM"]),
          source: :tms
        }}

      _ ->
        {:error, :parse_failed}
    end
  end

  # ──────────────────────────────────────────────────────────
  # HELPERS
  # ──────────────────────────────────────────────────────────

  defp match_route(origin, dest) do
    origin_key = cond do
      String.contains?(origin, "donald") -> :don
      String.contains?(origin, "geismar") -> :geis
      true -> nil
    end

    dest_key = cond do
      String.contains?(dest, "louis") or String.contains?(dest, "stl") -> :stl
      String.contains?(dest, "memphis") or String.contains?(dest, "mem") -> :mem
      true -> nil
    end

    case {origin_key, dest_key} do
      {:don, :stl} -> :don_stl
      {:don, :mem} -> :don_mem
      {:geis, :stl} -> :geis_stl
      {:geis, :mem} -> :geis_mem
      _ -> nil
    end
  end

  defp normalize_location(loc) when is_binary(loc) do
    loc |> String.downcase() |> String.trim()
  end
  defp normalize_location(_), do: ""

  defp broker_configured?, do: System.get_env("BROKER_API_URL") not in [nil, ""]
  defp tms_configured?, do: System.get_env("TMS_URL") not in [nil, ""]

  defp parse_num(nil), do: nil
  defp parse_num(v) when is_number(v), do: v / 1.0
  defp parse_num(v) when is_binary(v) do
    case Float.parse(v) do
      {f, _} -> f
      :error -> nil
    end
  end

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
