defmodule AmmoniaDesk.ProductGroup.Frames.AmmoniaDomestic do
  @moduledoc """
  Solver frame for domestic ammonia barge trading on the Mississippi River.

  This is the original product group — anhydrous ammonia purchased at NOLA
  terminals (Donaldsonville, Geismar) and delivered by barge to St. Louis
  and Memphis.

  ## Transport
  Inland waterway barge on the Lower Mississippi River.

  ## Routes (4)
  - Donaldsonville → St. Louis (1050 miles, ~9 days)
  - Donaldsonville → Memphis (600 miles, ~5.5 days)
  - Geismar → St. Louis (1060 miles, ~9.5 days)
  - Geismar → Memphis (610 miles, ~6 days)

  ## Variables (20)
  Environment (6): river stage, lock delays, temperature, wind, visibility, precipitation
  Operations (5): Don inventory, Geis inventory, StL outage, Mem outage, barge count
  Commercial (9): NOLA buy, StL sell, Mem sell, 4 freight rates, nat gas, working capital
  """

  @behaviour AmmoniaDesk.ProductGroup.Frame

  @impl true
  def frame do
    %{
      id: :ammonia_domestic,
      name: "NH3 Domestic Barge",
      product: "Anhydrous Ammonia",
      transport_mode: :barge,
      geography: "Lower Mississippi River, USA",

      variables: variables(),
      routes: routes(),
      constraints: constraints(),
      api_sources: api_sources(),
      signal_thresholds: signal_thresholds(),
      contract_term_map: contract_term_map(),
      location_anchors: location_anchors(),
      price_anchors: price_anchors(),
      product_patterns: [~r/\banhydrous\s+ammonia\b/i, ~r/\bNH3\b/, ~r/\bammonia\b/i],
      chain_magic: "NH3\x01",
      chain_product_code: 0x01,

      default_poll_intervals: %{
        usgs:             :timer.minutes(15),
        noaa:             :timer.minutes(30),
        usace:            :timer.minutes(30),
        eia:              :timer.hours(1),
        market:           :timer.minutes(30),
        broker:           :timer.hours(1),
        internal:         :timer.minutes(5),
        vessel_tracking:  :timer.minutes(10),
        tides:            :timer.minutes(15)
      },

      solver_binary: "solver"  # native/solver (generic Zig LP solver)
    }
  end

  defp variables do
    [
      # ── ENVIRONMENT ──
      %{key: :river_stage, label: "River Stage", unit: "ft", min: 2, max: 55, step: 0.1,
        default: 18.0, source: :usgs, group: :environment, type: :float, delta_threshold: 0.5,
        perturbation: %{stddev: 3.0, min: 2, max: 55}},
      %{key: :lock_hrs, label: "Lock Delays", unit: "hrs", min: 0, max: 96, step: 1,
        default: 12.0, source: :usace, group: :environment, type: :float, delta_threshold: 2.0,
        perturbation: %{stddev: 4.0, min: 0, max: 96}},
      %{key: :temp_f, label: "Temperature", unit: "°F", min: -20, max: 115, step: 1,
        default: 45.0, source: :noaa, group: :environment, type: :float, delta_threshold: 5.0,
        perturbation: %{stddev: 5.0, min: -20, max: 115}},
      %{key: :wind_mph, label: "Wind Speed", unit: "mph", min: 0, max: 55, step: 1,
        default: 12.0, source: :noaa, group: :environment, type: :float, delta_threshold: 3.0,
        perturbation: %{stddev: 3.0, min: 0, max: 55}},
      %{key: :vis_mi, label: "Visibility", unit: "mi", min: 0.05, max: 15, step: 0.1,
        default: 5.0, source: :noaa, group: :environment, type: :float, delta_threshold: 1.0,
        perturbation: %{stddev: 1.5, min: 0.05, max: 15}},
      %{key: :precip_in, label: "Precip (3-day)", unit: "in", min: 0, max: 8, step: 0.1,
        default: 1.0, source: :noaa, group: :environment, type: :float, delta_threshold: 0.5,
        perturbation: %{stddev: 0.5, min: 0, max: 8}},

      # ── OPERATIONS ──
      %{key: :inv_don, label: "Donaldsonville Inv", unit: "tons", min: 0, max: 15_000, step: 100,
        default: 12_000.0, source: :internal, group: :operations, type: :float, delta_threshold: 500.0,
        perturbation: %{stddev: 1000, min: 0, max: 15_000}},
      %{key: :inv_geis, label: "Geismar Inv", unit: "tons", min: 0, max: 10_000, step: 100,
        default: 8_000.0, source: :internal, group: :operations, type: :float, delta_threshold: 500.0,
        perturbation: %{stddev: 800, min: 0, max: 10_000}},
      %{key: :stl_outage, label: "StL Dock Outage", unit: "", min: 0, max: 1, step: 1,
        default: false, source: :internal, group: :operations, type: :boolean, delta_threshold: 0.5,
        perturbation: %{flip_prob: 0.08}},
      %{key: :mem_outage, label: "Memphis Dock Outage", unit: "", min: 0, max: 1, step: 1,
        default: false, source: :internal, group: :operations, type: :boolean, delta_threshold: 0.5,
        perturbation: %{flip_prob: 0.05}},
      %{key: :barge_count, label: "Barges Available", unit: "", min: 1, max: 30, step: 1,
        default: 14.0, source: :internal, group: :operations, type: :float, delta_threshold: 1.0,
        perturbation: %{stddev: 2.0, min: 1, max: 30}},
      %{key: :demand_stl, label: "StL Max Demand", unit: "tons", min: 0, max: 20_000, step: 500,
        default: 10_000.0, source: :internal, group: :operations, type: :float, delta_threshold: 500.0,
        perturbation: %{stddev: 1500, min: 0, max: 20_000}},
      %{key: :demand_mem, label: "Memphis Max Demand", unit: "tons", min: 0, max: 15_000, step: 500,
        default: 8_000.0, source: :internal, group: :operations, type: :float, delta_threshold: 500.0,
        perturbation: %{stddev: 1200, min: 0, max: 15_000}},

      # ── COMMERCIAL ──
      %{key: :nola_buy, label: "NH3 NOLA Buy", unit: "$/t", min: 200, max: 600, step: 5,
        default: 320.0, source: :market, group: :commercial, type: :float, delta_threshold: 2.0,
        perturbation: %{stddev: 15.0, min: 200, max: 600}},
      %{key: :sell_stl, label: "NH3 StL Delivered", unit: "$/t", min: 300, max: 600, step: 5,
        default: 410.0, source: :market, group: :commercial, type: :float, delta_threshold: 2.0,
        perturbation: %{stddev: 12.0, min: 300, max: 600}},
      %{key: :sell_mem, label: "NH3 Memphis Delivered", unit: "$/t", min: 280, max: 550, step: 5,
        default: 385.0, source: :market, group: :commercial, type: :float, delta_threshold: 2.0,
        perturbation: %{stddev: 10.0, min: 280, max: 550}},
      %{key: :fr_don_stl, label: "Freight Don→StL", unit: "$/t", min: 20, max: 130, step: 1,
        default: 55.0, source: :broker, group: :commercial, type: :float, delta_threshold: 1.0,
        perturbation: %{stddev: 5.0, min: 20, max: 130}},
      %{key: :fr_don_mem, label: "Freight Don→Mem", unit: "$/t", min: 10, max: 80, step: 1,
        default: 32.0, source: :broker, group: :commercial, type: :float, delta_threshold: 1.0,
        perturbation: %{stddev: 3.0, min: 10, max: 80}},
      %{key: :fr_geis_stl, label: "Freight Geis→StL", unit: "$/t", min: 20, max: 135, step: 1,
        default: 58.0, source: :broker, group: :commercial, type: :float, delta_threshold: 1.0,
        perturbation: %{stddev: 5.0, min: 20, max: 135}},
      %{key: :fr_geis_mem, label: "Freight Geis→Mem", unit: "$/t", min: 10, max: 85, step: 1,
        default: 34.0, source: :broker, group: :commercial, type: :float, delta_threshold: 1.0,
        perturbation: %{stddev: 3.0, min: 10, max: 85}},
      %{key: :nat_gas, label: "Nat Gas (Henry Hub)", unit: "$/MMBtu", min: 1.0, max: 8.0, step: 0.05,
        default: 2.80, source: :eia, group: :commercial, type: :float, delta_threshold: 0.10,
        perturbation: %{stddev: 0.3, min: 1.0, max: 8.0}},
      %{key: :working_cap, label: "Working Capital", unit: "$", min: 500_000, max: 10_000_000, step: 100_000,
        default: 4_200_000.0, source: :internal, group: :commercial, type: :float, delta_threshold: 100_000.0,
        perturbation: %{stddev: 200_000, min: 500_000, max: 10_000_000}}
    ]
  end

  defp routes do
    [
      %{key: :don_stl, name: "Don→StL", origin: "Donaldsonville, LA", destination: "St. Louis, MO",
        distance_mi: 1050, transport_mode: :barge, freight_variable: :fr_don_stl,
        buy_variable: :nola_buy, sell_variable: :sell_stl,
        typical_transit_days: 9.0, transit_cost_per_day: 2.0, unit_capacity: 1500.0},
      %{key: :don_mem, name: "Don→Mem", origin: "Donaldsonville, LA", destination: "Memphis, TN",
        distance_mi: 600, transport_mode: :barge, freight_variable: :fr_don_mem,
        buy_variable: :nola_buy, sell_variable: :sell_mem,
        typical_transit_days: 5.5, transit_cost_per_day: 2.0, unit_capacity: 1500.0},
      %{key: :geis_stl, name: "Geis→StL", origin: "Geismar, LA", destination: "St. Louis, MO",
        distance_mi: 1060, transport_mode: :barge, freight_variable: :fr_geis_stl,
        buy_variable: :nola_buy, sell_variable: :sell_stl,
        typical_transit_days: 9.5, transit_cost_per_day: 2.0, unit_capacity: 1500.0},
      %{key: :geis_mem, name: "Geis→Mem", origin: "Geismar, LA", destination: "Memphis, TN",
        distance_mi: 610, transport_mode: :barge, freight_variable: :fr_geis_mem,
        buy_variable: :nola_buy, sell_variable: :sell_mem,
        typical_transit_days: 6.0, transit_cost_per_day: 2.0, unit_capacity: 1500.0}
    ]
  end

  defp constraints do
    all_routes = [:don_stl, :don_mem, :geis_stl, :geis_mem]

    [
      %{key: :supply_don, name: "Supply Don", type: :supply, terminal: "Donaldsonville",
        bound_variable: :inv_don, routes: [:don_stl, :don_mem]},
      %{key: :supply_geis, name: "Supply Geis", type: :supply, terminal: "Geismar",
        bound_variable: :inv_geis, routes: [:geis_stl, :geis_mem]},
      %{key: :cap_stl, name: "StL Capacity", type: :demand_cap, destination: "St. Louis",
        bound_variable: :demand_stl, outage_variable: :stl_outage, outage_factor: 0.0,
        routes: [:don_stl, :geis_stl]},
      %{key: :cap_mem, name: "Mem Capacity", type: :demand_cap, destination: "Memphis",
        bound_variable: :demand_mem, outage_variable: :mem_outage, outage_factor: 0.0,
        routes: [:don_mem, :geis_mem]},
      %{key: :fleet, name: "Fleet", type: :fleet_constraint,
        bound_variable: :barge_count, routes: all_routes},
      %{key: :working_cap, name: "Working Cap", type: :capital_constraint,
        bound_variable: :working_cap, routes: all_routes}
    ]
  end

  defp api_sources do
    %{
      usgs:     %{module: AmmoniaDesk.Data.API.USGS,     variables: [:river_stage]},
      noaa:     %{module: AmmoniaDesk.Data.API.NOAA,      variables: [:temp_f, :wind_mph, :vis_mi, :precip_in]},
      usace:    %{module: AmmoniaDesk.Data.API.USACE,     variables: [:lock_hrs]},
      eia:      %{module: AmmoniaDesk.Data.API.EIA,       variables: [:nat_gas]},
      market:   %{module: AmmoniaDesk.Data.API.Market,    variables: [:nola_buy, :sell_stl, :sell_mem]},
      broker:   %{module: AmmoniaDesk.Data.API.Broker,    variables: [:fr_don_stl, :fr_don_mem, :fr_geis_stl, :fr_geis_mem]},
      internal: %{module: AmmoniaDesk.Data.API.Internal,  variables: [:inv_don, :inv_geis, :stl_outage, :mem_outage, :barge_count, :demand_stl, :demand_mem, :working_cap]},
      vessel_tracking: %{module: AmmoniaDesk.Data.API.VesselTracking, variables: []},
      tides:    %{module: AmmoniaDesk.Data.API.Tides,     variables: []}
    }
  end

  defp signal_thresholds do
    %{
      strong_go: 50_000,   # p5 > this → STRONG GO
      go: 50_000,          # p25 > this → GO
      cautious: 0,         # p50 > this → CAUTIOUS
      weak: 0              # else → WEAK or NO GO
    }
  end

  defp contract_term_map do
    %{
      "PRICE" => :nola_buy,
      "QUANTITY_TOLERANCE" => :total_volume,
      "PAYMENT" => :working_cap,
      "LAYTIME_DEMURRAGE" => :demurrage,
      "FORCE_MAJEURE" => :force_majeure,
      "INSURANCE" => :insurance,
      "WAR_RISK_AND_ROUTE_CLOSURE" => :freight_rate,
      "DATES_WINDOWS_NOMINATIONS" => :delivery_window
    }
  end

  defp location_anchors do
    %{
      "donaldsonville" => :inv_don,
      "don" => :inv_don,
      "geismar" => :inv_geis,
      "geis" => :inv_geis,
      "st. louis" => :sell_stl,
      "stl" => :sell_stl,
      "memphis" => :sell_mem,
      "mem" => :sell_mem,
      "nola" => :nola_buy,
      "new orleans" => :nola_buy
    }
  end

  defp price_anchors do
    %{
      "buy" => :nola_buy,
      "purchase" => :nola_buy,
      "henry hub" => :nat_gas,
      "natural gas" => :nat_gas
    }
  end
end
