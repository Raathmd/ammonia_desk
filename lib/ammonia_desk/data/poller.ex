defmodule AmmoniaDesk.Data.Poller do
  @moduledoc """
  Polls external APIs on a schedule and pushes updates to LiveState.
  
  Data sources:
    - USGS Water Services API (river stage/flow) — every 15 min
    - NOAA Weather API (temp, wind, vis, precip) — every 30 min
    - USACE Lock Performance (lock status/delays) — every 30 min
    - EIA API (nat gas prices) — every hour
    - Internal systems (inventory, outages, barges) — every 5 min
  """
  use GenServer
  require Logger

  @poll_intervals %{
    usgs: :timer.minutes(15),
    noaa: :timer.minutes(30),
    usace: :timer.minutes(30),
    eia: :timer.hours(1),
    internal: :timer.minutes(5)
  }

  # USGS gauge IDs for Mississippi River
  @usgs_gauges %{
    cairo_il: "03612500",
    memphis_tn: "07032000",
    vicksburg_ms: "07289000",
    baton_rouge_la: "07374000"
  }

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def init(_) do
    # Schedule first polls immediately
    Enum.each(@poll_intervals, fn {source, _interval} ->
      send(self(), {:poll, source})
    end)

    {:ok, %{last_poll: %{}, errors: %{}}}
  end

  @impl true
  def handle_info({:poll, source}, state) do
    new_state =
      case poll_source(source) do
        {:ok, data} ->
          old_vars = AmmoniaDesk.Data.LiveState.get()
          AmmoniaDesk.Data.LiveState.update(source, data)
          new_vars = AmmoniaDesk.Data.LiveState.get()
          
          if old_vars != new_vars do
            Phoenix.PubSub.broadcast(AmmoniaDesk.PubSub, "live_data", {:data_updated, source})
          end

          %{state |
            last_poll: Map.put(state.last_poll, source, DateTime.utc_now()),
            errors: Map.delete(state.errors, source)
          }

        {:error, reason} ->
          Logger.warning("Poll failed for #{source}: #{inspect(reason)}")
          %{state | errors: Map.put(state.errors, source, reason)}
      end

    # Schedule next poll
    interval = Map.get(@poll_intervals, source, :timer.minutes(15))
    Process.send_after(self(), {:poll, source}, interval)

    {:noreply, new_state}
  end

  # --- API Polling Functions ---

  defp poll_source(:usgs) do
    # USGS Water Services API — instantaneous values
    # https://waterservices.usgs.gov/rest/IV/
    gauge = @usgs_gauges.cairo_il
    url = "https://waterservices.usgs.gov/nwis/iv/" <>
      "?format=json&sites=#{gauge}&parameterCd=00065,00060&period=PT1H"

    case http_get(url) do
      {:ok, body} ->
        parse_usgs(body)
      error ->
        error
    end
  end

  defp poll_source(:noaa) do
    # NOAA Weather API — current observations
    # Point: near Baton Rouge for Lower Mississippi
    url = "https://api.weather.gov/stations/KBTR/observations/latest"

    case http_get(url) do
      {:ok, body} ->
        parse_noaa(body)
      error ->
        error
    end
  end

  defp poll_source(:usace) do
    # USACE Lock Performance Monitoring System
    # Note: actual API requires specific endpoint access
    # Simulating with reasonable defaults until real API configured
    {:ok, %{
      lock_hrs: 12.0,
      locks: %{
        "Lock_25" => "OPEN",
        "Lock_27" => "OPEN",
        "Lock_52" => "OPEN"
      }
    }}
  end

  defp poll_source(:eia) do
    # EIA Natural Gas API
    # https://api.eia.gov/v2/natural-gas/pri/fut/data/
    # Requires API key — using placeholder
    {:ok, %{
      nat_gas: 2.80
    }}
  end

  defp poll_source(:internal) do
    # Internal systems — would connect to ERP/SCADA/TMS
    # Placeholder with realistic values
    {:ok, %{
      inv_don: 12_000.0,
      inv_geis: 8_000.0,
      stl_outage: false,
      mem_outage: false,
      barge_count: 14.0,
      nola_buy: 320.0,
      sell_stl: 410.0,
      sell_mem: 385.0,
      fr_don_stl: 55.0,
      fr_don_mem: 32.0,
      fr_geis_stl: 58.0,
      fr_geis_mem: 34.0,
      working_cap: 4_200_000.0
    }}
  end

  # --- Parsers ---

  defp parse_usgs(body) do
    case Jason.decode(body) do
      {:ok, %{"value" => %{"timeSeries" => series}}} ->
        values = Enum.reduce(series, %{}, fn ts, acc ->
          param = get_in(ts, ["variable", "variableCode", Access.at(0), "value"])
          value = get_in(ts, ["values", Access.at(0), "value", Access.at(0), "value"])

          case {param, value} do
            {"00065", v} when is_binary(v) ->
              Map.put(acc, :river_stage, String.to_float(v))
            {"00060", v} when is_binary(v) ->
              Map.put(acc, :river_flow, String.to_float(v))
            _ ->
              acc
          end
        end)

        {:ok, values}

      _ ->
        {:error, :parse_failed}
    end
  end

  defp parse_noaa(body) do
    case Jason.decode(body) do
      {:ok, %{"properties" => props}} ->
        {:ok, %{
          temp_f: get_noaa_value(props, "temperature", &c_to_f/1),
          wind_mph: get_noaa_value(props, "windSpeed", &kmh_to_mph/1),
          vis_mi: get_noaa_value(props, "visibility", &m_to_mi/1),
          precip_in: 0.0  # precipitation requires separate forecast endpoint
        }}

      _ ->
        {:error, :parse_failed}
    end
  end

  defp get_noaa_value(props, key, converter) do
    case get_in(props, [key, "value"]) do
      nil -> nil
      v -> converter.(v)
    end
  end

  defp c_to_f(c) when is_number(c), do: c * 9 / 5 + 32
  defp c_to_f(_), do: nil

  defp kmh_to_mph(k) when is_number(k), do: k * 0.621371
  defp kmh_to_mph(_), do: nil

  defp m_to_mi(m) when is_number(m), do: m / 1609.34
  defp m_to_mi(_), do: nil

  defp http_get(_url) do
    # In production: Req.get!(url).body
    # For now, return simulated data
    {:error, :not_configured}
  end
end
