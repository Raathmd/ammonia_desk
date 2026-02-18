defmodule TradingDesk.Data.Poller do
  @moduledoc """
  Polls external APIs on admin-configured schedules and pushes updates to LiveState.

  Poll intervals are sourced from `DeltaConfig` — the admin can change them
  per product group at runtime. The Poller uses the shortest interval across
  all enabled product groups for each source (so if ammonia wants USGS every
  15 min and UAN wants it every 30 min, we poll every 15 min).

  Data sources:
    - USGS Water Services API (river stage/flow)
    - NOAA Weather API (temp, wind, vis, precip)
    - USACE Lock Performance (lock status/delays)
    - EIA API (nat gas prices)
    - Market price feeds (NOLA buy, delivered prices)
    - Broker freight feeds (barge freight rates)
    - Internal systems (inventory, outages, barges, working capital)

  On each poll, the Poller:
    1. Calls the real API integration module
    2. Falls back to simulated data if the API is not configured/available
    3. Updates LiveState with new values
    4. Broadcasts {:data_updated, source} if values changed
  """
  use GenServer
  require Logger

  alias TradingDesk.Config.DeltaConfig
  alias TradingDesk.Data.API

  # Default intervals used before DeltaConfig loads
  @fallback_intervals %{
    usgs:             :timer.minutes(15),
    noaa:             :timer.minutes(30),
    usace:            :timer.minutes(30),
    eia:              :timer.hours(1),
    market:           :timer.minutes(30),
    broker:           :timer.hours(1),
    internal:         :timer.minutes(5),
    vessel_tracking:  :timer.minutes(10),
    tides:            :timer.minutes(15)
  }

  # USGS gauge IDs for Mississippi River (kept for fallback)
  @usgs_gauges %{
    cairo_il: "03612500",
    memphis_tn: "07032000",
    vicksburg_ms: "07289000",
    baton_rouge_la: "07374000"
  }

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @doc "Get the status of all polled data sources: last poll time, errors, intervals."
  def status do
    GenServer.call(__MODULE__, :status)
  catch
    :exit, _ ->
      %{sources: [], last_poll: %{}, errors: %{}}
  end

  @impl true
  def handle_call(:status, _from, state) do
    sources =
      @fallback_intervals
      |> Map.keys()
      |> Enum.map(fn source ->
        %{
          source: source,
          label: source_label(source),
          last_poll_at: Map.get(state.last_poll, source),
          error: Map.get(state.errors, source),
          interval_ms: get_poll_interval(source),
          status: if(Map.has_key?(state.errors, source), do: :error, else: :ok)
        }
      end)
      |> Enum.sort_by(& &1.source)

    {:reply, %{sources: sources, last_poll: state.last_poll, errors: state.errors}, state}
  end

  @impl true
  def init(_) do
    # Subscribe to config changes so we can adjust poll intervals
    Phoenix.PubSub.subscribe(TradingDesk.PubSub, "delta_config")

    # Schedule first polls immediately
    sources = Map.keys(@fallback_intervals)
    Enum.each(sources, fn source ->
      send(self(), {:poll, source})
    end)

    {:ok, %{last_poll: %{}, errors: %{}, timers: %{}}}
  end

  @impl true
  def handle_info({:poll, source}, state) do
    new_state =
      case poll_source(source) do
        {:ok, data} ->
          old_vars = TradingDesk.Data.LiveState.get()
          TradingDesk.Data.LiveState.update(source, data)
          new_vars = TradingDesk.Data.LiveState.get()

          if old_vars != new_vars do
            Phoenix.PubSub.broadcast(TradingDesk.PubSub, "live_data", {:data_updated, source})
          end

          %{state |
            last_poll: Map.put(state.last_poll, source, DateTime.utc_now()),
            errors: Map.delete(state.errors, source)
          }

        {:error, reason} ->
          Logger.warning("Poll failed for #{source}: #{inspect(reason)}")
          %{state | errors: Map.put(state.errors, source, reason)}
      end

    # Schedule next poll using DeltaConfig intervals
    interval = get_poll_interval(source)
    timer_ref = Process.send_after(self(), {:poll, source}, interval)
    new_state = put_in(new_state, [:timers, source], timer_ref)

    {:noreply, new_state}
  end

  # Config changed — cancel and reschedule affected timers
  @impl true
  def handle_info({:delta_config, :config_updated, %{field: :poll_intervals}}, state) do
    Logger.info("Poller: poll intervals changed, rescheduling")
    # Existing timers will fire at their old schedule; the next reschedule
    # after they fire will pick up the new interval. No need to cancel early
    # unless we want immediate effect.
    {:noreply, state}
  end

  @impl true
  def handle_info({:delta_config, _, _}, state) do
    {:noreply, state}
  end

  # ──────────────────────────────────────────────────────────
  # API POLLING — real integrations with fallback
  # ──────────────────────────────────────────────────────────

  defp poll_source(:usgs) do
    case API.USGS.fetch() do
      {:ok, data} ->
        {:ok, Map.take(data, [:river_stage, :river_flow])}

      {:error, _reason} ->
        # Fallback: try direct HTTP with old parser
        poll_usgs_fallback()
    end
  end

  defp poll_source(:noaa) do
    case API.NOAA.fetch() do
      {:ok, data} ->
        {:ok, Map.take(data, [:temp_f, :wind_mph, :vis_mi, :precip_in])}

      {:error, _reason} ->
        poll_noaa_fallback()
    end
  end

  defp poll_source(:usace) do
    case API.USACE.fetch() do
      {:ok, data} ->
        {:ok, Map.take(data, [:lock_hrs])}

      {:error, _reason} ->
        # USACE API often requires special access; use defaults
        {:ok, %{lock_hrs: 12.0}}
    end
  end

  defp poll_source(:eia) do
    case API.EIA.fetch() do
      {:ok, data} ->
        {:ok, Map.take(data, [:nat_gas])}

      {:error, _reason} ->
        # No fallback available — keep last known value
        {:error, :eia_not_available}
    end
  end

  defp poll_source(:market) do
    case API.Market.fetch() do
      {:ok, data} ->
        {:ok, Map.take(data, [:nola_buy, :sell_stl, :sell_mem])}

      {:error, _reason} ->
        # Market feeds are subscription-based; keep last known
        {:error, :market_not_available}
    end
  end

  defp poll_source(:broker) do
    case API.Broker.fetch() do
      {:ok, data} ->
        {:ok, Map.take(data, [:fr_don_stl, :fr_don_mem, :fr_geis_stl, :fr_geis_mem])}

      {:error, _reason} ->
        {:error, :broker_not_available}
    end
  end

  defp poll_source(:internal) do
    case API.Internal.fetch() do
      {:ok, data} ->
        {:ok, Map.take(data, [:inv_don, :inv_geis, :stl_outage, :mem_outage,
                               :barge_count, :working_cap])}

      {:error, _reason} ->
        # Internal systems fallback — use simulated values
        {:ok, %{
          inv_don: 12_000.0,
          inv_geis: 8_000.0,
          stl_outage: false,
          mem_outage: false,
          barge_count: 14.0,
          working_cap: 4_200_000.0
        }}
    end
  end

  defp poll_source(:vessel_tracking) do
    case TradingDesk.Data.VesselWeather.fetch_fleet_conditions() do
      {:ok, data} ->
        # Store full vessel/weather/tides data in LiveState as supplementary data
        TradingDesk.Data.LiveState.update_supplementary(:vessel_tracking, data)

        # Extract fleet weather to update solver variables (worst-case across fleet)
        fleet_wx = data[:fleet_weather] || %{}
        solver_updates = %{}
          |> maybe_put(:wind_mph, fleet_wx[:wind_mph])
          |> maybe_put(:vis_mi, fleet_wx[:vis_mi])
          |> maybe_put(:temp_f, fleet_wx[:temp_f])

        if map_size(solver_updates) > 0 do
          {:ok, solver_updates}
        else
          {:ok, %{}}
        end

      {:error, _reason} ->
        # Try vessel tracking alone without weather enrichment
        case API.VesselTracking.fetch() do
          {:ok, data} ->
            TradingDesk.Data.LiveState.update_supplementary(:vessel_tracking, data)
            {:ok, %{}}

          {:error, reason} ->
            Logger.debug("Poller: vessel tracking unavailable: #{inspect(reason)}")
            {:ok, %{}}
        end
    end
  end

  defp poll_source(:tides) do
    case API.Tides.fetch() do
      {:ok, data} ->
        # Store full tidal data as supplementary
        TradingDesk.Data.LiveState.update_supplementary(:tides, data)

        # Water level can supplement river stage near NOLA
        {:ok, %{}}

      {:error, _reason} ->
        {:ok, %{}}
    end
  end

  # ──────────────────────────────────────────────────────────
  # FALLBACK PARSERS (from original implementation)
  # ──────────────────────────────────────────────────────────

  defp poll_usgs_fallback do
    gauge = @usgs_gauges.baton_rouge_la
    url = "https://waterservices.usgs.gov/nwis/iv/" <>
      "?format=json&sites=#{gauge}&parameterCd=00065,00060&period=PT1H"

    case http_get(url) do
      {:ok, body} -> parse_usgs(body)
      error -> error
    end
  end

  defp poll_noaa_fallback do
    url = "https://api.weather.gov/stations/KBTR/observations/latest"

    case http_get(url) do
      {:ok, body} -> parse_noaa(body)
      error -> error
    end
  end

  # ──────────────────────────────────────────────────────────
  # LEGACY PARSERS (kept as fallback)
  # ──────────────────────────────────────────────────────────

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
          precip_in: 0.0
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

  # ──────────────────────────────────────────────────────────
  # HELPERS
  # ──────────────────────────────────────────────────────────

  defp get_poll_interval(source) do
    try do
      DeltaConfig.effective_poll_intervals()
      |> Map.get(source, @fallback_intervals[source])
    rescue
      _ -> Map.get(@fallback_intervals, source, :timer.minutes(15))
    end
  end

  defp source_label(:usgs), do: "USGS Water Services"
  defp source_label(:noaa), do: "NOAA Weather"
  defp source_label(:usace), do: "USACE Lock Performance"
  defp source_label(:eia), do: "EIA Natural Gas"
  defp source_label(:market), do: "Market Prices"
  defp source_label(:broker), do: "Broker Freight"
  defp source_label(:internal), do: "Internal Systems"
  defp source_label(:vessel_tracking), do: "Vessel Tracking"
  defp source_label(:tides), do: "NOAA Tides"
  defp source_label(other), do: other |> to_string() |> String.capitalize()

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp http_get(url) do
    case Req.get(url, receive_timeout: 15_000) do
      {:ok, %{status: 200, body: body}} when is_binary(body) -> {:ok, body}
      {:ok, %{status: 200, body: body}} when is_map(body) -> {:ok, Jason.encode!(body)}
      {:ok, %{status: status}} -> {:error, {:http_status, status}}
      {:error, reason} -> {:error, {:http_error, reason}}
    end
  rescue
    _ -> {:error, :http_exception}
  end
end
