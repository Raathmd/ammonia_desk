defmodule TradingDesk.Data.API.USGS do
  @moduledoc """
  USGS Water Services API integration.

  Fetches real-time river stage and flow data from USGS gauges on the
  Mississippi River. Used to determine navigability, barge transit times,
  and flood/low-water risk.

  API documentation: https://waterservices.usgs.gov/rest/IV-Service.html

  ## Gauges

  We monitor multiple gauges along the Lower Mississippi:
    - Cairo, IL (03612500) — confluence of Ohio + Mississippi
    - Memphis, TN (07032000) — primary Memphis reference
    - Vicksburg, MS (07289000) — mid-reach reference
    - Baton Rouge, LA (07374000) — near NOLA terminals

  ## Parameters

    - 00065: Gauge height (ft) — maps to `river_stage`
    - 00060: Discharge (cfs) — used for flow calculations

  ## Rate Limits

  USGS has no strict rate limit but requests max 1 per 15 minutes per gauge
  for instantaneous values (data only updates every 15 min anyway).
  """

  require Logger

  # Mississippi River gauges (south to north)
  @gauges %{
    baton_rouge: %{
      site_id: "07374000",
      name: "Mississippi River at Baton Rouge, LA",
      lat: 30.4456,
      lon: -91.1914
    },
    vicksburg: %{
      site_id: "07289000",
      name: "Mississippi River at Vicksburg, MS",
      lat: 32.3198,
      lon: -90.9074
    },
    memphis: %{
      site_id: "07032000",
      name: "Mississippi River at Memphis, TN",
      lat: 35.1356,
      lon: -90.0735
    },
    cairo: %{
      site_id: "03612500",
      name: "Ohio River at Metropolis, IL (near Cairo)",
      lat: 37.1478,
      lon: -88.7215
    }
  }

  @base_url "https://waterservices.usgs.gov/nwis/iv/"

  # Parameter codes
  @param_gauge_height "00065"
  @param_discharge "00060"

  @doc """
  Fetch current river conditions from USGS.

  Returns `{:ok, %{river_stage: float, river_flow: float, gauge_data: map}}` or `{:error, reason}`.

  The primary gauge is Baton Rouge (closest to NOLA terminals).
  Additional gauge data is included for transit planning.
  """
  @spec fetch() :: {:ok, map()} | {:error, term()}
  def fetch do
    fetch_gauge(:baton_rouge)
  end

  @doc "Fetch data from a specific gauge."
  @spec fetch_gauge(atom()) :: {:ok, map()} | {:error, term()}
  def fetch_gauge(gauge_key) do
    gauge = Map.get(@gauges, gauge_key)

    unless gauge do
      {:error, {:unknown_gauge, gauge_key}}
    else
      url = build_url(gauge.site_id, [@param_gauge_height, @param_discharge])

      case http_get(url) do
        {:ok, body} ->
          parse_response(body, gauge_key)

        {:error, reason} ->
          Logger.warning("USGS: fetch failed for #{gauge_key}: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  @doc "Fetch all gauges and return combined data."
  @spec fetch_all_gauges() :: {:ok, map()} | {:error, term()}
  def fetch_all_gauges do
    site_ids = @gauges |> Map.values() |> Enum.map_join(",", & &1.site_id)
    url = build_url(site_ids, [@param_gauge_height, @param_discharge])

    case http_get(url) do
      {:ok, body} -> parse_multi_gauge_response(body)
      {:error, _} = err -> err
    end
  end

  # ──────────────────────────────────────────────────────────
  # URL BUILDING
  # ──────────────────────────────────────────────────────────

  defp build_url(site_ids, param_codes) do
    params = URI.encode_query(%{
      "format" => "json",
      "sites" => site_ids,
      "parameterCd" => Enum.join(param_codes, ","),
      "period" => "PT2H"  # last 2 hours of data
    })

    "#{@base_url}?#{params}"
  end

  # ──────────────────────────────────────────────────────────
  # RESPONSE PARSING
  # ──────────────────────────────────────────────────────────

  defp parse_response(body, gauge_key) do
    case Jason.decode(body) do
      {:ok, %{"value" => %{"timeSeries" => series}}} ->
        values = extract_time_series(series)

        {:ok, %{
          river_stage: values[:gauge_height],
          river_flow: values[:discharge],
          gauge: gauge_key,
          observation_time: values[:datetime],
          raw_series: series
        }}

      {:ok, _other} ->
        {:error, :unexpected_response_format}

      {:error, reason} ->
        {:error, {:json_parse_failed, reason}}
    end
  end

  defp parse_multi_gauge_response(body) do
    case Jason.decode(body) do
      {:ok, %{"value" => %{"timeSeries" => series}}} ->
        # Group by site
        by_site = Enum.group_by(series, fn ts ->
          get_in(ts, ["sourceInfo", "siteCode", Access.at(0), "value"])
        end)

        gauge_data = Map.new(@gauges, fn {key, gauge} ->
          site_series = Map.get(by_site, gauge.site_id, [])
          values = extract_time_series(site_series)
          {key, values}
        end)

        # Primary values from Baton Rouge
        primary = Map.get(gauge_data, :baton_rouge, %{})

        {:ok, %{
          river_stage: primary[:gauge_height],
          river_flow: primary[:discharge],
          gauges: gauge_data
        }}

      _ ->
        {:error, :parse_failed}
    end
  end

  defp extract_time_series(series) do
    Enum.reduce(series, %{}, fn ts, acc ->
      param_code = get_in(ts, ["variable", "variableCode", Access.at(0), "value"])
      most_recent = get_in(ts, ["values", Access.at(0), "value", Access.at(0)])

      value = parse_float(most_recent["value"])
      datetime = most_recent["dateTime"]

      case param_code do
        @param_gauge_height ->
          acc |> Map.put(:gauge_height, value) |> Map.put(:datetime, datetime)

        @param_discharge ->
          Map.put(acc, :discharge, value)

        _ ->
          acc
      end
    end)
  end

  defp parse_float(nil), do: nil
  defp parse_float(v) when is_binary(v) do
    case Float.parse(v) do
      {f, _} -> f
      :error -> nil
    end
  end
  defp parse_float(v) when is_number(v), do: v / 1.0

  # ──────────────────────────────────────────────────────────
  # HTTP
  # ──────────────────────────────────────────────────────────

  defp http_get(url) do
    case Req.get(url, receive_timeout: 15_000) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        {:ok, body}

      {:ok, %{status: 200, body: body}} when is_map(body) ->
        # Req may auto-decode JSON
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
