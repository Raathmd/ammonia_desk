defmodule TradingDesk.Data.API.Tides do
  @moduledoc """
  NOAA CO-OPS Tides and Currents API integration.

  Fetches real-time water levels, tidal predictions, and current velocity
  from NOAA stations along the Lower Mississippi River and Gulf approaches.

  This data is critical for barge navigation:
    - Water level affects draft clearance and loading capacity
    - Tidal influence extends ~180 miles upriver from Head of Passes
    - Current velocity affects transit times (with/against current)
    - Air gap at bridges determines whether loaded barges can pass

  API: https://api.tidesandcurrents.noaa.gov/api/prod/datagetter
  Completely free, no authentication required.

  ## Stations

  Lower Mississippi River (south to north):
    - 8760721: Pilottown, LA (Head of Passes — tidal influence starts here)
    - 8761305: Shell Beach, LA (Lake Borgne approach)
    - 8761927: New Canal Station, LA (Lake Pontchartrain / NOLA)
    - 8762075: Port Fourchon, LA (Gulf access)
    - 8762483: I-10 Bonnet Carre Floodway, LA (upriver from NOLA)

  NOAA PORTS Lower Mississippi:
    - Currents at SW Pass
    - Wind/temp at Venice, Pilot Station, Alliance
    - Air gap at Huey Long Bridge (I-90), CCC Bridge
  """

  require Logger

  @base_url "https://api.tidesandcurrents.noaa.gov/api/prod/datagetter"

  # Stations ordered south-to-north along the river
  @stations %{
    pilottown: %{
      id: "8760721",
      name: "Pilottown, LA",
      lat: 29.1783,
      lon: -89.2583,
      role: :tidal_boundary,  # tidal influence starts here
      river_mile: -18.0       # below Head of Passes
    },
    shell_beach: %{
      id: "8761305",
      name: "Shell Beach, LA",
      lat: 29.8683,
      lon: -89.6733,
      role: :approach,
      river_mile: 0.0
    },
    new_canal: %{
      id: "8761927",
      name: "New Canal Station, LA",
      lat: 30.0272,
      lon: -90.1133,
      role: :nola_reference,
      river_mile: 30.0
    },
    port_fourchon: %{
      id: "8762075",
      name: "Port Fourchon, LA",
      lat: 29.1142,
      lon: -90.1992,
      role: :gulf_access,
      river_mile: -30.0
    },
    bonnet_carre: %{
      id: "8762483",
      name: "I-10 Bonnet Carre Floodway, LA",
      lat: 30.0669,
      lon: -90.3839,
      role: :upriver_nola,
      river_mile: 45.0
    }
  }

  # Current stations (NOAA PORTS)
  @current_stations %{
    sw_pass: %{
      id: "LMN0101",
      name: "SW Pass, LA",
      lat: 28.9325,
      lon: -89.4289
    }
  }

  @doc """
  Fetch current water levels and tidal data from all stations.

  Returns `{:ok, %{water_levels: map, tidal_range: float, current_velocity: float, ...}}`
  """
  @spec fetch() :: {:ok, map()} | {:error, term()}
  def fetch do
    # Fetch water levels from all stations in parallel
    tasks =
      @stations
      |> Enum.map(fn {key, station} ->
        {key, Task.async(fn -> fetch_water_level(station.id) end)}
      end)

    water_levels =
      Map.new(tasks, fn {key, task} ->
        result =
          case Task.yield(task, 15_000) || Task.shutdown(task) do
            {:ok, val} -> val
            _ -> {:error, :timeout}
          end
        {key, result}
      end)

    # Get tidal predictions for Pilottown (primary tidal station)
    tidal_pred = fetch_tidal_predictions("8760721")

    # Get currents at SW Pass
    current = fetch_current("LMN0101")

    # Build summary
    primary = water_levels[:pilottown]
    nola = water_levels[:new_canal]

    primary_level = case primary do
      {:ok, data} -> data[:water_level]
      _ -> nil
    end

    nola_level = case nola do
      {:ok, data} -> data[:water_level]
      _ -> nil
    end

    tidal_range = case tidal_pred do
      {:ok, pred} -> pred[:range]
      _ -> nil
    end

    current_speed = case current do
      {:ok, data} -> data[:speed]
      _ -> nil
    end

    station_data =
      Map.new(water_levels, fn {key, val} ->
        case val do
          {:ok, data} -> {key, Map.merge(data, Map.get(@stations, key, %{}))}
          _ -> {key, nil}
        end
      end)

    {:ok, %{
      water_level_ft: primary_level,
      nola_water_level_ft: nola_level,
      tidal_range_ft: tidal_range,
      current_speed_kn: current_speed,
      stations: station_data,
      tidal_predictions: case tidal_pred do
        {:ok, p} -> p
        _ -> nil
      end,
      timestamp: DateTime.utc_now()
    }}
  rescue
    e ->
      Logger.error("Tides: fetch failed: #{Exception.message(e)}")
      {:error, {:exception, Exception.message(e)}}
  end

  @doc "Fetch water level from a specific station."
  @spec fetch_water_level(String.t()) :: {:ok, map()} | {:error, term()}
  def fetch_water_level(station_id) do
    params = %{
      "station" => station_id,
      "product" => "water_level",
      "datum" => "MLLW",         # Mean Lower Low Water
      "units" => "english",       # feet
      "time_zone" => "gmt",
      "format" => "json",
      "date" => "latest",
      "application" => "TradingDesk"
    }

    url = "#{@base_url}?#{URI.encode_query(params)}"

    case http_get(url) do
      {:ok, body} -> parse_water_level(body)
      {:error, _} = err -> err
    end
  end

  @doc "Fetch tidal predictions (high/low) for next 24 hours."
  @spec fetch_tidal_predictions(String.t()) :: {:ok, map()} | {:error, term()}
  def fetch_tidal_predictions(station_id) do
    now = DateTime.utc_now()
    begin_date = Calendar.strftime(now, "%Y%m%d")
    end_date = Calendar.strftime(DateTime.add(now, 86400, :second), "%Y%m%d")

    params = %{
      "station" => station_id,
      "product" => "predictions",
      "datum" => "MLLW",
      "units" => "english",
      "time_zone" => "gmt",
      "format" => "json",
      "begin_date" => begin_date,
      "end_date" => end_date,
      "interval" => "hilo",       # high/low only
      "application" => "TradingDesk"
    }

    url = "#{@base_url}?#{URI.encode_query(params)}"

    case http_get(url) do
      {:ok, body} -> parse_tidal_predictions(body)
      {:error, _} = err -> err
    end
  end

  @doc "Fetch current velocity at a currents station."
  @spec fetch_current(String.t()) :: {:ok, map()} | {:error, term()}
  def fetch_current(station_id) do
    params = %{
      "station" => station_id,
      "product" => "currents",
      "units" => "english",       # knots
      "time_zone" => "gmt",
      "format" => "json",
      "date" => "latest",
      "application" => "TradingDesk"
    }

    url = "#{@base_url}?#{URI.encode_query(params)}"

    case http_get(url) do
      {:ok, body} -> parse_current(body)
      {:error, _} = err -> err
    end
  end

  @doc "Fetch water level from the station nearest to a given lat/lon."
  @spec fetch_nearest(float(), float()) :: {:ok, map()} | {:error, term()}
  def fetch_nearest(lat, lon) do
    nearest = nearest_station(lat, lon)
    fetch_water_level(nearest.id)
  end

  @doc "Find the nearest tidal station to a given lat/lon."
  @spec nearest_station(float(), float()) :: map()
  def nearest_station(lat, lon) do
    @stations
    |> Map.values()
    |> Enum.min_by(fn station ->
      dlat = station.lat - lat
      dlon = station.lon - lon
      dlat * dlat + dlon * dlon
    end)
  end

  @doc "Get all station metadata."
  def stations, do: @stations

  @doc "Get current station metadata."
  def current_stations, do: @current_stations

  # ──────────────────────────────────────────────────────────
  # PARSING
  # ──────────────────────────────────────────────────────────

  defp parse_water_level(body) do
    case Jason.decode(body) do
      {:ok, %{"data" => [latest | _]}} ->
        {:ok, %{
          water_level: parse_float(latest["v"]),
          sigma: parse_float(latest["s"]),
          flags: latest["f"],
          quality: latest["q"],
          timestamp: latest["t"]
        }}

      {:ok, %{"error" => %{"message" => msg}}} ->
        {:error, {:api_error, msg}}

      _ ->
        {:error, :parse_failed}
    end
  end

  defp parse_tidal_predictions(body) do
    case Jason.decode(body) do
      {:ok, %{"predictions" => predictions}} when is_list(predictions) ->
        parsed =
          Enum.map(predictions, fn p ->
            %{
              time: p["t"],
              level: parse_float(p["v"]),
              type: case p["type"] do
                "H" -> :high
                "L" -> :low
                _ -> :unknown
              end
            }
          end)

        # Calculate tidal range (max high - min low in next 24h)
        highs = Enum.filter(parsed, & &1.type == :high) |> Enum.map(& &1.level)
        lows = Enum.filter(parsed, & &1.type == :low) |> Enum.map(& &1.level)

        range =
          if length(highs) > 0 and length(lows) > 0 do
            Enum.max(highs) - Enum.min(lows)
          else
            nil
          end

        next_high = Enum.find(parsed, & &1.type == :high)
        next_low = Enum.find(parsed, & &1.type == :low)

        {:ok, %{
          predictions: parsed,
          range: range,
          next_high: next_high,
          next_low: next_low,
          count: length(parsed)
        }}

      {:ok, %{"error" => %{"message" => msg}}} ->
        {:error, {:api_error, msg}}

      _ ->
        {:error, :parse_failed}
    end
  end

  defp parse_current(body) do
    case Jason.decode(body) do
      {:ok, %{"data" => [latest | _]}} ->
        {:ok, %{
          speed: parse_float(latest["s"]),
          direction: parse_float(latest["d"]),
          bin: latest["b"],
          timestamp: latest["t"]
        }}

      {:ok, %{"error" => %{"message" => msg}}} ->
        {:error, {:api_error, msg}}

      _ ->
        {:error, :parse_failed}
    end
  end

  # ──────────────────────────────────────────────────────────
  # HELPERS
  # ──────────────────────────────────────────────────────────

  defp parse_float(nil), do: nil
  defp parse_float("") , do: nil
  defp parse_float(v) when is_number(v), do: v / 1.0
  defp parse_float(v) when is_binary(v) do
    case Float.parse(v) do
      {f, _} -> f
      :error -> nil
    end
  end

  defp http_get(url) do
    headers = [
      {"User-Agent", "(TradingDesk, ops@trammo.com)"},
      {"Accept", "application/json"}
    ]

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
