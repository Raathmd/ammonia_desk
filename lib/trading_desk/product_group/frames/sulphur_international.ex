defmodule TradingDesk.ProductGroup.Frames.SulphurInternational do
  @moduledoc """
  Solver frame for international sulphur ocean trading.

  Trammo is the world's largest sulphur marketer (~5M MT/yr, 17% of global
  shipments). Sulphur is produced as a by-product of oil & gas refining and
  shipped globally on bulk carriers.

  ## Transport
  Ocean-going bulk carrier vessels + rail from inland origins.

  ## Key Origins
  - Vancouver, BC (Pacific Coast Terminals — one of world's largest sulphur terminals)
  - Middle East (Abu Dhabi, Saudi Arabia, Kuwait, Qatar — refinery by-product)
  - Kazakhstan/Central Asia (via Batumi, Georgia terminal — Trammo-owned)
  - US Gulf (Texas/Louisiana refineries)

  ## Key Destinations
  - North Africa (Morocco — OCP phosphate production)
  - India (fertilizer production)
  - China (fertilizer + chemical)
  - Brazil (fertilizer)
  - Australia (mining — metal leaching)

  ## Variables (18)
  Market (6): FOB prices at 3 origins, CFR prices at 3 destinations
  Freight (4): Ocean freight rates on 4 key routes
  Operations (4): Port congestion, vessel availability, storage levels, rail capacity
  Macro (4): FX rates, bunker fuel, Suez/Panama canal rates, weather
  """

  @behaviour TradingDesk.ProductGroup.Frame

  @impl true
  def frame do
    %{
      id: :sulphur_international,
      name: "Sulphur International",
      product: "Sulphur (Solid)",
      transport_mode: :ocean_vessel,
      geography: "Global — Middle East, Vancouver, Central Asia → N.Africa, India, China, Brazil",

      variables: variables(),
      routes: routes(),
      constraints: constraints(),
      api_sources: api_sources(),
      signal_thresholds: signal_thresholds(),
      contract_term_map: contract_term_map(),
      location_anchors: location_anchors(),
      price_anchors: price_anchors(),
      product_patterns: [~r/\bsulph?ur\b/i, ~r/\bsolid\s+sulph?ur\b/i, ~r/\bformed\s+sulph?ur\b/i],
      chain_magic: "SUL\x01",
      chain_product_code: 0x10,

      default_poll_intervals: %{
        market_prices:    :timer.minutes(30),
        ocean_freight:    :timer.hours(1),
        vessel_tracking:  :timer.minutes(15),
        port_congestion:  :timer.hours(2),
        fx_rates:         :timer.minutes(30),
        bunker_fuel:      :timer.hours(1),
        internal:         :timer.minutes(10)
      },

      solver_binary: "solver"  # generic LP solver (model descriptor driven)
    }
  end

  defp variables do
    [
      # ── MARKET PRICES ──
      %{key: :fob_vancouver, label: "FOB Vancouver", unit: "$/t", min: 50, max: 300, step: 1,
        default: 120.0, source: :market_prices, group: :market, type: :float, delta_threshold: 3.0,
        perturbation: %{stddev: 8.0, min: 50, max: 300}},
      %{key: :fob_mideast, label: "FOB Middle East", unit: "$/t", min: 40, max: 280, step: 1,
        default: 95.0, source: :market_prices, group: :market, type: :float, delta_threshold: 3.0,
        perturbation: %{stddev: 8.0, min: 40, max: 280}},
      %{key: :fob_batumi, label: "FOB Batumi", unit: "$/t", min: 40, max: 250, step: 1,
        default: 88.0, source: :market_prices, group: :market, type: :float, delta_threshold: 3.0,
        perturbation: %{stddev: 7.0, min: 40, max: 250}},
      %{key: :cfr_morocco, label: "CFR Morocco", unit: "$/t", min: 80, max: 350, step: 1,
        default: 155.0, source: :market_prices, group: :market, type: :float, delta_threshold: 3.0,
        perturbation: %{stddev: 10.0, min: 80, max: 350}},
      %{key: :cfr_india, label: "CFR India", unit: "$/t", min: 70, max: 350, step: 1,
        default: 140.0, source: :market_prices, group: :market, type: :float, delta_threshold: 3.0,
        perturbation: %{stddev: 10.0, min: 70, max: 350}},
      %{key: :cfr_china, label: "CFR China", unit: "$/t", min: 70, max: 350, step: 1,
        default: 145.0, source: :market_prices, group: :market, type: :float, delta_threshold: 3.0,
        perturbation: %{stddev: 10.0, min: 70, max: 350}},

      # ── OCEAN FREIGHT ──
      %{key: :fr_van_morocco, label: "Freight Van→Morocco", unit: "$/t", min: 15, max: 80, step: 0.5,
        default: 32.0, source: :ocean_freight, group: :freight, type: :float, delta_threshold: 2.0,
        perturbation: %{stddev: 4.0, min: 15, max: 80}},
      %{key: :fr_me_india, label: "Freight ME→India", unit: "$/t", min: 8, max: 50, step: 0.5,
        default: 18.0, source: :ocean_freight, group: :freight, type: :float, delta_threshold: 1.5,
        perturbation: %{stddev: 3.0, min: 8, max: 50}},
      %{key: :fr_me_china, label: "Freight ME→China", unit: "$/t", min: 12, max: 65, step: 0.5,
        default: 25.0, source: :ocean_freight, group: :freight, type: :float, delta_threshold: 2.0,
        perturbation: %{stddev: 4.0, min: 12, max: 65}},
      %{key: :fr_batumi_morocco, label: "Freight Batumi→Morocco", unit: "$/t", min: 10, max: 55, step: 0.5,
        default: 22.0, source: :ocean_freight, group: :freight, type: :float, delta_threshold: 1.5,
        perturbation: %{stddev: 3.0, min: 10, max: 55}},

      # ── OPERATIONS ──
      %{key: :port_congestion_days, label: "Dest Port Congestion", unit: "days", min: 0, max: 30, step: 0.5,
        default: 3.0, source: :port_congestion, group: :operations, type: :float, delta_threshold: 1.0,
        perturbation: %{stddev: 2.0, min: 0, max: 30}},
      %{key: :vessel_count, label: "Vessels Available", unit: "", min: 0, max: 20, step: 1,
        default: 6.0, source: :internal, group: :operations, type: :float, delta_threshold: 1.0,
        perturbation: %{stddev: 1.0, min: 0, max: 20}},
      %{key: :storage_vancouver_kt, label: "Vancouver Storage", unit: "kt", min: 0, max: 500, step: 10,
        default: 180.0, source: :internal, group: :operations, type: :float, delta_threshold: 20.0,
        perturbation: %{stddev: 30.0, min: 0, max: 500}},
      %{key: :rail_capacity_pct, label: "Rail Capacity (%)", unit: "%", min: 0, max: 100, step: 1,
        default: 85.0, source: :internal, group: :operations, type: :float, delta_threshold: 5.0,
        perturbation: %{stddev: 5.0, min: 0, max: 100}},

      # ── SUPPLY / DEMAND CAPS ──
      %{key: :supply_mideast_kt, label: "ME Supply Cap", unit: "kt", min: 0, max: 1000, step: 10,
        default: 300.0, source: :internal, group: :operations, type: :float, delta_threshold: 20.0,
        perturbation: %{stddev: 40.0, min: 0, max: 1000}},
      %{key: :supply_batumi_kt, label: "Batumi Supply Cap", unit: "kt", min: 0, max: 300, step: 10,
        default: 100.0, source: :internal, group: :operations, type: :float, delta_threshold: 10.0,
        perturbation: %{stddev: 15.0, min: 0, max: 300}},
      %{key: :demand_morocco_kt, label: "Morocco Demand Cap", unit: "kt", min: 0, max: 500, step: 10,
        default: 200.0, source: :internal, group: :operations, type: :float, delta_threshold: 20.0,
        perturbation: %{stddev: 30.0, min: 0, max: 500}},
      %{key: :demand_india_kt, label: "India Demand Cap", unit: "kt", min: 0, max: 800, step: 10,
        default: 300.0, source: :internal, group: :operations, type: :float, delta_threshold: 20.0,
        perturbation: %{stddev: 40.0, min: 0, max: 800}},
      %{key: :demand_china_kt, label: "China Demand Cap", unit: "kt", min: 0, max: 1000, step: 20,
        default: 500.0, source: :internal, group: :operations, type: :float, delta_threshold: 30.0,
        perturbation: %{stddev: 60.0, min: 0, max: 1000}},

      # ── MACRO ──
      %{key: :usd_inr, label: "USD/INR", unit: "", min: 70, max: 100, step: 0.1,
        default: 83.5, source: :fx_rates, group: :macro, type: :float, delta_threshold: 0.5,
        perturbation: %{stddev: 1.0, min: 70, max: 100}},
      %{key: :bunker_380, label: "Bunker 380cSt", unit: "$/t", min: 200, max: 800, step: 5,
        default: 480.0, source: :bunker_fuel, group: :macro, type: :float, delta_threshold: 10.0,
        perturbation: %{stddev: 20.0, min: 200, max: 800}},
      %{key: :suez_canal_usd, label: "Suez Transit Cost", unit: "$k", min: 100, max: 800, step: 10,
        default: 350.0, source: :internal, group: :macro, type: :float, delta_threshold: 20.0,
        perturbation: %{stddev: 30.0, min: 100, max: 800}},
      %{key: :working_cap, label: "Working Capital", unit: "$M", min: 1, max: 100, step: 1,
        default: 25.0, source: :internal, group: :macro, type: :float, delta_threshold: 2.0,
        perturbation: %{stddev: 3.0, min: 1, max: 100}}
    ]
  end

  defp routes do
    [
      %{key: :van_morocco, name: "Vancouver → Morocco", origin: "Vancouver, BC",
        destination: "Jorf Lasfar, Morocco", distance_nm: 8900,
        transport_mode: :ocean_vessel, freight_variable: :fr_van_morocco,
        buy_variable: :fob_vancouver, sell_variable: :cfr_morocco,
        typical_transit_days: 25, transit_cost_per_day: 0.3, unit_capacity: 50_000.0},
      %{key: :me_india, name: "ME → India", origin: "Abu Dhabi/Ruwais, UAE",
        destination: "Mumbai/Paradip, India", distance_nm: 1800,
        transport_mode: :ocean_vessel, freight_variable: :fr_me_india,
        buy_variable: :fob_mideast, sell_variable: :cfr_india,
        typical_transit_days: 7, transit_cost_per_day: 0.3, unit_capacity: 50_000.0},
      %{key: :me_china, name: "ME → China", origin: "Abu Dhabi/Ruwais, UAE",
        destination: "Nanjing/Zhanjiang, China", distance_nm: 5500,
        transport_mode: :ocean_vessel, freight_variable: :fr_me_china,
        buy_variable: :fob_mideast, sell_variable: :cfr_china,
        typical_transit_days: 18, transit_cost_per_day: 0.3, unit_capacity: 50_000.0},
      %{key: :batumi_morocco, name: "Batumi → Morocco", origin: "Batumi, Georgia",
        destination: "Jorf Lasfar, Morocco", distance_nm: 3200,
        transport_mode: :ocean_vessel, freight_variable: :fr_batumi_morocco,
        buy_variable: :fob_batumi, sell_variable: :cfr_morocco,
        typical_transit_days: 10, transit_cost_per_day: 0.3, unit_capacity: 50_000.0}
    ]
  end

  defp constraints do
    all_routes = [:van_morocco, :me_india, :me_china, :batumi_morocco]

    [
      %{key: :supply_vancouver, name: "Vancouver Supply", type: :supply, terminal: "Vancouver",
        bound_variable: :storage_vancouver_kt, routes: [:van_morocco]},
      %{key: :supply_mideast, name: "ME Supply", type: :supply, terminal: "Middle East",
        bound_variable: :supply_mideast_kt, routes: [:me_india, :me_china]},
      %{key: :supply_batumi, name: "Batumi Supply", type: :supply, terminal: "Batumi",
        bound_variable: :supply_batumi_kt, routes: [:batumi_morocco]},
      %{key: :dest_morocco, name: "Morocco Demand Cap", type: :demand_cap, destination: "Morocco",
        bound_variable: :demand_morocco_kt, routes: [:van_morocco, :batumi_morocco]},
      %{key: :dest_india, name: "India Demand Cap", type: :demand_cap, destination: "India",
        bound_variable: :demand_india_kt, routes: [:me_india]},
      %{key: :dest_china, name: "China Demand Cap", type: :demand_cap, destination: "China",
        bound_variable: :demand_china_kt, routes: [:me_china]},
      %{key: :fleet, name: "Fleet", type: :fleet_constraint,
        bound_variable: :vessel_count, routes: all_routes},
      %{key: :working_cap, name: "Working Cap", type: :capital_constraint,
        bound_variable: :working_cap, routes: all_routes}
    ]
  end

  defp api_sources do
    %{
      market_prices:   %{module: nil, variables: [:fob_vancouver, :fob_mideast, :fob_batumi, :cfr_morocco, :cfr_india, :cfr_china],
                         description: "Argus Sulphur, CRU Sulphur, ICIS"},
      ocean_freight:   %{module: nil, variables: [:fr_van_morocco, :fr_me_india, :fr_me_china, :fr_batumi_morocco],
                         description: "Baltic Exchange, Clarksons, SSY"},
      vessel_tracking: %{module: TradingDesk.Data.API.VesselTracking, variables: [],
                         description: "AIS via VesselFinder/MarineTraffic — ocean vessel tracking"},
      port_congestion: %{module: nil, variables: [:port_congestion_days],
                         description: "Port authority APIs, shipping agent reports"},
      fx_rates:        %{module: nil, variables: [:usd_inr],
                         description: "ECB/Fed exchange rate feeds"},
      bunker_fuel:     %{module: nil, variables: [:bunker_380],
                         description: "Ship & Bunker, Argus Bunker Index"},
      internal:        %{module: nil, variables: [:vessel_count, :storage_vancouver_kt, :rail_capacity_pct,
                                                   :supply_mideast_kt, :supply_batumi_kt,
                                                   :demand_morocco_kt, :demand_india_kt, :demand_china_kt,
                                                   :suez_canal_usd, :working_cap],
                         description: "Internal TMS, SAP, terminal systems"}
    }
  end

  defp signal_thresholds do
    %{
      strong_go: 500_000,   # much larger cargo sizes → higher absolute profit thresholds
      go: 250_000,
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
      "INSURANCE" => :insurance,
      "WAR_RISK_AND_ROUTE_CLOSURE" => :freight_rate,
      "DATES_WINDOWS_NOMINATIONS" => :delivery_window,
      "LOADING_DISCHARGING_RATE" => :port_congestion_days,
      "VESSEL_NOMINATION" => :vessel_count
    }
  end

  defp location_anchors do
    %{
      "vancouver" => :fob_vancouver,
      "pacific coast" => :fob_vancouver,
      "abu dhabi" => :fob_mideast,
      "ruwais" => :fob_mideast,
      "middle east" => :fob_mideast,
      "batumi" => :fob_batumi,
      "georgia" => :fob_batumi,
      "kazakhstan" => :fob_batumi,
      "jorf lasfar" => :cfr_morocco,
      "morocco" => :cfr_morocco,
      "ocp" => :cfr_morocco,
      "india" => :cfr_india,
      "mumbai" => :cfr_india,
      "paradip" => :cfr_india,
      "china" => :cfr_china,
      "nanjing" => :cfr_china
    }
  end

  defp price_anchors do
    %{
      "fob" => nil,        # needs location context
      "cfr" => nil,        # needs location context
      "cif" => nil,
      "bunker" => :bunker_380,
      "suez" => :suez_canal_usd,
      "exchange rate" => :usd_inr,
      "fx" => :usd_inr
    }
  end
end
