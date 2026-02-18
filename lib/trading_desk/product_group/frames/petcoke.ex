defmodule TradingDesk.ProductGroup.Frames.Petcoke do
  @moduledoc """
  Solver frame for petroleum coke (petcoke) trading.

  Trammo has been trading petcoke since 2009 and is a leading independent
  global trader. Petcoke is a by-product of petroleum refining with high
  calorific value, used as fuel source and in production of electrodes,
  concrete, and glass.

  ## Transport
  Ocean-going bulk carrier vessels from refineries to end users.

  ## Key Origins
  - US Gulf Coast (Texas, Louisiana refineries — largest global producer)
  - India (Reliance, IOCL, BPCL refineries)
  - Middle East (Saudi refineries)

  ## Key Destinations
  - India (cement, power — largest consumer)
  - China (aluminum smelting, power)
  - Turkey (cement)
  - Japan (power, calcining)

  ## Variables (16)
  Market (4): FOB USGC, FOB India, CFR India, CFR China
  Freight (3): USGC→India, USGC→China, India→China
  Operations (4): Refinery utilization, storage, vessel availability, load rate
  Quality/Macro (5): HGI, sulfur content, calorific value, bunker fuel, working capital
  """

  @behaviour TradingDesk.ProductGroup.Frame

  @impl true
  def frame do
    %{
      id: :petcoke,
      name: "Petroleum Coke",
      product: "Petroleum Coke (Fuel Grade)",
      transport_mode: :ocean_vessel,
      geography: "Global — US Gulf, India, Middle East → India, China, Turkey",

      variables: variables(),
      routes: routes(),
      constraints: constraints(),
      api_sources: api_sources(),
      signal_thresholds: signal_thresholds(),
      contract_term_map: contract_term_map(),
      location_anchors: location_anchors(),
      price_anchors: price_anchors(),
      product_patterns: [~r/\bpet(?:roleum)?\s*coke\b/i, ~r/\bpetcoke\b/i, ~r/\bfuel\s+grade\s+coke\b/i],
      chain_magic: "PCK\x01",
      chain_product_code: 0x20,

      default_poll_intervals: %{
        market_prices:    :timer.minutes(30),
        ocean_freight:    :timer.hours(1),
        vessel_tracking:  :timer.minutes(15),
        refinery_data:    :timer.hours(4),
        bunker_fuel:      :timer.hours(1),
        internal:         :timer.minutes(10)
      },

      solver_binary: "solver"  # generic LP solver (model descriptor driven)
    }
  end

  defp variables do
    [
      # ── MARKET PRICES ──
      %{key: :fob_usgc, label: "FOB US Gulf", unit: "$/t", min: 30, max: 200, step: 1,
        default: 55.0, source: :market_prices, group: :market, type: :float, delta_threshold: 2.0,
        perturbation: %{stddev: 5.0, min: 30, max: 200}},
      %{key: :fob_india, label: "FOB India", unit: "$/t", min: 20, max: 180, step: 1,
        default: 42.0, source: :market_prices, group: :market, type: :float, delta_threshold: 2.0,
        perturbation: %{stddev: 4.0, min: 20, max: 180}},
      %{key: :cfr_india, label: "CFR India", unit: "$/t", min: 50, max: 250, step: 1,
        default: 82.0, source: :market_prices, group: :market, type: :float, delta_threshold: 3.0,
        perturbation: %{stddev: 6.0, min: 50, max: 250}},
      %{key: :cfr_china, label: "CFR China", unit: "$/t", min: 50, max: 250, step: 1,
        default: 88.0, source: :market_prices, group: :market, type: :float, delta_threshold: 3.0,
        perturbation: %{stddev: 6.0, min: 50, max: 250}},

      # ── OCEAN FREIGHT ──
      %{key: :fr_usgc_india, label: "Freight USGC→India", unit: "$/t", min: 15, max: 70, step: 0.5,
        default: 30.0, source: :ocean_freight, group: :freight, type: :float, delta_threshold: 2.0,
        perturbation: %{stddev: 4.0, min: 15, max: 70}},
      %{key: :fr_usgc_china, label: "Freight USGC→China", unit: "$/t", min: 20, max: 80, step: 0.5,
        default: 35.0, source: :ocean_freight, group: :freight, type: :float, delta_threshold: 2.0,
        perturbation: %{stddev: 5.0, min: 20, max: 80}},
      %{key: :fr_india_china, label: "Freight India→China", unit: "$/t", min: 8, max: 40, step: 0.5,
        default: 15.0, source: :ocean_freight, group: :freight, type: :float, delta_threshold: 1.5,
        perturbation: %{stddev: 3.0, min: 8, max: 40}},

      # ── OPERATIONS ──
      %{key: :refinery_util_pct, label: "Refinery Utilization", unit: "%", min: 60, max: 100, step: 1,
        default: 92.0, source: :refinery_data, group: :operations, type: :float, delta_threshold: 2.0,
        perturbation: %{stddev: 3.0, min: 60, max: 100}},
      %{key: :storage_usgc_kt, label: "USGC Storage", unit: "kt", min: 0, max: 300, step: 10,
        default: 120.0, source: :internal, group: :operations, type: :float, delta_threshold: 15.0,
        perturbation: %{stddev: 20.0, min: 0, max: 300}},
      %{key: :vessel_count, label: "Vessels Available", unit: "", min: 0, max: 15, step: 1,
        default: 4.0, source: :internal, group: :operations, type: :float, delta_threshold: 1.0,
        perturbation: %{stddev: 1.0, min: 0, max: 15}},
      %{key: :load_rate_tpd, label: "Load Rate", unit: "t/day", min: 5000, max: 30_000, step: 1000,
        default: 15_000.0, source: :internal, group: :operations, type: :float, delta_threshold: 2000.0,
        perturbation: %{stddev: 3000.0, min: 5000, max: 30_000}},

      # ── SUPPLY / DEMAND CAPS ──
      %{key: :supply_india_kt, label: "India Supply Cap", unit: "kt", min: 0, max: 200, step: 10,
        default: 60.0, source: :internal, group: :operations, type: :float, delta_threshold: 10.0,
        perturbation: %{stddev: 10.0, min: 0, max: 200}},
      %{key: :demand_india_kt, label: "India Demand Cap", unit: "kt", min: 0, max: 500, step: 10,
        default: 200.0, source: :internal, group: :operations, type: :float, delta_threshold: 15.0,
        perturbation: %{stddev: 30.0, min: 0, max: 500}},
      %{key: :demand_china_kt, label: "China Demand Cap", unit: "kt", min: 0, max: 600, step: 20,
        default: 300.0, source: :internal, group: :operations, type: :float, delta_threshold: 20.0,
        perturbation: %{stddev: 40.0, min: 0, max: 600}},

      # ── QUALITY / MACRO ──
      %{key: :hgi, label: "HGI (Hardgrove)", unit: "", min: 30, max: 100, step: 1,
        default: 55.0, source: :internal, group: :quality, type: :float, delta_threshold: 3.0,
        perturbation: %{stddev: 5.0, min: 30, max: 100}},
      %{key: :sulfur_pct, label: "Sulfur Content", unit: "%", min: 1, max: 8, step: 0.1,
        default: 5.5, source: :internal, group: :quality, type: :float, delta_threshold: 0.3,
        perturbation: %{stddev: 0.5, min: 1, max: 8}},
      %{key: :cv_kcal, label: "Calorific Value", unit: "kcal/kg", min: 6000, max: 8500, step: 50,
        default: 7800.0, source: :internal, group: :quality, type: :float, delta_threshold: 100.0,
        perturbation: %{stddev: 150.0, min: 6000, max: 8500}},
      %{key: :bunker_380, label: "Bunker 380cSt", unit: "$/t", min: 200, max: 800, step: 5,
        default: 480.0, source: :bunker_fuel, group: :macro, type: :float, delta_threshold: 10.0,
        perturbation: %{stddev: 20.0, min: 200, max: 800}},
      %{key: :working_cap, label: "Working Capital", unit: "$M", min: 1, max: 50, step: 1,
        default: 12.0, source: :internal, group: :macro, type: :float, delta_threshold: 1.0,
        perturbation: %{stddev: 2.0, min: 1, max: 50}}
    ]
  end

  defp routes do
    [
      %{key: :usgc_india, name: "USGC → India", origin: "US Gulf Coast",
        destination: "Mundra/Kandla, India", distance_nm: 9500,
        transport_mode: :ocean_vessel, freight_variable: :fr_usgc_india,
        buy_variable: :fob_usgc, sell_variable: :cfr_india,
        typical_transit_days: 35, transit_cost_per_day: 0.2, unit_capacity: 50_000.0},
      %{key: :usgc_china, name: "USGC → China", origin: "US Gulf Coast",
        destination: "Qingdao/Lianyungang, China", distance_nm: 11_000,
        transport_mode: :ocean_vessel, freight_variable: :fr_usgc_china,
        buy_variable: :fob_usgc, sell_variable: :cfr_china,
        typical_transit_days: 40, transit_cost_per_day: 0.2, unit_capacity: 50_000.0},
      %{key: :india_china, name: "India → China", origin: "Mundra/Jamnagar, India",
        destination: "Qingdao/Lianyungang, China", distance_nm: 4500,
        transport_mode: :ocean_vessel, freight_variable: :fr_india_china,
        buy_variable: :fob_india, sell_variable: :cfr_china,
        typical_transit_days: 15, transit_cost_per_day: 0.2, unit_capacity: 50_000.0}
    ]
  end

  defp constraints do
    all_routes = [:usgc_india, :usgc_china, :india_china]

    [
      %{key: :supply_usgc, name: "USGC Supply", type: :supply, terminal: "US Gulf Coast",
        bound_variable: :storage_usgc_kt, routes: [:usgc_india, :usgc_china]},
      %{key: :supply_india, name: "India Supply", type: :supply, terminal: "India",
        bound_variable: :supply_india_kt, routes: [:india_china]},
      %{key: :dest_india, name: "India Demand", type: :demand_cap, destination: "India",
        bound_variable: :demand_india_kt, routes: [:usgc_india]},
      %{key: :dest_china, name: "China Demand", type: :demand_cap, destination: "China",
        bound_variable: :demand_china_kt, routes: [:usgc_china, :india_china]},
      %{key: :fleet, name: "Fleet", type: :fleet_constraint,
        bound_variable: :vessel_count, routes: all_routes},
      %{key: :working_cap, name: "Working Cap", type: :capital_constraint,
        bound_variable: :working_cap, routes: all_routes}
    ]
  end

  defp api_sources do
    %{
      market_prices:   %{module: nil, variables: [:fob_usgc, :fob_india, :cfr_india, :cfr_china],
                         description: "Argus Petcoke, CRU, Platts"},
      ocean_freight:   %{module: nil, variables: [:fr_usgc_india, :fr_usgc_china, :fr_india_china],
                         description: "Baltic Exchange, Clarksons"},
      vessel_tracking: %{module: TradingDesk.Data.API.VesselTracking, variables: [],
                         description: "AIS via VesselFinder/MarineTraffic"},
      refinery_data:   %{module: nil, variables: [:refinery_util_pct],
                         description: "EIA refinery utilization reports"},
      bunker_fuel:     %{module: nil, variables: [:bunker_380],
                         description: "Ship & Bunker, Argus Bunker Index"},
      internal:        %{module: nil, variables: [:storage_usgc_kt, :vessel_count, :load_rate_tpd,
                                                   :supply_india_kt, :demand_india_kt, :demand_china_kt,
                                                   :hgi, :sulfur_pct, :cv_kcal, :working_cap],
                         description: "Internal TMS, quality lab, SAP"}
    }
  end

  defp signal_thresholds do
    %{
      strong_go: 200_000,
      go: 100_000,
      cautious: 0,
      weak: 0
    }
  end

  defp contract_term_map do
    %{
      "PRICE" => :contract_price,
      "QUANTITY_TOLERANCE" => :total_volume,
      "PAYMENT" => :working_cap,
      "LAYTIME_DEMURRAGE" => :demurrage,
      "FORCE_MAJEURE" => :force_majeure,
      "QUALITY_SPECIFICATIONS" => :quality_spec,
      "LOADING_DISCHARGING_RATE" => :load_rate_tpd,
      "VESSEL_NOMINATION" => :vessel_count
    }
  end

  defp location_anchors do
    %{
      "us gulf" => :fob_usgc,
      "usgc" => :fob_usgc,
      "houston" => :fob_usgc,
      "port arthur" => :fob_usgc,
      "india" => :cfr_india,
      "mundra" => :cfr_india,
      "kandla" => :cfr_india,
      "china" => :cfr_china,
      "qingdao" => :cfr_china
    }
  end

  defp price_anchors do
    %{
      "fob" => nil,
      "cfr" => nil,
      "bunker" => :bunker_380
    }
  end
end
