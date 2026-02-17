defmodule AmmoniaDesk.ProductGroup.Frames.AmmoniaInternational do
  @moduledoc """
  Solver frame for international ammonia ocean trading.

  Trammo is the world's largest ammonia buyer, purchasing through long-term
  or spot agreements in 25 countries and selling in nearly 35 countries.
  This frame covers ocean vessel (refrigerated) ammonia trading.

  ## Transport
  Specialized refrigerated ocean vessels (ammonia carriers).

  ## Key Origins
  - Trinidad & Tobago (Caribbean — largest Western Hemisphere producer)
  - Saudi Arabia (Ma'aden, SABIC — Middle East hub)
  - Russia/Ukraine (Black Sea — Yuzhnyy/Odessa)
  - Indonesia (Kaltim, East Java)
  - Algeria (North Africa)

  ## Key Destinations
  - US Gulf/Tampa (direct application + industrial)
  - India (fertilizer feedstock)
  - Morocco (phosphate production — OCP)
  - South Korea (industrial + power)
  - Europe (Spain, Belgium — Trammo green ammonia initiative)

  ## Variables (18)
  Market (6): FOB prices at 3 origins, CFR prices at 3 destinations
  Freight (4): Charter rates on 4 key trade lanes
  Operations (4): Vessel availability, terminal storage, plant utilization, tank levels
  Macro (4): Nat gas feedstock, bunker fuel, FX (EUR/USD), working capital
  """

  @behaviour AmmoniaDesk.ProductGroup.Frame

  @impl true
  def frame do
    %{
      id: :ammonia_international,
      name: "NH3 International",
      product: "Anhydrous Ammonia (Refrigerated)",
      transport_mode: :ocean_vessel,
      geography: "Global — Trinidad, ME, Black Sea → Tampa, India, Morocco, Europe",

      variables: variables(),
      routes: routes(),
      constraints: constraints(),
      api_sources: api_sources(),
      signal_thresholds: signal_thresholds(),
      contract_term_map: contract_term_map(),
      location_anchors: location_anchors(),
      price_anchors: price_anchors(),
      product_patterns: [~r/\banhydrous\s+ammonia\b/i, ~r/\bNH3\b/, ~r/\bammonia\b/i, ~r/\brefrigerated\s+ammonia\b/i],
      chain_magic: "NH3\x02",
      chain_product_code: 0x02,

      default_poll_intervals: %{
        market_prices:    :timer.minutes(30),
        ocean_freight:    :timer.hours(1),
        vessel_tracking:  :timer.minutes(15),
        nat_gas:          :timer.hours(2),
        fx_rates:         :timer.minutes(30),
        bunker_fuel:      :timer.hours(1),
        internal:         :timer.minutes(10)
      },

      solver_binary: "solver_ammonia_intl"
    }
  end

  defp variables do
    [
      # ── MARKET PRICES ──
      %{key: :fob_trinidad, label: "FOB Trinidad", unit: "$/t", min: 150, max: 700, step: 5,
        default: 350.0, source: :market_prices, group: :market, type: :float, delta_threshold: 5.0,
        perturbation: %{stddev: 15.0, min: 150, max: 700}},
      %{key: :fob_yuzhnyy, label: "FOB Yuzhnyy", unit: "$/t", min: 150, max: 700, step: 5,
        default: 320.0, source: :market_prices, group: :market, type: :float, delta_threshold: 5.0,
        perturbation: %{stddev: 15.0, min: 150, max: 700}},
      %{key: :fob_mideast, label: "FOB ME (Saudi)", unit: "$/t", min: 150, max: 700, step: 5,
        default: 310.0, source: :market_prices, group: :market, type: :float, delta_threshold: 5.0,
        perturbation: %{stddev: 15.0, min: 150, max: 700}},
      %{key: :cfr_tampa, label: "CFR Tampa", unit: "$/t", min: 200, max: 800, step: 5,
        default: 420.0, source: :market_prices, group: :market, type: :float, delta_threshold: 5.0,
        perturbation: %{stddev: 18.0, min: 200, max: 800}},
      %{key: :cfr_india, label: "CFR India", unit: "$/t", min: 200, max: 750, step: 5,
        default: 380.0, source: :market_prices, group: :market, type: :float, delta_threshold: 5.0,
        perturbation: %{stddev: 15.0, min: 200, max: 750}},
      %{key: :cfr_morocco, label: "CFR Morocco", unit: "$/t", min: 200, max: 750, step: 5,
        default: 370.0, source: :market_prices, group: :market, type: :float, delta_threshold: 5.0,
        perturbation: %{stddev: 15.0, min: 200, max: 750}},

      # ── OCEAN FREIGHT ──
      %{key: :fr_trinidad_tampa, label: "Freight Trinidad→Tampa", unit: "$/t", min: 15, max: 80, step: 1,
        default: 30.0, source: :ocean_freight, group: :freight, type: :float, delta_threshold: 2.0,
        perturbation: %{stddev: 5.0, min: 15, max: 80}},
      %{key: :fr_yuzhnyy_morocco, label: "Freight Yuzhnyy→Morocco", unit: "$/t", min: 20, max: 90, step: 1,
        default: 40.0, source: :ocean_freight, group: :freight, type: :float, delta_threshold: 3.0,
        perturbation: %{stddev: 6.0, min: 20, max: 90}},
      %{key: :fr_me_india, label: "Freight ME→India", unit: "$/t", min: 15, max: 70, step: 1,
        default: 28.0, source: :ocean_freight, group: :freight, type: :float, delta_threshold: 2.0,
        perturbation: %{stddev: 4.0, min: 15, max: 70}},
      %{key: :fr_trinidad_india, label: "Freight Trinidad→India", unit: "$/t", min: 35, max: 120, step: 1,
        default: 65.0, source: :ocean_freight, group: :freight, type: :float, delta_threshold: 4.0,
        perturbation: %{stddev: 8.0, min: 35, max: 120}},

      # ── OPERATIONS ──
      %{key: :vessel_count, label: "NH3 Carriers Available", unit: "", min: 0, max: 10, step: 1,
        default: 3.0, source: :internal, group: :operations, type: :float, delta_threshold: 1.0,
        perturbation: %{stddev: 1.0, min: 0, max: 10}},
      %{key: :storage_tampa_kt, label: "Tampa Terminal Storage", unit: "kt", min: 0, max: 100, step: 5,
        default: 35.0, source: :internal, group: :operations, type: :float, delta_threshold: 5.0,
        perturbation: %{stddev: 8.0, min: 0, max: 100}},
      %{key: :plant_utilization_pct, label: "Supplier Plant Util", unit: "%", min: 50, max: 100, step: 1,
        default: 88.0, source: :internal, group: :operations, type: :float, delta_threshold: 3.0,
        perturbation: %{stddev: 5.0, min: 50, max: 100}},
      %{key: :tank_level_pct, label: "Dest Tank Levels", unit: "%", min: 0, max: 100, step: 1,
        default: 60.0, source: :internal, group: :operations, type: :float, delta_threshold: 5.0,
        perturbation: %{stddev: 8.0, min: 0, max: 100}},

      # ── MACRO ──
      %{key: :nat_gas_feedstock, label: "Nat Gas (feedstock proxy)", unit: "$/MMBtu", min: 1, max: 12, step: 0.1,
        default: 3.50, source: :nat_gas, group: :macro, type: :float, delta_threshold: 0.2,
        perturbation: %{stddev: 0.5, min: 1, max: 12}},
      %{key: :bunker_380, label: "Bunker 380cSt", unit: "$/t", min: 200, max: 800, step: 5,
        default: 480.0, source: :bunker_fuel, group: :macro, type: :float, delta_threshold: 10.0,
        perturbation: %{stddev: 20.0, min: 200, max: 800}},
      %{key: :eur_usd, label: "EUR/USD", unit: "", min: 0.8, max: 1.3, step: 0.01,
        default: 1.08, source: :fx_rates, group: :macro, type: :float, delta_threshold: 0.01,
        perturbation: %{stddev: 0.02, min: 0.8, max: 1.3}},
      %{key: :working_cap, label: "Working Capital", unit: "$M", min: 5, max: 200, step: 5,
        default: 50.0, source: :internal, group: :macro, type: :float, delta_threshold: 5.0,
        perturbation: %{stddev: 8.0, min: 5, max: 200}}
    ]
  end

  defp routes do
    [
      %{key: :trinidad_tampa, name: "Trinidad → Tampa", origin: "Point Lisas, Trinidad",
        destination: "Tampa, FL", distance_nm: 1800,
        transport_mode: :ocean_vessel, freight_variable: :fr_trinidad_tampa,
        sell_variable: :cfr_tampa, typical_transit_days: 5},
      %{key: :yuzhnyy_morocco, name: "Yuzhnyy → Morocco", origin: "Yuzhnyy, Ukraine",
        destination: "Jorf Lasfar, Morocco", distance_nm: 3500,
        transport_mode: :ocean_vessel, freight_variable: :fr_yuzhnyy_morocco,
        sell_variable: :cfr_morocco, typical_transit_days: 10},
      %{key: :me_india, name: "ME → India", origin: "Jubail, Saudi Arabia",
        destination: "Paradip/Mumbai, India", distance_nm: 2200,
        transport_mode: :ocean_vessel, freight_variable: :fr_me_india,
        sell_variable: :cfr_india, typical_transit_days: 7},
      %{key: :trinidad_india, name: "Trinidad → India", origin: "Point Lisas, Trinidad",
        destination: "Paradip/Mumbai, India", distance_nm: 10_000,
        transport_mode: :ocean_vessel, freight_variable: :fr_trinidad_india,
        sell_variable: :cfr_india, typical_transit_days: 30}
    ]
  end

  defp constraints do
    [
      %{key: :supply_trinidad, name: "Trinidad Supply", type: :supply, terminal: "Trinidad"},
      %{key: :supply_yuzhnyy, name: "Yuzhnyy Supply", type: :supply, terminal: "Yuzhnyy"},
      %{key: :supply_mideast, name: "ME Supply", type: :supply, terminal: "Middle East"},
      %{key: :dest_tampa, name: "Tampa Demand", type: :demand_cap, destination: "Tampa"},
      %{key: :dest_india, name: "India Demand", type: :demand_cap, destination: "India"},
      %{key: :dest_morocco, name: "Morocco Demand", type: :demand_cap, destination: "Morocco"},
      %{key: :fleet, name: "Fleet", type: :fleet_constraint},
      %{key: :working_cap, name: "Working Cap", type: :capital_constraint}
    ]
  end

  defp api_sources do
    %{
      market_prices:   %{module: nil, variables: [:fob_trinidad, :fob_yuzhnyy, :fob_mideast, :cfr_tampa, :cfr_india, :cfr_morocco],
                         description: "Argus Ammonia, ICIS, Fertecon"},
      ocean_freight:   %{module: nil, variables: [:fr_trinidad_tampa, :fr_yuzhnyy_morocco, :fr_me_india, :fr_trinidad_india],
                         description: "Baltic Exchange, Clarksons, NH3 broker market"},
      vessel_tracking: %{module: AmmoniaDesk.Data.API.VesselTracking, variables: [],
                         description: "AIS — NH3 refrigerated carrier fleet"},
      nat_gas:         %{module: AmmoniaDesk.Data.API.EIA, variables: [:nat_gas_feedstock],
                         description: "Henry Hub + international gas benchmarks"},
      fx_rates:        %{module: nil, variables: [:eur_usd],
                         description: "ECB/Fed exchange rate feeds"},
      bunker_fuel:     %{module: nil, variables: [:bunker_380],
                         description: "Ship & Bunker, Argus Bunker Index"},
      internal:        %{module: nil, variables: [:vessel_count, :storage_tampa_kt, :plant_utilization_pct, :tank_level_pct, :working_cap],
                         description: "Internal TMS, terminal gauges, SAP"}
    }
  end

  defp signal_thresholds do
    %{
      strong_go: 300_000,
      go: 150_000,
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
      "VESSEL_NOMINATION" => :vessel_count
    }
  end

  defp location_anchors do
    %{
      "trinidad" => :fob_trinidad,
      "point lisas" => :fob_trinidad,
      "yuzhnyy" => :fob_yuzhnyy,
      "odessa" => :fob_yuzhnyy,
      "black sea" => :fob_yuzhnyy,
      "saudi" => :fob_mideast,
      "jubail" => :fob_mideast,
      "middle east" => :fob_mideast,
      "tampa" => :cfr_tampa,
      "india" => :cfr_india,
      "paradip" => :cfr_india,
      "morocco" => :cfr_morocco,
      "jorf lasfar" => :cfr_morocco
    }
  end

  defp price_anchors do
    %{
      "fob" => nil,
      "cfr" => nil,
      "cif" => nil,
      "bunker" => :bunker_380,
      "natural gas" => :nat_gas_feedstock,
      "henry hub" => :nat_gas_feedstock,
      "exchange rate" => :eur_usd
    }
  end
end
