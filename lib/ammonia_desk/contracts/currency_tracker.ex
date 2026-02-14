defmodule AmmoniaDesk.Contracts.CurrencyTracker do
  @moduledoc """
  Tracks the currency (freshness) of every data point in the contract pipeline.

  "Current" means: every piece of data feeding into optimization was validated
  recently enough that we trust it. This module answers the question:
  "Is this contract's data still good, or does something need to be re-run?"

  Tracked timestamps per contract:
    - :parsed_at         — when clauses were last extracted from the document
    - :template_validated_at — when template completeness was last checked
    - :llm_validated_at  — when the LLM verification pass last ran
    - :sap_validated_at  — when SAP cross-check last ran
    - :position_refreshed_at — when open position was last fetched from SAP
    - :legal_reviewed_at — when legal last reviewed/approved

  Tracked timestamps per product group:
    - :full_refresh_at   — when the entire product group was last fully refreshed

  Staleness thresholds are configurable and strict. If ANY tracked timestamp
  exceeds its threshold, the contract (or product group) is marked stale.
  """

  use GenServer
  require Logger

  # Staleness thresholds in minutes
  # These are intentionally tight — the business requires current data
  @thresholds %{
    parsed_at:              60 * 24,    # 24 hours — re-parse if document changed
    template_validated_at:  60 * 24,    # 24 hours — re-validate if template changed
    llm_validated_at:       60 * 24 * 3, # 3 days — LLM check less frequent
    sap_validated_at:       60,          # 1 hour — SAP data changes frequently
    position_refreshed_at:  30,          # 30 min — positions are critical
    legal_reviewed_at:      :never_stale # legal approval doesn't expire by time
  }

  @product_group_thresholds %{
    full_refresh_at: 60 * 4  # 4 hours
  }

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # --- Public API ---

  @doc """
  Record a timestamp for a specific event on a contract.
  """
  def stamp(contract_id, event, timestamp \\ DateTime.utc_now()) do
    GenServer.call(__MODULE__, {:stamp, contract_id, event, timestamp})
  end

  @doc """
  Record a timestamp for a product group event.
  """
  def stamp_product_group(product_group, event, timestamp \\ DateTime.utc_now()) do
    GenServer.call(__MODULE__, {:stamp_pg, product_group, event, timestamp})
  end

  @doc """
  Get all timestamps for a contract.
  """
  def get_stamps(contract_id) do
    GenServer.call(__MODULE__, {:get_stamps, contract_id})
  end

  @doc """
  Check staleness of a single contract. Returns a list of stale events.
  """
  def stale_events(contract_id) do
    GenServer.call(__MODULE__, {:stale_events, contract_id})
  end

  @doc """
  Check if a contract is fully current (no stale events).
  """
  def current?(contract_id) do
    case stale_events(contract_id) do
      [] -> true
      _ -> false
    end
  end

  @doc """
  Check staleness for an entire product group.
  Returns %{contracts: %{id => [stale_events]}, product_group: [stale_events]}.
  """
  def product_group_staleness(product_group) do
    GenServer.call(__MODULE__, {:pg_staleness, product_group})
  end

  @doc """
  Is the entire product group current? Every contract + group-level timestamps.
  """
  def product_group_current?(product_group) do
    case product_group_staleness(product_group) do
      %{contracts: contracts, product_group: pg_stale} ->
        Enum.empty?(pg_stale) and
          Enum.all?(contracts, fn {_id, stale} -> Enum.empty?(stale) end)
    end
  end

  @doc """
  Full currency report for a product group — suitable for UI display.
  """
  def currency_report(product_group) do
    GenServer.call(__MODULE__, {:currency_report, product_group})
  end

  # --- GenServer ---

  @impl true
  def init(_opts) do
    table = :ets.new(:currency_tracker, [:set, :protected])
    pg_table = :ets.new(:currency_tracker_pg, [:set, :protected])
    {:ok, %{table: table, pg_table: pg_table}}
  end

  @impl true
  def handle_call({:stamp, contract_id, event, timestamp}, _from, state) do
    key = {contract_id, event}
    :ets.insert(state.table, {key, timestamp})
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:stamp_pg, product_group, event, timestamp}, _from, state) do
    key = {product_group, event}
    :ets.insert(state.pg_table, {key, timestamp})
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:get_stamps, contract_id}, _from, state) do
    stamps =
      @thresholds
      |> Map.keys()
      |> Enum.map(fn event ->
        case :ets.lookup(state.table, {contract_id, event}) do
          [{_, ts}] -> {event, ts}
          [] -> {event, nil}
        end
      end)
      |> Map.new()

    {:reply, stamps, state}
  end

  @impl true
  def handle_call({:stale_events, contract_id}, _from, state) do
    now = DateTime.utc_now()

    stale =
      @thresholds
      |> Enum.reject(fn {_event, threshold} -> threshold == :never_stale end)
      |> Enum.filter(fn {event, max_age_min} ->
        case :ets.lookup(state.table, {contract_id, event}) do
          [{_, ts}] -> DateTime.diff(now, ts, :second) > max_age_min * 60
          [] -> true  # never stamped = stale
        end
      end)
      |> Enum.map(fn {event, max_age_min} ->
        ts = case :ets.lookup(state.table, {contract_id, event}) do
          [{_, ts}] -> ts
          [] -> nil
        end
        %{
          event: event,
          last_run: ts,
          max_age_minutes: max_age_min,
          age_minutes: if(ts, do: round(DateTime.diff(now, ts, :second) / 60), else: nil)
        }
      end)

    {:reply, stale, state}
  end

  @impl true
  def handle_call({:pg_staleness, product_group}, _from, state) do
    now = DateTime.utc_now()

    # Get all contract IDs for this product group
    contract_ids = get_pg_contract_ids(state, product_group)

    contract_staleness =
      contract_ids
      |> Enum.map(fn id ->
        stale = compute_stale(state.table, id, now)
        {id, stale}
      end)
      |> Map.new()

    pg_stale =
      @product_group_thresholds
      |> Enum.filter(fn {event, max_age_min} ->
        case :ets.lookup(state.pg_table, {product_group, event}) do
          [{_, ts}] -> DateTime.diff(now, ts, :second) > max_age_min * 60
          [] -> true
        end
      end)
      |> Enum.map(fn {event, _} -> event end)

    {:reply, %{contracts: contract_staleness, product_group: pg_stale}, state}
  end

  @impl true
  def handle_call({:currency_report, product_group}, _from, state) do
    now = DateTime.utc_now()
    contract_ids = get_pg_contract_ids(state, product_group)

    contract_details =
      Enum.map(contract_ids, fn id ->
        stamps =
          @thresholds
          |> Map.keys()
          |> Enum.map(fn event ->
            case :ets.lookup(state.table, {id, event}) do
              [{_, ts}] ->
                age = round(DateTime.diff(now, ts, :second) / 60)
                threshold = Map.get(@thresholds, event)
                is_stale = threshold != :never_stale and age > threshold
                {event, %{timestamp: ts, age_minutes: age, stale: is_stale}}
              [] ->
                {event, %{timestamp: nil, age_minutes: nil, stale: true}}
            end
          end)
          |> Map.new()

        stale_count = Enum.count(stamps, fn {_k, v} -> v.stale end)
        {id, %{stamps: stamps, stale_count: stale_count, fully_current: stale_count == 0}}
      end)
      |> Map.new()

    pg_stamps =
      @product_group_thresholds
      |> Enum.map(fn {event, threshold} ->
        case :ets.lookup(state.pg_table, {product_group, event}) do
          [{_, ts}] ->
            age = round(DateTime.diff(now, ts, :second) / 60)
            {event, %{timestamp: ts, age_minutes: age, stale: age > threshold}}
          [] ->
            {event, %{timestamp: nil, age_minutes: nil, stale: true}}
        end
      end)
      |> Map.new()

    total = length(contract_ids)
    current = Enum.count(contract_details, fn {_id, d} -> d.fully_current end)

    report = %{
      product_group: product_group,
      total_contracts: total,
      fully_current: current,
      stale: total - current,
      all_current: current == total and Enum.all?(pg_stamps, fn {_, v} -> not v.stale end),
      contracts: contract_details,
      product_group_stamps: pg_stamps,
      checked_at: now
    }

    {:reply, report, state}
  end

  # --- Private ---

  defp compute_stale(table, contract_id, now) do
    @thresholds
    |> Enum.reject(fn {_event, threshold} -> threshold == :never_stale end)
    |> Enum.filter(fn {event, max_age_min} ->
      case :ets.lookup(table, {contract_id, event}) do
        [{_, ts}] -> DateTime.diff(now, ts, :second) > max_age_min * 60
        [] -> true
      end
    end)
    |> Enum.map(fn {event, _} -> event end)
  end

  defp get_pg_contract_ids(state, product_group) do
    # Look up contracts via the Store to get IDs for this product group
    contracts = AmmoniaDesk.Contracts.Store.list_by_product_group(product_group)
    Enum.map(contracts, & &1.id)
  end
end
