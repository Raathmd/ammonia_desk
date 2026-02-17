defmodule TradingDesk.Solver.SolveAudit do
  @moduledoc """
  Immutable record of a solve execution — what data went in, what came out.

  Every solve (single or Monte Carlo) creates one audit record capturing:

    - **Contract versions**: exactly which contract versions were active,
      including their file hashes, counterparties, version numbers, and
      clause counts. This is a point-in-time snapshot — even if the contract
      is later superseded, the audit shows what was used.

    - **Variable values + sources**: the full Variables struct plus the
      timestamp of each API source's last fetch (USGS, NOAA, USACE, EIA,
      internal systems). You can see exactly when each data point was
      refreshed relative to the solve.

    - **Contract freshness**: whether the Graph API hash check ran, whether
      any contracts were re-ingested before the solve, or whether stale
      data was used (and why).

    - **Result**: the full Result or Distribution struct.

    - **Timeline**: when each pipeline phase started and completed.

  ## Querying

  Use `SolveAudit.Store` to query audit records:

      SolveAudit.Store.list_recent(50)
      SolveAudit.Store.find_by_contract("contract-id-abc")
      SolveAudit.Store.find_by_trader("trader@trammo.com")
      SolveAudit.Store.find_by_time_range(~U[2026-02-01 00:00:00Z], ~U[2026-02-14 23:59:59Z])
  """

  defstruct [
    # Identity
    :id,                       # same as pipeline run_id (6-byte hex)
    :mode,                     # :solve | :monte_carlo
    :product_group,            # :ammonia | :uan | :urea
    :trader_id,                # who triggered it (nil for AutoRunner)
    :trigger,                  # :dashboard | :auto_runner | :api | :scheduled
    :caller_ref,               # opaque ref passed through from caller

    # ── Contract snapshot ──────────────────────────────────
    # Exactly which contract versions fed into this solve.
    # Each entry is a lightweight snapshot (not the full Contract struct).
    :contracts_used,           # [%{id, counterparty, version, file_hash, status, ...}]

    # Contract freshness check result
    :contracts_checked,        # boolean — did we check Graph API hashes?
    :contracts_stale,          # boolean — did the check fail (solved with stale data)?
    :contracts_stale_reason,   # reason if stale (nil otherwise)
    :contracts_ingested,       # count of contracts re-ingested before this solve

    # ── Variables snapshot ─────────────────────────────────
    # The exact variable values used in this solve.
    :variables,                # %Variables{} struct (frozen copy)

    # When each API source was last fetched relative to this solve.
    # %{usgs: ~U[...], noaa: ~U[...], usace: ~U[...], eia: ~U[...], internal: ~U[...]}
    :variable_sources,         # %{source_atom => DateTime.t()}

    # ── Result ─────────────────────────────────────────────
    :result,                   # %Result{} or %Distribution{}
    :result_status,            # :optimal | :infeasible | :error (from Result) or signal from Distribution

    # ── Timeline ───────────────────────────────────────────
    :started_at,               # pipeline started
    :contracts_checked_at,     # hash check completed
    :ingestion_completed_at,   # re-ingestion completed (nil if no changes)
    :solve_started_at,         # LP solver invoked
    :completed_at,             # result returned

    # ── Scenario link ──────────────────────────────────────
    :scenario_id               # if saved as a named scenario, link back
  ]

  @type contract_snapshot :: %{
    id: String.t(),
    counterparty: String.t(),
    counterparty_type: :customer | :supplier,
    version: pos_integer(),
    file_hash: String.t() | nil,
    status: atom(),
    clause_count: non_neg_integer(),
    clause_ids: [String.t()],
    graph_item_id: String.t() | nil,
    sap_contract_id: String.t() | nil,
    source_file: String.t() | nil
  }

  @type t :: %__MODULE__{
    id: String.t(),
    mode: :solve | :monte_carlo,
    product_group: atom(),
    trader_id: String.t() | nil,
    trigger: :dashboard | :auto_runner | :api | :scheduled,
    caller_ref: term(),
    contracts_used: [contract_snapshot()],
    contracts_checked: boolean(),
    contracts_stale: boolean(),
    contracts_stale_reason: term(),
    contracts_ingested: non_neg_integer(),
    variables: TradingDesk.Variables.t(),
    variable_sources: %{atom() => DateTime.t()},
    result: term(),
    result_status: atom(),
    started_at: DateTime.t(),
    contracts_checked_at: DateTime.t() | nil,
    ingestion_completed_at: DateTime.t() | nil,
    solve_started_at: DateTime.t() | nil,
    completed_at: DateTime.t() | nil,
    scenario_id: term()
  }

  @doc """
  Build a contract snapshot from a full Contract struct.

  Captures only the fields needed for audit — lightweight and immutable.
  """
  def snapshot_contract(%{} = contract) do
    clauses = contract.clauses || []

    %{
      id: contract.id,
      counterparty: contract.counterparty,
      counterparty_type: contract.counterparty_type,
      version: contract.version,
      file_hash: contract.file_hash,
      status: contract.status,
      clause_count: length(clauses),
      clause_ids: Enum.map(clauses, fn c -> c.clause_id || c.type end),
      graph_item_id: contract.graph_item_id,
      sap_contract_id: contract.sap_contract_id,
      source_file: contract.source_file
    }
  end

  @doc """
  Snapshot all active contracts for a product group.
  """
  def snapshot_active_contracts(product_group) do
    TradingDesk.Contracts.Store.get_active_set(product_group)
    |> Enum.map(&snapshot_contract/1)
  end

  @doc """
  Snapshot current variable sources from LiveState.
  """
  def snapshot_variable_sources do
    TradingDesk.Data.LiveState.last_updated()
  end
end
