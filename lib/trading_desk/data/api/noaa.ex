defmodule TradingDesk.Data.API.NOAA do
  @moduledoc """
  NOAA Weather API integration.

  Fetches current weather observations relevant to barge operations on the
  Lower Mississippi River. Maps to solver variables:

    - temp_f: Air temperature (affects ammonia handling, vapor pressure)
    - wind_mph: Wind speed (affects barge navigation, loading ops)
    - vis_mi: Visibility (fog/haze affects transit, lock operations)
    - precip_in: Precipitation (affects river stage forecast)

  API documentation: https://www.weather.gov/documentation/services-web-api

  ## Stations

  We monitor weather stations along the barge route:
    - KBTR: Baton Rouge Metro (Ryan Field) — near NOLA terminals
    - KMEM: Memphis International — Memphis delivery point
    - KSTL: St. Louis Lambert — St. Louis delivery point
    - KVKS: Vicksburg Municipal — mid-route reference

  ## Rate Limits

  NOAA requires a User-Agent header with contact info.
  No strict rate limit, but courtesy suggests max 1 request/sec.
  """

  require Logger

  @stations %{
    baton_rouge: %{
      station_id: "KBTR",
      name: "Baton Rouge Metro Airport",
      role: :origin  # near NOLA terminals
    },
    memphis: %{
      station_id: "KMEM",
      name: "Memphis International Airport",
      role: :destination
    },
    st_louis: %{
      station_id: "KSTL",
      name: "St. Louis Lambert International",
      role: :destination
    },
    vicksburg: %{
      station_id: "KVKS",
      name: "Vicksburg Municipal Airport",
      role: :waypoint
    }
  }

  @base_url "https://api.weather.gov"
  @user_agent {"User-Agent", "(TradingDesk, ops@trammo.com)"}

  @doc """
  Fetch current weather observations for all stations.

  Returns `{:ok, %{temp_f: float, wind_mph: float, vis_mi: float, precip_in: float, stations: map}}`
  or `{:error, reason}`.

  Primary values come from Baton Rouge (origin).
  All station data is included for route-level weather assessment.
  """
  @spec fetch() :: {:ok, map()} | {:error, term()}
  def fetch do
    results =
      @stations
      |> Enum.map(fn {key, station} ->
        {key, fetch_station(station.station_id)}
      end)
      |> Map.new()

    # Primary station for solver variables
    primary = results[:baton_rouge]

    case primary do
      {:ok, obs} ->
        station_data = Map.new(results, fn {k, v} ->
          case v do
            {:ok, data} -> {k, data}
            {:error, _} -> {k, nil}
          end
        end)

        {:ok, %{
          temp_f: obs[:temp_f],
          wind_mph: obs[:wind_mph],
          vis_mi: obs[:vis_mi],
          precip_in: obs[:precip_in] || 0.0,
          stations: station_data
        }}

      {:error, reason} ->
        Logger.warning("NOAA: primary station fetch failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc "Fetch observations from a specific station."
  @spec fetch_station(String.t()) :: {:ok, map()} | {:error, term()}
  def fetch_station(station_id) do
    url = "#{@base_url}/stations/#{station_id}/observations/latest"

    case http_get(url) do
      {:ok, body} -> parse_observation(body)
      {:error, _} = err -> err
    end
  end

  @doc """
  Fetch 3-day precipitation forecast for origin area.

  Uses the NWS gridpoint forecast to get quantitative precipitation.
  Maps to `precip_in` variable.
  """
  @spec fetch_precip_forecast() :: {:ok, float()} | {:error, term()}
  def fetch_precip_forecast do
    # Baton Rouge grid point (pre-resolved)
    url = "#{@base_url}/gridpoints/LIX/66,62/forecast"

    case http_get(url) do
      {:ok, body} -> parse_precip_forecast(body)
      {:error, _} = err -> err
    end
  end

  # ──────────────────────────────────────────────────────────
  # PARSING
  # ──────────────────────────────────────────────────────────

  defp parse_observation(body) do
    case Jason.decode(body) do
      {:ok, %{"properties" => props}} ->
        {:ok, %{
          temp_f: convert_temp(props["temperature"]),
          wind_mph: convert_wind(props["windSpeed"]),
          vis_mi: convert_visibility(props["visibility"]),
          precip_in: convert_precip(props["precipitationLastHour"]),
          wind_direction: get_value(props["windDirection"]),
          dewpoint_f: convert_temp(props["dewpoint"]),
          humidity: get_value(props["relativeHumidity"]),
          barometric_pressure: get_value(props["barometricPressure"]),
          timestamp: props["timestamp"],
          text_description: props["textDescription"]
        }}

      _ ->
        {:error, :parse_failed}
    end
  end

  defp parse_precip_forecast(body) do
    case Jason.decode(body) do
      {:ok, %{"properties" => %{"periods" => periods}}} ->
        # Sum precipitation probability over next 3 days (6 periods)
        # This is a rough estimate — real QPF would use gridded data
        total_precip =
          periods
          |> Enum.take(6)  # ~3 days of 12-hour periods
          |> Enum.reduce(0.0, fn period, acc ->
            detail = period["detailedForecast"] || ""

            cond do
              String.contains?(detail, "heavy rain") -> acc + 1.5
              String.contains?(detail, "rain") -> acc + 0.5
              String.contains?(detail, "showers") -> acc + 0.3
              String.contains?(detail, "drizzle") -> acc + 0.1
              true -> acc
            end
          end)

        {:ok, total_precip}

      _ ->
        {:error, :parse_failed}
    end
  end

  # ──────────────────────────────────────────────────────────
  # UNIT CONVERSIONS
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
    v / 25.4  # mm to inches
  end
  defp convert_precip(_), do: 0.0

  defp get_value(%{"value" => v}) when is_number(v), do: v
  defp get_value(_), do: nil

  # ──────────────────────────────────────────────────────────
  # HTTP
  # ──────────────────────────────────────────────────────────

  defp http_get(url) do
    headers = [@user_agent, {"Accept", "application/geo+json"}]

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
