defmodule AmmoniaDesk.Data.VesselWeather do
  @moduledoc """
  Vessel-proximate weather and tides lookup.

  Given a vessel's GPS position from AIS tracking, this module:
    1. Finds the nearest NOAA weather station and fetches local conditions
    2. Finds the nearest NOAA CO-OPS tidal station and fetches water levels
    3. Combines into a per-vessel weather/tides snapshot

  This allows the scenario desk to show:
    - Weather conditions at each vessel's current location (not just the origin)
    - Local water levels and tidal influence relevant to each vessel
    - Worst-case conditions across the fleet (for conservative auto-solve)

  ## How It Feeds the Solver

  The solver uses a single set of weather variables (temp_f, wind_mph, vis_mi, etc).
  When vessel positions are known, we compute the "worst-case fleet weather":

    - wind_mph: max wind across all vessel positions
    - vis_mi: min visibility across all vessel positions
    - temp_f: min temperature (coldest point, worst for ammonia vapor pressure)
    - precip_in: max precipitation
    - river_stage: from nearest USGS gauge, enriched with tidal data

  This gives the solver a conservative picture for route planning.
  """

  require Logger

  alias AmmoniaDesk.Data.API.VesselTracking
  alias AmmoniaDesk.Data.API.Tides

  # NOAA weather stations mapped to approximate lat/lon regions along the Mississippi
  @weather_stations [
    %{id: "KBTR", name: "Baton Rouge", lat: 30.53, lon: -91.15},
    %{id: "KMSY", name: "New Orleans (Kenner)", lat: 29.99, lon: -90.25},
    %{id: "KVKS", name: "Vicksburg", lat: 32.24, lon: -90.93},
    %{id: "KGLH", name: "Greenville", lat: 33.48, lon: -90.99},
    %{id: "KMEM", name: "Memphis", lat: 35.04, lon: -89.98},
    %{id: "KCGI", name: "Cape Girardeau", lat: 37.22, lon: -89.57},
    %{id: "KSTL", name: "St. Louis", lat: 38.75, lon: -90.37}
  ]

  @noaa_base "https://api.weather.gov"

  @doc """
  Fetch weather and tides for all tracked vessels.

  Returns `{:ok, %{vessel_conditions: [...], fleet_weather: map, fleet_tides: map}}`
  """
  @spec fetch_fleet_conditions() :: {:ok, map()} | {:error, term()}
  def fetch_fleet_conditions do
    case VesselTracking.fetch() do
      {:ok, %{vessels: vessels}} when length(vessels) > 0 ->
        # Fetch conditions for each vessel in parallel
        conditions =
          vessels
          |> Enum.map(fn vessel ->
            Task.async(fn -> fetch_vessel_conditions(vessel) end)
          end)
          |> Enum.map(fn task ->
            case Task.yield(task, 20_000) || Task.shutdown(task) do
              {:ok, result} -> result
              _ -> nil
            end
          end)
          |> Enum.reject(&is_nil/1)

        fleet_weather = compute_fleet_weather(conditions)
        fleet_tides = compute_fleet_tides(conditions)

        {:ok, %{
          vessel_conditions: conditions,
          fleet_weather: fleet_weather,
          fleet_tides: fleet_tides,
          vessel_count: length(conditions),
          timestamp: DateTime.utc_now()
        }}

      {:ok, %{vessels: []}} ->
        {:error, :no_vessels_found}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Fetch weather and tidal conditions for a single vessel position.

  Returns a map with:
    - vessel: original vessel data
    - weather: NOAA observation from nearest station
    - tides: NOAA CO-OPS water level from nearest station
    - station_distance_mi: distance to the weather station used
  """
  @spec fetch_vessel_conditions(map()) :: map() | nil
  def fetch_vessel_conditions(%{lat: lat, lon: lon} = vessel) when is_number(lat) and is_number(lon) do
    # Find nearest weather station
    {station, distance} = nearest_weather_station(lat, lon)

    # Fetch weather from nearest station
    weather = fetch_station_weather(station.id)

    # Fetch tides from nearest tidal station
    tide_station = Tides.nearest_station(lat, lon)
    tide_data = case Tides.fetch_water_level(tide_station.id) do
      {:ok, data} -> data
      _ -> nil
    end

    %{
      vessel: vessel,
      weather: case weather do
        {:ok, obs} -> obs
        _ -> nil
      end,
      tides: tide_data,
      weather_station: station.name,
      weather_station_id: station.id,
      tide_station: tide_station.name,
      tide_station_id: tide_station.id,
      station_distance_mi: Float.round(distance, 1),
      lat: lat,
      lon: lon
    }
  end
  def fetch_vessel_conditions(_), do: nil

  @doc """
  Compute worst-case fleet weather for conservative solver input.

  Takes the most adverse conditions across all vessel positions:
    - Highest wind speed
    - Lowest visibility
    - Lowest temperature (worst for ammonia vapor pressure)
    - Highest precipitation
  """
  @spec compute_fleet_weather([map()]) :: map()
  def compute_fleet_weather(conditions) do
    weather_obs = conditions
      |> Enum.map(& &1[:weather])
      |> Enum.reject(&is_nil/1)

    if length(weather_obs) == 0 do
      %{source: :no_data}
    else
      %{
        wind_mph: weather_obs |> Enum.map(& &1[:wind_mph]) |> Enum.reject(&is_nil/1) |> max_or_nil(),
        vis_mi: weather_obs |> Enum.map(& &1[:vis_mi]) |> Enum.reject(&is_nil/1) |> min_or_nil(),
        temp_f: weather_obs |> Enum.map(& &1[:temp_f]) |> Enum.reject(&is_nil/1) |> min_or_nil(),
        precip_in: weather_obs |> Enum.map(& &1[:precip_in]) |> Enum.reject(&is_nil/1) |> max_or_nil(),
        source: :fleet_aggregate,
        station_count: length(weather_obs)
      }
    end
  end

  @doc """
  Compute fleet tides summary from vessel conditions.
  """
  @spec compute_fleet_tides([map()]) :: map()
  def compute_fleet_tides(conditions) do
    tide_obs = conditions
      |> Enum.map(& &1[:tides])
      |> Enum.reject(&is_nil/1)

    if length(tide_obs) == 0 do
      %{source: :no_data}
    else
      levels = Enum.map(tide_obs, & &1[:water_level]) |> Enum.reject(&is_nil/1)

      %{
        min_water_level: min_or_nil(levels),
        max_water_level: max_or_nil(levels),
        mean_water_level: if(length(levels) > 0, do: Enum.sum(levels) / length(levels), else: nil),
        station_count: length(tide_obs),
        source: :fleet_aggregate
      }
    end
  end

  @doc "Find the nearest NOAA weather station to a lat/lon."
  @spec nearest_weather_station(float(), float()) :: {map(), float()}
  def nearest_weather_station(lat, lon) do
    @weather_stations
    |> Enum.map(fn station ->
      dist = VesselTracking.haversine_distance(lat, lon, station.lat, station.lon)
      {station, dist}
    end)
    |> Enum.min_by(fn {_station, dist} -> dist end)
  end

  # ──────────────────────────────────────────────────────────
  # WEATHER STATION FETCH
  # ──────────────────────────────────────────────────────────

  defp fetch_station_weather(station_id) do
    url = "#{@noaa_base}/stations/#{station_id}/observations/latest"
    headers = [
      {"User-Agent", "(AmmoniaDesk, ops@trammo.com)"},
      {"Accept", "application/geo+json"}
    ]

    case Req.get(url, headers: headers, receive_timeout: 15_000) do
      {:ok, %{status: 200, body: body}} ->
        parse_noaa_observation(body)

      {:ok, %{status: status}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, {:http_error, reason}}
    end
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  end

  defp parse_noaa_observation(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> parse_noaa_observation(decoded)
      {:error, reason} -> {:error, {:json_parse, reason}}
    end
  end

  defp parse_noaa_observation(%{"properties" => props}) do
    {:ok, %{
      temp_f: convert_temp(props["temperature"]),
      wind_mph: convert_wind(props["windSpeed"]),
      vis_mi: convert_visibility(props["visibility"]),
      precip_in: convert_precip(props["precipitationLastHour"]),
      wind_direction: get_value(props["windDirection"]),
      humidity: get_value(props["relativeHumidity"]),
      text: props["textDescription"],
      timestamp: props["timestamp"]
    }}
  end

  defp parse_noaa_observation(_), do: {:error, :unexpected_format}

  # ──────────────────────────────────────────────────────────
  # UNIT CONVERSIONS (same as NOAA module)
  # ──────────────────────────────────────────────────────────

  defp convert_temp(%{"value" => v, "unitCode" => "wmoUnit:degC"}) when is_number(v) do
    v * 9.0 / 5.0 + 32.0
  end
  defp convert_temp(%{"value" => v, "unitCode" => "wmoUnit:degF"}) when is_number(v), do: v
  defp convert_temp(_), do: nil

  defp convert_wind(%{"value" => v, "unitCode" => "wmoUnit:km_h-1"}) when is_number(v) do
    v * 0.621371
  end
  defp convert_wind(%{"value" => v, "unitCode" => "wmoUnit:m_s-1"}) when is_number(v) do
    v * 2.23694
  end
  defp convert_wind(_), do: nil

  defp convert_visibility(%{"value" => v, "unitCode" => "wmoUnit:m"}) when is_number(v) do
    v / 1609.34
  end
  defp convert_visibility(_), do: nil

  defp convert_precip(%{"value" => v, "unitCode" => "wmoUnit:mm"}) when is_number(v) do
    v / 25.4
  end
  defp convert_precip(_), do: 0.0

  defp get_value(%{"value" => v}) when is_number(v), do: v
  defp get_value(_), do: nil

  # ──────────────────────────────────────────────────────────
  # HELPERS
  # ──────────────────────────────────────────────────────────

  defp max_or_nil([]), do: nil
  defp max_or_nil(list), do: Enum.max(list)

  defp min_or_nil([]), do: nil
  defp min_or_nil(list), do: Enum.min(list)
end
