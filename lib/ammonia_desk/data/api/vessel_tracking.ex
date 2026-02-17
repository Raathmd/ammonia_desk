defmodule AmmoniaDesk.Data.API.VesselTracking do
  @moduledoc """
  AIS vessel tracking integration for barge towboats on the Mississippi River.

  Tracks towboat positions via AIS (Automatic Identification System) to determine
  where product is currently located along the river. Vessel positions are used to:

    - Fetch vessel-proximate weather (conditions at the vessel's current location)
    - Fetch local tides/currents data (from nearest NOAA CO-OPS station)
    - Estimate transit times and arrival windows
    - Display fleet position on the scenario desk

  ## AIS Data Sources (priority order)

    1. **VesselFinder** — REST API, credit-based, good inland waterway coverage
       Env: `VESSELFINDER_API_KEY`

    2. **MarineTraffic** — PS06 bounding box queries, comprehensive AIS network
       Env: `MARINETRAFFIC_API_KEY`

    3. **AISHub** — Community AIS sharing, free tier, spotty inland coverage
       Env: `AISHUB_API_KEY`

  ## Vessel Identification

  We track towboats, not barges (barges don't carry AIS transponders).
  Towboat identification is by MMSI or vessel name configured in env:

    - `TRACKED_VESSELS` — comma-separated MMSI numbers or vessel names

  ## Bounding Box

  The Lower Mississippi River corridor from NOLA to Cairo, IL:
    - SW corner: 29.0°N, -91.5°W (below NOLA)
    - NE corner: 37.2°N, -88.5°W (Cairo, IL)
  """

  require Logger

  # Mississippi River corridor bounding box
  @bbox %{
    min_lat: 29.0,
    max_lat: 37.2,
    min_lon: -91.5,
    max_lon: -88.5
  }

  # Key waypoints for position context
  @waypoints [
    %{name: "NOLA/Donaldsonville", lat: 30.10, lon: -90.99, mile: 0},
    %{name: "Baton Rouge", lat: 30.45, lon: -91.19, mile: 115},
    %{name: "Vicksburg", lat: 32.32, lon: -90.91, mile: 437},
    %{name: "Greenville", lat: 33.41, lon: -91.06, mile: 531},
    %{name: "Memphis", lat: 35.14, lon: -90.05, mile: 736},
    %{name: "Cairo", lat: 37.00, lon: -89.18, mile: 953},
    %{name: "St. Louis", lat: 38.63, lon: -90.20, mile: 1070}
  ]

  @doc """
  Fetch current positions of tracked vessels.

  Returns `{:ok, %{vessels: [vessel_map], fleet_summary: map}}` or `{:error, reason}`.

  Each vessel map contains:
    - mmsi: MMSI number
    - name: vessel name
    - lat: latitude
    - lon: longitude
    - course: course over ground (degrees)
    - speed: speed over ground (knots)
    - heading: true heading
    - status: navigational status
    - nearest_waypoint: closest waypoint name
    - river_mile: estimated river mile
    - timestamp: position report time
  """
  @spec fetch() :: {:ok, map()} | {:error, term()}
  def fetch do
    tracked = get_tracked_vessels()

    result =
      cond do
        has_key?("VESSELFINDER_API_KEY") ->
          fetch_vesselfinder(tracked)

        has_key?("MARINETRAFFIC_API_KEY") ->
          fetch_marinetraffic(tracked)

        has_key?("AISHUB_API_KEY") ->
          fetch_aishub(tracked)

        true ->
          {:error, :no_ais_provider_configured}
      end

    case result do
      {:ok, vessels} ->
        enriched = Enum.map(vessels, &enrich_vessel/1)
        summary = build_fleet_summary(enriched)
        {:ok, %{vessels: enriched, fleet_summary: summary}}

      {:error, _} = err ->
        err
    end
  end

  @doc "Get the list of tracked vessel MMSIs/names from config."
  @spec get_tracked_vessels() :: [String.t()]
  def get_tracked_vessels do
    case System.get_env("TRACKED_VESSELS") do
      nil -> []
      "" -> []
      csv -> String.split(csv, ",") |> Enum.map(&String.trim/1)
    end
  end

  @doc "Get the bounding box for the Mississippi River corridor."
  def bbox, do: @bbox

  @doc "Get the waypoint list."
  def waypoints, do: @waypoints

  @doc "Find the nearest waypoint to a lat/lon position."
  @spec nearest_waypoint(float(), float()) :: map()
  def nearest_waypoint(lat, lon) do
    Enum.min_by(@waypoints, fn wp ->
      haversine_distance(lat, lon, wp.lat, wp.lon)
    end)
  end

  @doc "Estimate river mile from lat/lon position."
  @spec estimate_river_mile(float(), float()) :: float()
  def estimate_river_mile(lat, lon) do
    # Find the two nearest waypoints and interpolate
    sorted =
      @waypoints
      |> Enum.map(fn wp -> {wp, haversine_distance(lat, lon, wp.lat, wp.lon)} end)
      |> Enum.sort_by(fn {_wp, dist} -> dist end)
      |> Enum.take(2)

    case sorted do
      [{wp1, d1}, {wp2, d2}] ->
        # Linear interpolation between nearest two waypoints
        total = d1 + d2
        if total > 0 do
          wp1.mile * (1 - d1 / total) + wp2.mile * (d1 / total)
        else
          wp1.mile
        end

      [{wp, _}] ->
        wp.mile

      [] ->
        0.0
    end
  end

  # ──────────────────────────────────────────────────────────
  # VESSELFINDER
  # ──────────────────────────────────────────────────────────

  defp fetch_vesselfinder(tracked_vessels) do
    api_key = System.get_env("VESSELFINDER_API_KEY")

    # VesselFinder supports fetching by MMSI list or bounding box
    url =
      if length(tracked_vessels) > 0 do
        mmsis = Enum.join(tracked_vessels, ",")
        "https://api.vesselfinder.com/vessels?userkey=#{api_key}&mmsi=#{mmsis}"
      else
        # Bounding box query for all vessels in corridor
        "https://api.vesselfinder.com/vessels?userkey=#{api_key}" <>
          "&latmin=#{@bbox.min_lat}&latmax=#{@bbox.max_lat}" <>
          "&lonmin=#{@bbox.min_lon}&lonmax=#{@bbox.max_lon}" <>
          "&type=70,71,72,79"  # Cargo/tanker vessel types
      end

    case http_get(url) do
      {:ok, body} -> parse_vesselfinder(body)
      {:error, _} = err -> err
    end
  end

  defp parse_vesselfinder(body) do
    case Jason.decode(body) do
      {:ok, %{"AIS" => ais_list}} when is_list(ais_list) ->
        vessels =
          Enum.map(ais_list, fn ais ->
            %{
              mmsi: to_string(ais["MMSI"]),
              name: ais["NAME"] || ais["SHIPNAME"] || "Unknown",
              lat: parse_num(ais["LATITUDE"]),
              lon: parse_num(ais["LONGITUDE"]),
              course: parse_num(ais["COURSE"]),
              speed: parse_num(ais["SPEED"]),
              heading: parse_num(ais["HEADING"]),
              status: parse_nav_status(ais["NAVSTAT"]),
              imo: ais["IMO"],
              ship_type: ais["TYPE"],
              destination: ais["DESTINATION"],
              eta: ais["ETA"],
              timestamp: ais["TIMESTAMP"],
              source: :vesselfinder
            }
          end)
          |> Enum.filter(fn v -> v.lat != nil and v.lon != nil end)

        {:ok, vessels}

      {:ok, %{"error" => error}} ->
        {:error, {:api_error, error}}

      {:ok, other} ->
        Logger.warning("VesselFinder: unexpected response format: #{inspect(other)}")
        {:error, :unexpected_format}

      {:error, reason} ->
        {:error, {:json_parse, reason}}
    end
  end

  # ──────────────────────────────────────────────────────────
  # MARINETRAFFIC
  # ──────────────────────────────────────────────────────────

  defp fetch_marinetraffic(tracked_vessels) do
    api_key = System.get_env("MARINETRAFFIC_API_KEY")

    # PS06 — Vessel Positions in Area
    url =
      "https://services.marinetraffic.com/api/exportvesseltrack/v:2/#{api_key}" <>
        "/MINLAT:#{@bbox.min_lat}/MAXLAT:#{@bbox.max_lat}" <>
        "/MINLON:#{@bbox.min_lon}/MAXLON:#{@bbox.max_lon}" <>
        "/protocol:jsono"

    url =
      if length(tracked_vessels) > 0 do
        mmsi = List.first(tracked_vessels)
        "https://services.marinetraffic.com/api/exportvessel/v:5/#{api_key}" <>
          "/mmsi:#{mmsi}/protocol:jsono"
      else
        url
      end

    case http_get(url) do
      {:ok, body} -> parse_marinetraffic(body)
      {:error, _} = err -> err
    end
  end

  defp parse_marinetraffic(body) do
    case Jason.decode(body) do
      {:ok, list} when is_list(list) ->
        vessels =
          Enum.map(list, fn v ->
            %{
              mmsi: to_string(v["MMSI"]),
              name: v["SHIPNAME"] || "Unknown",
              lat: parse_num(v["LAT"]),
              lon: parse_num(v["LON"]),
              course: parse_num(v["COURSE"]),
              speed: parse_num(v["SPEED"]),
              heading: parse_num(v["HEADING"]),
              status: parse_nav_status(v["STATUS"]),
              ship_type: v["SHIP_TYPE"],
              destination: v["DESTINATION"],
              timestamp: v["TIMESTAMP"],
              source: :marinetraffic
            }
          end)
          |> Enum.filter(fn v -> v.lat != nil and v.lon != nil end)

        {:ok, vessels}

      {:ok, %{"errors" => errors}} ->
        {:error, {:api_error, errors}}

      _ ->
        {:error, :parse_failed}
    end
  end

  # ──────────────────────────────────────────────────────────
  # AISHUB
  # ──────────────────────────────────────────────────────────

  defp fetch_aishub(tracked_vessels) do
    api_key = System.get_env("AISHUB_API_KEY")

    url =
      "https://data.aishub.net/ws.php?username=#{api_key}&format=1&output=json" <>
        "&latmin=#{@bbox.min_lat}&latmax=#{@bbox.max_lat}" <>
        "&lonmin=#{@bbox.min_lon}&lonmax=#{@bbox.max_lon}"

    url =
      if length(tracked_vessels) > 0 do
        mmsis = Enum.join(tracked_vessels, ",")
        url <> "&mmsi=#{mmsis}"
      else
        url
      end

    case http_get(url) do
      {:ok, body} -> parse_aishub(body)
      {:error, _} = err -> err
    end
  end

  defp parse_aishub(body) do
    case Jason.decode(body) do
      {:ok, [_meta | data]} when is_list(data) ->
        vessels =
          data
          |> List.flatten()
          |> Enum.map(fn v ->
            %{
              mmsi: to_string(v["MMSI"]),
              name: v["NAME"] || "Unknown",
              lat: parse_num(v["LATITUDE"]) && parse_num(v["LATITUDE"]) / 600_000,
              lon: parse_num(v["LONGITUDE"]) && parse_num(v["LONGITUDE"]) / 600_000,
              course: parse_num(v["COG"]) && parse_num(v["COG"]) / 10,
              speed: parse_num(v["SOG"]) && parse_num(v["SOG"]) / 10,
              heading: parse_num(v["HEADING"]),
              status: parse_nav_status(v["NAVSTAT"]),
              timestamp: v["TIME"],
              source: :aishub
            }
          end)
          |> Enum.filter(fn v -> v.lat != nil and v.lon != nil end)

        {:ok, vessels}

      _ ->
        {:error, :parse_failed}
    end
  end

  # ──────────────────────────────────────────────────────────
  # ENRICHMENT
  # ──────────────────────────────────────────────────────────

  defp enrich_vessel(vessel) do
    wp = nearest_waypoint(vessel.lat, vessel.lon)
    mile = estimate_river_mile(vessel.lat, vessel.lon)

    direction =
      cond do
        vessel.course == nil -> :unknown
        vessel.course >= 315 or vessel.course < 45 -> :northbound
        vessel.course >= 135 and vessel.course < 225 -> :southbound
        true -> :unknown
      end

    vessel
    |> Map.put(:nearest_waypoint, wp.name)
    |> Map.put(:river_mile, Float.round(mile, 1))
    |> Map.put(:direction, direction)
    |> Map.put(:distance_to_waypoint_nm, Float.round(haversine_distance(vessel.lat, vessel.lon, wp.lat, wp.lon) * 0.539957, 1))
  end

  defp build_fleet_summary(vessels) do
    %{
      total_vessels: length(vessels),
      northbound: Enum.count(vessels, & &1.direction == :northbound),
      southbound: Enum.count(vessels, & &1.direction == :southbound),
      underway: Enum.count(vessels, & &1.status in [:underway_engine, :underway_sailing]),
      at_anchor: Enum.count(vessels, & &1.status == :at_anchor),
      moored: Enum.count(vessels, & &1.status == :moored),
      positions: Enum.map(vessels, fn v ->
        %{name: v.name, lat: v.lat, lon: v.lon, mile: v.river_mile, near: v.nearest_waypoint}
      end),
      timestamp: DateTime.utc_now()
    }
  end

  # ──────────────────────────────────────────────────────────
  # HELPERS
  # ──────────────────────────────────────────────────────────

  defp parse_nav_status(0), do: :underway_engine
  defp parse_nav_status(1), do: :at_anchor
  defp parse_nav_status(2), do: :not_under_command
  defp parse_nav_status(3), do: :restricted_maneuverability
  defp parse_nav_status(5), do: :moored
  defp parse_nav_status(7), do: :engaged_in_fishing
  defp parse_nav_status(8), do: :underway_sailing
  defp parse_nav_status("0"), do: :underway_engine
  defp parse_nav_status("1"), do: :at_anchor
  defp parse_nav_status("5"), do: :moored
  defp parse_nav_status(_), do: :unknown

  defp parse_num(nil), do: nil
  defp parse_num(v) when is_number(v), do: v / 1.0
  defp parse_num(v) when is_binary(v) do
    case Float.parse(v) do
      {f, _} -> f
      :error -> nil
    end
  end

  @doc """
  Haversine distance between two lat/lon points in statute miles.
  """
  @spec haversine_distance(float(), float(), float(), float()) :: float()
  def haversine_distance(lat1, lon1, lat2, lon2) do
    r = 3958.8  # Earth radius in statute miles

    dlat = deg_to_rad(lat2 - lat1)
    dlon = deg_to_rad(lon2 - lon1)

    a =
      :math.sin(dlat / 2) * :math.sin(dlat / 2) +
      :math.cos(deg_to_rad(lat1)) * :math.cos(deg_to_rad(lat2)) *
      :math.sin(dlon / 2) * :math.sin(dlon / 2)

    c = 2 * :math.atan2(:math.sqrt(a), :math.sqrt(1 - a))
    r * c
  end

  defp deg_to_rad(deg), do: deg * :math.pi() / 180.0

  defp has_key?(env_var) do
    System.get_env(env_var) not in [nil, ""]
  end

  defp http_get(url) do
    case Req.get(url, receive_timeout: 20_000) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        {:ok, body}

      {:ok, %{status: 200, body: body}} when is_map(body) or is_list(body) ->
        {:ok, Jason.encode!(body)}

      {:ok, %{status: status, body: body}} ->
        Logger.warning("VesselTracking: HTTP #{status}: #{inspect(body)}")
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, {:http_error, reason}}
    end
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  end
end
