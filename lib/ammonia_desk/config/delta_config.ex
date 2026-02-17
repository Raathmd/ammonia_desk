defmodule AmmoniaDesk.Config.DeltaConfig do
  @moduledoc """
  Admin-configurable delta thresholds and poll intervals per product group.

  The auto-trader only re-solves when a variable's delta exceeds its configured
  threshold. Admins configure per product group:

    - Poll intervals per API source (how often to check each API)
    - Delta thresholds per variable (how much change triggers a re-solve)
    - Cooldown interval (minimum time between auto-solves)
    - Whether the product group's auto-solver is enabled

  Config changes are persisted to Postgres and broadcast via PubSub so the
  Poller and AutoRunner pick up changes immediately.

  ## Usage

      # Get current config for ammonia
      DeltaConfig.get(:ammonia)

      # Admin updates a threshold
      DeltaConfig.update(:ammonia, :thresholds, %{nola_buy: 1.0})

      # Admin changes poll interval for USGS
      DeltaConfig.update(:ammonia, :poll_intervals, %{usgs: :timer.minutes(10)})

      # Disable auto-solving for a product group
      DeltaConfig.update(:ammonia, :enabled, false)
  """

  use GenServer
  require Logger

  @pubsub AmmoniaDesk.PubSub
  @topic "delta_config"

  # ──────────────────────────────────────────────────────────
  # DEFAULTS
  # ──────────────────────────────────────────────────────────

  @default_configs %{
    ammonia: %{
      enabled: true,
      product_group: :ammonia,

      # Per-source poll intervals (ms)
      poll_intervals: %{
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

      # Per-variable delta thresholds (absolute value)
      # A new solve is triggered when |current - baseline| > threshold
      thresholds: %{
        river_stage:  0.5,        # ft
        lock_hrs:     2.0,        # hrs
        temp_f:       5.0,        # degF
        wind_mph:     3.0,        # mph
        vis_mi:       1.0,        # miles
        precip_in:    0.5,        # inches
        inv_don:      500.0,      # tons
        inv_geis:     500.0,      # tons
        stl_outage:   0.5,        # boolean flip (any change triggers)
        mem_outage:   0.5,        # boolean flip
        barge_count:  1.0,        # barges
        nola_buy:     2.0,        # $/ton
        sell_stl:     2.0,        # $/ton
        sell_mem:     2.0,        # $/ton
        fr_don_stl:   1.0,        # $/ton
        fr_don_mem:   1.0,        # $/ton
        fr_geis_stl:  1.0,        # $/ton
        fr_geis_mem:  1.0,        # $/ton
        nat_gas:      0.10,       # $/MMBtu
        working_cap:  100_000.0   # $
      },

      # Minimum time between auto-solves (prevents rapid-fire during volatility)
      min_solve_interval_ms: :timer.minutes(5),

      # Monte Carlo scenario count for auto-solves
      n_scenarios: 1000
    },

    uan: %{
      enabled: false,
      product_group: :uan,
      poll_intervals: %{
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
      thresholds: %{
        river_stage: 0.5, lock_hrs: 2.0, temp_f: 5.0, wind_mph: 3.0,
        vis_mi: 1.0, precip_in: 0.5, inv_don: 500.0, inv_geis: 500.0,
        stl_outage: 0.5, mem_outage: 0.5, barge_count: 1.0,
        nola_buy: 2.0, sell_stl: 2.0, sell_mem: 2.0,
        fr_don_stl: 1.0, fr_don_mem: 1.0, fr_geis_stl: 1.0, fr_geis_mem: 1.0,
        nat_gas: 0.10, working_cap: 100_000.0
      },
      min_solve_interval_ms: :timer.minutes(5),
      n_scenarios: 1000
    },

    urea: %{
      enabled: false,
      product_group: :urea,
      poll_intervals: %{
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
      thresholds: %{
        river_stage: 0.5, lock_hrs: 2.0, temp_f: 5.0, wind_mph: 3.0,
        vis_mi: 1.0, precip_in: 0.5, inv_don: 500.0, inv_geis: 500.0,
        stl_outage: 0.5, mem_outage: 0.5, barge_count: 1.0,
        nola_buy: 2.0, sell_stl: 2.0, sell_mem: 2.0,
        fr_don_stl: 1.0, fr_don_mem: 1.0, fr_geis_stl: 1.0, fr_geis_mem: 1.0,
        nat_gas: 0.10, working_cap: 100_000.0
      },
      min_solve_interval_ms: :timer.minutes(5),
      n_scenarios: 1000
    },

    sulphur_international: %{
      enabled: false,
      product_group: :sulphur_international,
      poll_intervals: %{
        market_prices:    :timer.minutes(30),
        ocean_freight:    :timer.hours(1),
        vessel_tracking:  :timer.minutes(15),
        nat_gas:          :timer.hours(2),
        fx_rates:         :timer.minutes(30),
        bunker_fuel:      :timer.hours(1),
        internal:         :timer.minutes(10)
      },
      thresholds: AmmoniaDesk.ProductGroup.default_thresholds(:sulphur_international),
      min_solve_interval_ms: :timer.minutes(5),
      n_scenarios: 1000
    },

    ammonia_international: %{
      enabled: false,
      product_group: :ammonia_international,
      poll_intervals: %{
        market_prices:    :timer.minutes(30),
        ocean_freight:    :timer.hours(1),
        vessel_tracking:  :timer.minutes(15),
        nat_gas:          :timer.hours(2),
        fx_rates:         :timer.minutes(30),
        bunker_fuel:      :timer.hours(1),
        internal:         :timer.minutes(10)
      },
      thresholds: AmmoniaDesk.ProductGroup.default_thresholds(:ammonia_international),
      min_solve_interval_ms: :timer.minutes(5),
      n_scenarios: 1000
    },

    petcoke: %{
      enabled: false,
      product_group: :petcoke,
      poll_intervals: %{
        market_prices:    :timer.minutes(30),
        ocean_freight:    :timer.hours(1),
        vessel_tracking:  :timer.minutes(15),
        nat_gas:          :timer.hours(2),
        internal:         :timer.minutes(10)
      },
      thresholds: AmmoniaDesk.ProductGroup.default_thresholds(:petcoke),
      min_solve_interval_ms: :timer.minutes(5),
      n_scenarios: 1000
    }
  }

  # Legacy variable indices for backward compat (ammonia domestic)
  @legacy_variable_indices %{
    river_stage: 0, lock_hrs: 1, temp_f: 2, wind_mph: 3, vis_mi: 4,
    precip_in: 5, inv_don: 6, inv_geis: 7, stl_outage: 8, mem_outage: 9,
    barge_count: 10, nola_buy: 11, sell_stl: 12, sell_mem: 13,
    fr_don_stl: 14, fr_don_mem: 15, fr_geis_stl: 16, fr_geis_mem: 17,
    nat_gas: 18, working_cap: 19
  }

  # ──────────────────────────────────────────────────────────
  # PUBLIC API
  # ──────────────────────────────────────────────────────────

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @doc "Get delta config for a product group."
  @spec get(atom()) :: map()
  def get(product_group) do
    GenServer.call(__MODULE__, {:get, product_group})
  end

  @doc "Get all product group configs."
  @spec all() :: map()
  def all do
    GenServer.call(__MODULE__, :all)
  end

  @doc "Get the poll interval for a specific source in a product group."
  @spec poll_interval(atom(), atom()) :: non_neg_integer()
  def poll_interval(product_group, source) do
    config = get(product_group)
    get_in(config, [:poll_intervals, source]) || :timer.minutes(15)
  end

  @doc "Get the threshold for a specific variable in a product group."
  @spec threshold(atom(), atom()) :: float()
  def threshold(product_group, variable) do
    config = get(product_group)
    get_in(config, [:thresholds, variable]) || 1.0
  end

  @doc "Get variable index for bitmask encoding."
  @spec variable_index(atom()) :: non_neg_integer()
  def variable_index(key), do: Map.get(@legacy_variable_indices, key, 0)

  @doc "Get variable index for a specific product group."
  @spec variable_index(atom(), atom()) :: non_neg_integer()
  def variable_index(key, product_group) do
    indices = AmmoniaDesk.ProductGroup.variable_indices(product_group)
    Map.get(indices, key, 0)
  end

  @doc "Get variable key from bitmask index."
  @spec variable_from_index(non_neg_integer()) :: atom()
  def variable_from_index(index) do
    @legacy_variable_indices
    |> Enum.find(fn {_k, v} -> v == index end)
    |> case do
      {k, _} -> k
      nil -> :unknown
    end
  end

  @doc "Get variable key from bitmask index for a specific product group."
  @spec variable_from_index(non_neg_integer(), atom()) :: atom()
  def variable_from_index(index, product_group) do
    keys = AmmoniaDesk.ProductGroup.variable_keys(product_group)
    Enum.at(keys, index, :unknown)
  end

  @doc """
  Update a config field for a product group.

  Supported fields:
    - :enabled (boolean)
    - :thresholds (map of variable => threshold)
    - :poll_intervals (map of source => interval_ms)
    - :min_solve_interval_ms (integer)
    - :n_scenarios (integer)
  """
  @spec update(atom(), atom(), term()) :: :ok | {:error, term()}
  def update(product_group, field, value) do
    GenServer.call(__MODULE__, {:update, product_group, field, value})
  end

  @doc "Replace entire config for a product group."
  @spec set(atom(), map()) :: :ok
  def set(product_group, config) do
    GenServer.call(__MODULE__, {:set, product_group, config})
  end

  @doc "Get the merged poll intervals across all enabled product groups (shortest wins)."
  @spec effective_poll_intervals() :: map()
  def effective_poll_intervals do
    GenServer.call(__MODULE__, :effective_poll_intervals)
  end

  # ──────────────────────────────────────────────────────────
  # GENSERVER
  # ──────────────────────────────────────────────────────────

  @impl true
  def init(_) do
    # Load from Postgres if available, otherwise use defaults
    configs = load_persisted_configs()
    {:ok, %{configs: configs}}
  end

  @impl true
  def handle_call({:get, product_group}, _from, state) do
    config = Map.get(state.configs, product_group, %{enabled: false, product_group: product_group})
    {:reply, config, state}
  end

  @impl true
  def handle_call(:all, _from, state) do
    {:reply, state.configs, state}
  end

  @impl true
  def handle_call(:effective_poll_intervals, _from, state) do
    intervals =
      state.configs
      |> Enum.filter(fn {_pg, config} -> config[:enabled] end)
      |> Enum.flat_map(fn {_pg, config} -> Map.to_list(config[:poll_intervals] || %{}) end)
      |> Enum.group_by(fn {source, _} -> source end, fn {_, interval} -> interval end)
      |> Enum.map(fn {source, intervals} -> {source, Enum.min(intervals)} end)
      |> Map.new()

    {:reply, intervals, state}
  end

  @impl true
  def handle_call({:update, product_group, field, value}, _from, state) do
    case do_update(state.configs, product_group, field, value) do
      {:ok, new_configs} ->
        persist_config(product_group, new_configs[product_group])

        broadcast(:config_updated, %{
          product_group: product_group,
          field: field,
          value: value,
          config: new_configs[product_group]
        })

        Logger.info("DeltaConfig: #{product_group}.#{field} updated")
        {:reply, :ok, %{state | configs: new_configs}}

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  @impl true
  def handle_call({:set, product_group, config}, _from, state) do
    config = Map.put(config, :product_group, product_group)
    new_configs = Map.put(state.configs, product_group, config)

    persist_config(product_group, config)

    broadcast(:config_replaced, %{
      product_group: product_group,
      config: config
    })

    Logger.info("DeltaConfig: #{product_group} config replaced")
    {:reply, :ok, %{state | configs: new_configs}}
  end

  # ──────────────────────────────────────────────────────────
  # INTERNAL
  # ──────────────────────────────────────────────────────────

  defp do_update(configs, product_group, field, value) do
    config = Map.get(configs, product_group, @default_configs[product_group] || %{})

    case field do
      :enabled when is_boolean(value) ->
        {:ok, Map.put(configs, product_group, Map.put(config, :enabled, value))}

      :thresholds when is_map(value) ->
        existing = config[:thresholds] || %{}
        merged = Map.merge(existing, value)
        {:ok, Map.put(configs, product_group, Map.put(config, :thresholds, merged))}

      :poll_intervals when is_map(value) ->
        existing = config[:poll_intervals] || %{}
        merged = Map.merge(existing, value)
        {:ok, Map.put(configs, product_group, Map.put(config, :poll_intervals, merged))}

      :min_solve_interval_ms when is_integer(value) ->
        {:ok, Map.put(configs, product_group, Map.put(config, :min_solve_interval_ms, value))}

      :n_scenarios when is_integer(value) and value > 0 ->
        {:ok, Map.put(configs, product_group, Map.put(config, :n_scenarios, value))}

      _ ->
        {:error, {:invalid_field, field}}
    end
  end

  defp load_persisted_configs do
    # Try loading from Postgres; fall back to defaults
    try do
      case AmmoniaDesk.Repo.all(AmmoniaDesk.DB.DeltaConfigRecord) do
        [] ->
          @default_configs

        records ->
          Enum.reduce(records, @default_configs, fn record, acc ->
            pg = String.to_existing_atom(record.product_group)
            config = deserialize_config(record)
            Map.put(acc, pg, config)
          end)
      end
    rescue
      _ -> @default_configs
    end
  end

  defp persist_config(product_group, config) do
    Task.Supervisor.start_child(
      AmmoniaDesk.Contracts.TaskSupervisor,
      fn -> do_persist_config(product_group, config) end
    )
  end

  defp do_persist_config(product_group, config) do
    attrs = %{
      product_group: to_string(product_group),
      enabled: config[:enabled] || false,
      poll_intervals: serialize_intervals(config[:poll_intervals] || %{}),
      thresholds: config[:thresholds] || %{},
      min_solve_interval_ms: config[:min_solve_interval_ms] || :timer.minutes(5),
      n_scenarios: config[:n_scenarios] || 1000
    }

    %AmmoniaDesk.DB.DeltaConfigRecord{}
    |> AmmoniaDesk.DB.DeltaConfigRecord.changeset(attrs)
    |> AmmoniaDesk.Repo.insert(
      on_conflict: {:replace_all_except, [:product_group, :inserted_at]},
      conflict_target: :product_group
    )
    |> case do
      {:ok, _} ->
        Logger.debug("DB: delta config for #{product_group} persisted")

      {:error, changeset} ->
        Logger.warning("DB: failed to persist delta config: #{inspect(changeset.errors)}")
    end
  rescue
    e -> Logger.warning("DB: delta config persist error: #{inspect(e)}")
  end

  defp serialize_intervals(intervals) do
    Map.new(intervals, fn {k, v} -> {to_string(k), v} end)
  end

  defp deserialize_config(record) do
    %{
      enabled: record.enabled,
      product_group: String.to_existing_atom(record.product_group),
      poll_intervals: deserialize_intervals(record.poll_intervals || %{}),
      thresholds: deserialize_thresholds(record.thresholds || %{}),
      min_solve_interval_ms: record.min_solve_interval_ms || :timer.minutes(5),
      n_scenarios: record.n_scenarios || 1000
    }
  end

  defp deserialize_intervals(intervals) do
    Map.new(intervals, fn {k, v} -> {String.to_existing_atom(k), v} end)
  end

  defp deserialize_thresholds(thresholds) do
    Map.new(thresholds, fn {k, v} -> {String.to_existing_atom(k), v} end)
  end

  defp broadcast(event, payload) do
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:delta_config, event, payload})
  end
end
