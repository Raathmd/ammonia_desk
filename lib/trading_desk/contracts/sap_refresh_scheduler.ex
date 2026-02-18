defmodule TradingDesk.Contracts.SapRefreshScheduler do
  @moduledoc """
  Scheduled SAP position refresh — periodically pulls latest contract
  positions from SAP OData so the solver always has current data.

  Two refresh triggers:
    1. **Scheduled** — configurable interval (default: every 15 minutes).
       Runs a full refresh across all product groups.
    2. **SAP push (ping)** — SAP calls our webhook when a contract position
       changes. The ping triggers an immediate refresh for the affected
       product group (or all groups if no product group specified).

  The refresh interval is configurable via application env:
    config :trading_desk, TradingDesk.Contracts.SapRefreshScheduler,
      interval_ms: :timer.minutes(15),
      enabled: true

  SAP position refresh is decoupled from the solve pipeline. Neither
  manual trader solves nor auto-runner solves trigger a SAP refresh.
  Instead, positions are kept current by:
    - This scheduler (periodic background refresh)
    - SAP push pings (immediate refresh when SAP detects a change)
  The solver always uses whatever positions are currently in the Store.
  """

  use GenServer
  require Logger

  alias TradingDesk.Contracts.SapPositions

  @default_interval :timer.minutes(15)

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Force an immediate refresh for a product group."
  def refresh_now(product_group \\ nil) do
    GenServer.cast(__MODULE__, {:refresh_now, product_group})
  end

  @doc "Handle a ping from SAP — triggers immediate refresh."
  def sap_ping(params \\ %{}) do
    GenServer.cast(__MODULE__, {:sap_ping, params})
  end

  @doc "Get the last refresh timestamp and status."
  def status do
    GenServer.call(__MODULE__, :status)
  end

  # ── GenServer ──────────────────────────────────────────────

  @impl true
  def init(opts) do
    config = Application.get_env(:trading_desk, __MODULE__, [])
    interval = Keyword.get(config, :interval_ms, @default_interval)
    enabled = Keyword.get(config, :enabled, true)

    if enabled do
      # First scheduled refresh after a short delay (let the app boot)
      Process.send_after(self(), :scheduled_refresh, 10_000)
    end

    {:ok, %{
      interval: interval,
      enabled: enabled,
      last_refresh_at: nil,
      last_refresh_result: nil,
      refresh_count: 0
    }}
  end

  @impl true
  def handle_cast({:refresh_now, nil}, state) do
    state = do_refresh_all(state)
    {:noreply, state}
  end

  def handle_cast({:refresh_now, product_group}, state) do
    state = do_refresh(product_group, state)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:sap_ping, params}, state) do
    product_group = parse_product_group(params)

    Logger.info(
      "SapRefreshScheduler: received SAP ping" <>
      if(product_group, do: " for #{product_group}", else: " (all groups)")
    )

    state =
      if product_group do
        do_refresh(product_group, state)
      else
        do_refresh_all(state)
      end

    # Broadcast that SAP pushed an update
    Phoenix.PubSub.broadcast(
      TradingDesk.PubSub,
      "sap_events",
      {:sap_position_changed, %{
        product_group: product_group,
        refreshed_at: state.last_refresh_at,
        source: :sap_ping
      }}
    )

    {:noreply, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, %{
      enabled: state.enabled,
      interval_ms: state.interval,
      last_refresh_at: state.last_refresh_at,
      last_refresh_result: state.last_refresh_result,
      refresh_count: state.refresh_count,
      sap_connected: SapPositions.connected?()
    }, state}
  end

  @impl true
  def handle_info(:scheduled_refresh, state) do
    state = do_refresh_all(state)

    # Schedule next refresh
    if state.enabled do
      Process.send_after(self(), :scheduled_refresh, state.interval)
    end

    {:noreply, state}
  end

  # ── Private ──────────────────────────────────────────────

  defp do_refresh_all(state) do
    Logger.info("SapRefreshScheduler: running full refresh across all product groups")

    case SapPositions.refresh_all() do
      {:ok, result} ->
        %{state |
          last_refresh_at: DateTime.utc_now(),
          last_refresh_result: {:ok, result},
          refresh_count: state.refresh_count + 1
        }

      {:error, reason} ->
        Logger.warning("SapRefreshScheduler: full refresh failed: #{inspect(reason)}")
        %{state |
          last_refresh_at: DateTime.utc_now(),
          last_refresh_result: {:error, reason}
        }
    end
  end

  defp do_refresh(product_group, state) do
    Logger.info("SapRefreshScheduler: refreshing #{product_group}")

    case SapPositions.refresh_positions(product_group) do
      {:ok, result} ->
        %{state |
          last_refresh_at: DateTime.utc_now(),
          last_refresh_result: {:ok, result},
          refresh_count: state.refresh_count + 1
        }

      {:error, reason} ->
        Logger.warning("SapRefreshScheduler: refresh failed for #{product_group}: #{inspect(reason)}")
        %{state |
          last_refresh_at: DateTime.utc_now(),
          last_refresh_result: {:error, reason}
        }
    end
  end

  defp parse_product_group(%{"product_group" => pg}) when is_binary(pg) do
    try do
      String.to_existing_atom(pg)
    rescue
      ArgumentError -> nil
    end
  end
  defp parse_product_group(%{product_group: pg}) when is_atom(pg), do: pg
  defp parse_product_group(_), do: nil
end
