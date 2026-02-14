defmodule AmmoniaDesk.DB.SnapshotRestore do
  @moduledoc """
  Restores application state from snapshot log files.

  The snapshot log is the source of truth — it contains full, self-contained
  data for every mutation. This module replays log entries to rebuild:

    1. **Postgres** — drop and re-insert from log entries
    2. **ETS** — rebuild in-memory stores (contracts, audits, scenarios)
    3. **Both** — full recovery after a catastrophic failure

  ## Point-in-time restore

  Every log entry has a timestamp. You can restore to any point:

      # Restore Postgres to state as of noon today
      SnapshotRestore.restore_postgres(up_to: ~U[2026-02-14 12:00:00Z])

      # Restore just the last 24 hours to fill a gap
      SnapshotRestore.restore_postgres(since: ~U[2026-02-13 12:00:00Z])

  ## Gap filling

  If the async DB.Writer failed for some entries (network blip, Postgres
  down temporarily), you can fill the gaps without a full rebuild:

      SnapshotRestore.fill_gaps()

  This reads the log, checks which entries are missing from Postgres,
  and inserts only those.

  ## Integrity verification

  Before restoring, you can verify the hash chain hasn't been tampered with:

      SnapshotRestore.verify_all()
  """

  alias AmmoniaDesk.DB.{SnapshotLog, ContractRecord, SolveAuditRecord, SolveAuditContract, ScenarioRecord}
  alias AmmoniaDesk.Repo

  require Logger

  # ──────────────────────────────────────────────────────────
  # FULL RESTORE TO POSTGRES
  # ──────────────────────────────────────────────────────────

  @doc """
  Restore Postgres from snapshot log.

  Options:
    :since   — only replay entries after this timestamp
    :up_to   — only replay entries up to this timestamp
    :types   — which types to restore (default: all)
    :verify  — verify hash chain before restoring (default: true)
  """
  @spec restore_postgres(keyword()) :: {:ok, map()} | {:error, term()}
  def restore_postgres(opts \\ []) do
    since = Keyword.get(opts, :since, ~U[1970-01-01 00:00:00Z])
    up_to = Keyword.get(opts, :up_to, DateTime.utc_now())
    types = Keyword.get(opts, :types, [:contract, :audit, :scenario])
    verify = Keyword.get(opts, :verify, true)

    Logger.info("SnapshotRestore: starting Postgres restore (#{inspect(types)})")

    # Optionally verify integrity first
    if verify do
      case verify_all() do
        :ok -> :ok
        {:error, details} ->
          Logger.warning("SnapshotRestore: chain verification found issues: #{inspect(details)}")
      end
    end

    results =
      Enum.map(types, fn type ->
        entries = read_entries(type, since, up_to)
        count = length(entries)
        Logger.info("SnapshotRestore: replaying #{count} #{type} entries")

        restored = replay_to_postgres(type, entries)
        {type, %{total: count, restored: restored}}
      end)
      |> Map.new()

    Logger.info("SnapshotRestore: complete — #{inspect(results)}")
    {:ok, results}
  end

  # ──────────────────────────────────────────────────────────
  # POINT-IN-TIME RESTORE TO ETS
  # ──────────────────────────────────────────────────────────

  @doc """
  Restore ETS stores from snapshot log.

  Rebuilds the in-memory state to a specific point in time. Useful after
  a node crash or for testing against historical state.

  Options:
    :up_to — restore state as of this timestamp (default: now)
  """
  @spec restore_ets(keyword()) :: {:ok, map()}
  def restore_ets(opts \\ []) do
    up_to = Keyword.get(opts, :up_to, DateTime.utc_now())

    Logger.info("SnapshotRestore: rebuilding ETS state up to #{DateTime.to_iso8601(up_to)}")

    # Contracts: replay all contract mutations, keeping latest per ID
    contract_entries = read_entries(:contract, ~U[1970-01-01 00:00:00Z], up_to)
    contracts_by_id = build_latest_map(contract_entries)

    contract_count =
      Enum.count(contracts_by_id, fn {_id, contract} ->
        case AmmoniaDesk.Contracts.Store.ingest(contract) do
          {:ok, _} -> true
          {:error, _} -> false
        end
      end)

    # Audits: replay all audit entries
    audit_entries = read_entries(:audit, ~U[1970-01-01 00:00:00Z], up_to)
    audit_count =
      Enum.count(audit_entries, fn entry ->
        case AmmoniaDesk.Solver.SolveAuditStore.record(entry.data) do
          {:ok, _} -> true
          _ -> false
        end
      end)

    results = %{
      contracts_restored: contract_count,
      audits_restored: audit_count,
      restored_up_to: up_to
    }

    Logger.info("SnapshotRestore: ETS rebuilt — #{inspect(results)}")
    {:ok, results}
  end

  # ──────────────────────────────────────────────────────────
  # GAP FILLING
  # ──────────────────────────────────────────────────────────

  @doc """
  Find and fill gaps between snapshot log and Postgres.

  Reads the log, checks which entries are missing from Postgres,
  and inserts only those. Safe to run repeatedly.
  """
  @spec fill_gaps(keyword()) :: {:ok, map()}
  def fill_gaps(opts \\ []) do
    since = Keyword.get(opts, :since, ~U[1970-01-01 00:00:00Z])

    Logger.info("SnapshotRestore: scanning for gaps since #{DateTime.to_iso8601(since)}")

    # Contracts
    contract_entries = read_entries(:contract, since, DateTime.utc_now())
    contract_gaps = find_missing_contracts(contract_entries)
    contract_filled = replay_to_postgres(:contract, contract_gaps)

    # Audits
    audit_entries = read_entries(:audit, since, DateTime.utc_now())
    audit_gaps = find_missing_audits(audit_entries)
    audit_filled = replay_to_postgres(:audit, audit_gaps)

    # Scenarios
    scenario_entries = read_entries(:scenario, since, DateTime.utc_now())
    scenario_gaps = find_missing_scenarios(scenario_entries)
    scenario_filled = replay_to_postgres(:scenario, scenario_gaps)

    results = %{
      contracts: %{scanned: length(contract_entries), gaps_filled: contract_filled},
      audits: %{scanned: length(audit_entries), gaps_filled: audit_filled},
      scenarios: %{scanned: length(scenario_entries), gaps_filled: scenario_filled}
    }

    Logger.info("SnapshotRestore: gap fill complete — #{inspect(results)}")
    {:ok, results}
  end

  # ──────────────────────────────────────────────────────────
  # INTEGRITY VERIFICATION
  # ──────────────────────────────────────────────────────────

  @doc """
  Verify hash chain integrity for all WAL files.

  Returns :ok if all chains are valid, or a list of broken files.
  """
  @spec verify_all() :: :ok | {:error, [{String.t(), term()}]}
  def verify_all do
    errors =
      [:contract, :audit, :scenario]
      |> Enum.flat_map(fn type ->
        SnapshotLog.list_files(type)
        |> Enum.map(fn path ->
          case SnapshotLog.verify_chain(path) do
            :ok -> nil
            {:error, detail} -> {path, detail}
          end
        end)
        |> Enum.reject(&is_nil/1)
      end)

    if errors == [] do
      :ok
    else
      {:error, errors}
    end
  end

  # ──────────────────────────────────────────────────────────
  # INTERNAL: READ ENTRIES
  # ──────────────────────────────────────────────────────────

  defp read_entries(type, since, up_to) do
    case SnapshotLog.read_range(type, since, up_to) do
      {:ok, entries} -> entries
      {:error, reason} ->
        Logger.error("SnapshotRestore: failed to read #{type} entries: #{inspect(reason)}")
        []
    end
  end

  # ──────────────────────────────────────────────────────────
  # INTERNAL: REPLAY TO POSTGRES
  # ──────────────────────────────────────────────────────────

  defp replay_to_postgres(:contract, entries) do
    Enum.count(entries, fn entry ->
      contract = entry.data
      attrs = ContractRecord.from_contract(contract)

      case %ContractRecord{}
           |> ContractRecord.changeset(attrs)
           |> Repo.insert(on_conflict: :nothing, conflict_target: :id) do
        {:ok, _} -> true
        {:error, _} -> false
      end
    end)
  rescue
    e ->
      Logger.error("SnapshotRestore: contract replay error: #{inspect(e)}")
      0
  end

  defp replay_to_postgres(:audit, entries) do
    Enum.count(entries, fn entry ->
      audit = entry.data

      Repo.transaction(fn ->
        attrs = SolveAuditRecord.from_solve_audit(audit)

        case %SolveAuditRecord{}
             |> SolveAuditRecord.changeset(attrs)
             |> Repo.insert(on_conflict: :nothing, conflict_target: :id) do
          {:ok, _record} ->
            # Insert contract links
            for snap <- (audit.contracts_used || []) do
              %SolveAuditContract{}
              |> SolveAuditContract.changeset(%{
                solve_audit_id: audit.id,
                contract_id: snap.id,
                counterparty: snap.counterparty,
                contract_version: snap.version
              })
              |> Repo.insert(on_conflict: :nothing,
                   conflict_target: [:solve_audit_id, :contract_id])
            end
            true

          {:error, _} ->
            Repo.rollback(:skip)
        end
      end)
      |> case do
        {:ok, true} -> true
        _ -> false
      end
    end)
  rescue
    e ->
      Logger.error("SnapshotRestore: audit replay error: #{inspect(e)}")
      0
  end

  defp replay_to_postgres(:scenario, entries) do
    Enum.count(entries, fn entry ->
      scenario = entry.data
      attrs = %{
        trader_id: scenario[:trader_id] || scenario.trader_id,
        name: scenario[:name] || scenario.name,
        variables: serialize_vars(scenario[:variables] || scenario.variables),
        result_data: serialize_result(scenario[:result] || scenario.result),
        solve_audit_id: scenario[:audit_id]
      }

      case %ScenarioRecord{} |> ScenarioRecord.changeset(attrs) |> Repo.insert() do
        {:ok, _} -> true
        {:error, _} -> false
      end
    end)
  rescue
    e ->
      Logger.error("SnapshotRestore: scenario replay error: #{inspect(e)}")
      0
  end

  # ──────────────────────────────────────────────────────────
  # INTERNAL: GAP DETECTION
  # ──────────────────────────────────────────────────────────

  defp find_missing_contracts(entries) do
    ids = Enum.map(entries, fn e -> e.data.id end) |> Enum.uniq()

    existing_ids =
      if length(ids) > 0 do
        import Ecto.Query
        Repo.all(from c in ContractRecord, where: c.id in ^ids, select: c.id)
      else
        []
      end
      |> MapSet.new()

    Enum.reject(entries, fn e -> MapSet.member?(existing_ids, e.data.id) end)
  end

  defp find_missing_audits(entries) do
    ids = Enum.map(entries, fn e -> e.data.id end) |> Enum.uniq()

    existing_ids =
      if length(ids) > 0 do
        import Ecto.Query
        Repo.all(from a in SolveAuditRecord, where: a.id in ^ids, select: a.id)
      else
        []
      end
      |> MapSet.new()

    Enum.reject(entries, fn e -> MapSet.member?(existing_ids, e.data.id) end)
  end

  defp find_missing_scenarios(entries) do
    # Scenarios don't have stable IDs from the log, so we use timestamps
    # to detect approximate gaps. This is less precise but still useful.
    if length(entries) == 0 do
      []
    else
      import Ecto.Query
      oldest = entries |> Enum.map(& &1.ts) |> Enum.min(DateTime)
      db_count = Repo.one(from s in ScenarioRecord, where: s.inserted_at >= ^oldest, select: count())
      log_count = length(entries)

      if db_count < log_count do
        Logger.info("SnapshotRestore: #{log_count - db_count} scenario gaps detected")
        # Re-insert all — Postgres will handle duplicates via unique constraints
        entries
      else
        []
      end
    end
  rescue
    _ -> entries
  end

  # ──────────────────────────────────────────────────────────
  # INTERNAL: HELPERS
  # ──────────────────────────────────────────────────────────

  defp build_latest_map(entries) do
    # For contracts, keep only the latest entry per ID
    Enum.reduce(entries, %{}, fn entry, acc ->
      Map.put(acc, entry.data.id, entry.data)
    end)
  end

  defp serialize_vars(%AmmoniaDesk.Variables{} = v), do: Map.from_struct(v)
  defp serialize_vars(v) when is_map(v), do: v
  defp serialize_vars(_), do: %{}

  defp serialize_result(r) when is_struct(r), do: Map.from_struct(r)
  defp serialize_result(r) when is_map(r), do: r
  defp serialize_result(_), do: %{}
end
