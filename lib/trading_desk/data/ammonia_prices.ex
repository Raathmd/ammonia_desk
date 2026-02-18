defmodule TradingDesk.Data.AmmoniaPrices do
  @moduledoc """
  Ammonia pricing data — benchmark assessments from industry sources.

  In production, pulls from:
    - Fertecon/CRU ammonia weekly assessments
    - FMB/Argus ammonia weekly
    - Profercy World Nitrogen Index
    - ICIS pricing service

  Current seeded data represents Feb 2026 market levels.
  Prices are in USD per metric ton at the named delivery point.

  The solver uses these to validate contract prices against the market
  and to set default commercial variables when live feed isn't available.
  """

  use GenServer
  require Logger

  @refresh_interval :timer.minutes(15)

  # Seeded benchmark prices — Feb 2026 market levels
  @benchmarks %{
    # FOB benchmarks (where the product is loaded)
    fob_yuzhnyy: %{
      price: 295.0,
      currency: :usd,
      unit: "$/MT",
      point: "FOB Yuzhnyy",
      source: "Fertecon",
      updated_at: ~U[2026-02-18 06:00:00Z]
    },
    fob_middle_east: %{
      price: 320.0,
      currency: :usd,
      unit: "$/MT",
      point: "FOB Middle East (AG)",
      source: "Fertecon",
      updated_at: ~U[2026-02-18 06:00:00Z]
    },
    fob_trinidad: %{
      price: 345.0,
      currency: :usd,
      unit: "$/MT",
      point: "FOB Trinidad/Caribbean",
      source: "FMB",
      updated_at: ~U[2026-02-18 06:00:00Z]
    },
    fob_nola: %{
      price: 380.0,
      currency: :usd,
      unit: "$/MT",
      point: "FOB NOLA barge",
      source: "Fertecon",
      updated_at: ~U[2026-02-18 06:00:00Z]
    },
    # CFR benchmarks (cost + freight to delivery port)
    cfr_tampa: %{
      price: 420.0,
      currency: :usd,
      unit: "$/MT",
      point: "CFR Tampa",
      source: "Fertecon",
      updated_at: ~U[2026-02-18 06:00:00Z]
    },
    cfr_india: %{
      price: 375.0,
      currency: :usd,
      unit: "$/MT",
      point: "CFR India (West Coast)",
      source: "FMB",
      updated_at: ~U[2026-02-18 06:00:00Z]
    },
    cfr_nwe: %{
      price: 410.0,
      currency: :usd,
      unit: "$/MT",
      point: "CFR NW Europe",
      source: "Fertecon",
      updated_at: ~U[2026-02-18 06:00:00Z]
    },
    cfr_morocco: %{
      price: 390.0,
      currency: :usd,
      unit: "$/MT",
      point: "CFR Morocco",
      source: "FMB",
      updated_at: ~U[2026-02-18 06:00:00Z]
    },
    # Domestic US benchmarks
    nola_barge: %{
      price: 385.0,
      currency: :usd,
      unit: "$/ST",
      point: "NOLA barge (short ton)",
      source: "Fertecon",
      updated_at: ~U[2026-02-18 06:00:00Z]
    },
    corn_belt: %{
      price: 520.0,
      currency: :usd,
      unit: "$/ST",
      point: "Corn Belt retail",
      source: "DTN/Fertecon",
      updated_at: ~U[2026-02-18 06:00:00Z]
    },
    # Index references
    tampa_cfr_index: %{
      price: 425.0,
      currency: :usd,
      unit: "$/MT",
      point: "Tampa CFR (contract reference)",
      source: "Fertecon/FMB average",
      updated_at: ~U[2026-02-18 06:00:00Z]
    }
  }

  # Freight rates for key routes (USD/MT)
  @freight_rates %{
    trinidad_to_tampa: 22.0,
    mideast_to_india: 35.0,
    mideast_to_tampa: 45.0,
    yuzhnyy_to_morocco: 18.0,
    yuzhnyy_to_nwe: 22.0,
    trinidad_to_nwe: 38.0
  }

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  # ── Public API ─────────────────────────────────────────────

  @doc "Get all benchmark prices"
  def benchmarks do
    GenServer.call(__MODULE__, :benchmarks)
  catch
    :exit, _ -> @benchmarks
  end

  @doc "Get a specific benchmark by key"
  def get(benchmark_key) do
    Map.get(benchmarks(), benchmark_key)
  end

  @doc "Get the NOLA buy price (used as solver default for nola_buy)"
  def nola_buy_price do
    case get(:fob_nola) do
      %{price: p} -> p
      _ -> 380.0
    end
  end

  @doc "Get the Tampa CFR index price"
  def tampa_cfr_price do
    case get(:tampa_cfr_index) do
      %{price: p} -> p
      _ -> 425.0
    end
  end

  @doc "Get all freight rates"
  def freight_rates, do: @freight_rates

  @doc """
  Get a compact summary for display in the UI.
  Returns list of %{key, label, price, source, direction}.
  """
  def price_summary do
    [
      %{key: :fob_nola, label: "NOLA Barge", price: price_for(:fob_nola), source: "Fertecon", direction: :buy},
      %{key: :fob_trinidad, label: "FOB Trinidad", price: price_for(:fob_trinidad), source: "FMB", direction: :buy},
      %{key: :fob_middle_east, label: "FOB Mid East", price: price_for(:fob_middle_east), source: "Fertecon", direction: :buy},
      %{key: :fob_yuzhnyy, label: "FOB Yuzhnyy", price: price_for(:fob_yuzhnyy), source: "Fertecon", direction: :buy},
      %{key: :cfr_tampa, label: "CFR Tampa", price: price_for(:cfr_tampa), source: "Fertecon", direction: :sell},
      %{key: :cfr_india, label: "CFR India", price: price_for(:cfr_india), source: "FMB", direction: :sell},
      %{key: :cfr_nwe, label: "CFR NW Europe", price: price_for(:cfr_nwe), source: "Fertecon", direction: :sell},
      %{key: :cfr_morocco, label: "CFR Morocco", price: price_for(:cfr_morocco), source: "FMB", direction: :sell}
    ]
  end

  @doc "Get the latest update timestamp across all benchmarks"
  def last_updated do
    benchmarks()
    |> Map.values()
    |> Enum.map(& &1.updated_at)
    |> Enum.max(DateTime, fn -> ~U[2026-01-01 00:00:00Z] end)
  end

  # ── GenServer ─────────────────────────────────────────────

  @impl true
  def init(_) do
    # Schedule periodic refresh
    Process.send_after(self(), :refresh, @refresh_interval)
    {:ok, %{prices: @benchmarks, freight: @freight_rates}}
  end

  @impl true
  def handle_call(:benchmarks, _from, state) do
    {:reply, state.prices, state}
  end

  @impl true
  def handle_info(:refresh, state) do
    # TODO: Pull from live pricing API
    # For now, just reschedule
    Process.send_after(self(), :refresh, @refresh_interval)
    {:noreply, state}
  end

  defp price_for(key) do
    case Map.get(@benchmarks, key) do
      %{price: p} -> p
      _ -> 0.0
    end
  end
end
