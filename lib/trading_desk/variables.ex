defmodule TradingDesk.Variables do
  @moduledoc """
  The 18 variables that define a scenario.
  This is the single source of truth for what a scenario looks like.
  """

  @enforce_keys [
    :river_stage, :lock_hrs, :temp_f, :wind_mph, :vis_mi, :precip_in,
    :inv_don, :inv_geis, :stl_outage, :mem_outage, :barge_count,
    :nola_buy, :sell_stl, :sell_mem,
    :fr_don_stl, :fr_don_mem, :fr_geis_stl, :fr_geis_mem,
    :nat_gas, :working_cap
  ]

  defstruct [
    # ENV (1-8) — from USGS, NOAA, USACE
    river_stage: 18.0,     # ft — USGS gauge
    lock_hrs: 12.0,        # hrs total delay — USACE
    temp_f: 45.0,          # °F — NOAA
    wind_mph: 12.0,        # mph — NOAA
    vis_mi: 5.0,           # miles — NOAA
    precip_in: 1.0,        # inches 3-day — NOAA

    # OPS (9-13) — internal systems
    inv_don: 12_000.0,     # tons — Donaldsonville terminal
    inv_geis: 8_000.0,     # tons — Geismar terminal
    stl_outage: false,     # StL dock status
    mem_outage: false,     # Memphis dock status
    barge_count: 14.0,     # available barges

    # COMMERCIAL (14-18)
    nola_buy: 320.0,       # $/ton — NH3 purchase price
    sell_stl: 410.0,       # $/ton — StL delivered
    sell_mem: 385.0,       # $/ton — Memphis delivered
    fr_don_stl: 55.0,      # $/ton freight
    fr_don_mem: 32.0,
    fr_geis_stl: 58.0,
    fr_geis_mem: 34.0,
    nat_gas: 2.80,         # $/MMBtu — EIA
    working_cap: 4_200_000.0
  ]

  @type t :: %__MODULE__{}

  @doc "Metadata for each variable — used by UI for sliders, labels, validation"
  def metadata do
    [
      %{key: :river_stage, label: "River Stage", unit: "ft", min: 2, max: 55, step: 0.1,
        source: :usgs, group: :environment},
      %{key: :lock_hrs, label: "Lock Delays", unit: "hrs", min: 0, max: 96, step: 1,
        source: :usace, group: :environment},
      %{key: :temp_f, label: "Temperature", unit: "°F", min: -20, max: 115, step: 1,
        source: :noaa, group: :environment},
      %{key: :wind_mph, label: "Wind Speed", unit: "mph", min: 0, max: 55, step: 1,
        source: :noaa, group: :environment},
      %{key: :vis_mi, label: "Visibility", unit: "mi", min: 0.05, max: 15, step: 0.1,
        source: :noaa, group: :environment},
      %{key: :precip_in, label: "Precip (3-day)", unit: "in", min: 0, max: 8, step: 0.1,
        source: :noaa, group: :environment},

      %{key: :inv_don, label: "Donaldsonville Inv", unit: "tons", min: 0, max: 15000, step: 100,
        source: :internal, group: :operations},
      %{key: :inv_geis, label: "Geismar Inv", unit: "tons", min: 0, max: 10000, step: 100,
        source: :internal, group: :operations},
      %{key: :stl_outage, label: "StL Dock Outage", unit: "", min: 0, max: 1, step: 1,
        source: :internal, group: :operations, type: :boolean},
      %{key: :mem_outage, label: "Memphis Dock Outage", unit: "", min: 0, max: 1, step: 1,
        source: :internal, group: :operations, type: :boolean},
      %{key: :barge_count, label: "Barges Available", unit: "", min: 1, max: 30, step: 1,
        source: :internal, group: :operations},

      %{key: :nola_buy, label: "NH3 NOLA Buy", unit: "$/t", min: 200, max: 600, step: 5,
        source: :market, group: :commercial},
      %{key: :sell_stl, label: "NH3 StL Delivered", unit: "$/t", min: 300, max: 600, step: 5,
        source: :market, group: :commercial},
      %{key: :sell_mem, label: "NH3 Memphis Delivered", unit: "$/t", min: 280, max: 550, step: 5,
        source: :market, group: :commercial},
      %{key: :fr_don_stl, label: "Freight Don→StL", unit: "$/t", min: 20, max: 130, step: 1,
        source: :broker, group: :commercial},
      %{key: :fr_don_mem, label: "Freight Don→Mem", unit: "$/t", min: 10, max: 80, step: 1,
        source: :broker, group: :commercial},
      %{key: :fr_geis_stl, label: "Freight Geis→StL", unit: "$/t", min: 20, max: 135, step: 1,
        source: :broker, group: :commercial},
      %{key: :fr_geis_mem, label: "Freight Geis→Mem", unit: "$/t", min: 10, max: 85, step: 1,
        source: :broker, group: :commercial},
      %{key: :nat_gas, label: "Nat Gas (Henry Hub)", unit: "$/MMBtu", min: 1.0, max: 8.0, step: 0.05,
        source: :eia, group: :commercial},
      %{key: :working_cap, label: "Working Capital", unit: "$", min: 500_000, max: 10_000_000, step: 100_000,
        source: :internal, group: :commercial}
    ]
  end

  @doc "Pack into binary for Zig port"
  def to_binary(%__MODULE__{} = v) do
    <<
      v.river_stage::float-little-64,
      v.lock_hrs::float-little-64,
      v.temp_f::float-little-64,
      v.wind_mph::float-little-64,
      v.vis_mi::float-little-64,
      v.precip_in::float-little-64,
      v.inv_don::float-little-64,
      v.inv_geis::float-little-64,
      (if v.stl_outage, do: 1.0, else: 0.0)::float-little-64,
      (if v.mem_outage, do: 1.0, else: 0.0)::float-little-64,
      v.barge_count::float-little-64,
      v.nola_buy::float-little-64,
      v.sell_stl::float-little-64,
      v.sell_mem::float-little-64,
      v.fr_don_stl::float-little-64,
      v.fr_don_mem::float-little-64,
      v.fr_geis_stl::float-little-64,
      v.fr_geis_mem::float-little-64,
      v.nat_gas::float-little-64,
      v.working_cap::float-little-64
    >>
  end
end
