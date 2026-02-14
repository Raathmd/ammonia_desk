defmodule AmmoniaDesk.DB.Writer do
  @moduledoc """
  Dual-write persistence: snapshot log (WAL) + Postgres.

  Every mutation follows this order:

    1. **Snapshot log** (synchronous fsync) — data is on disk, crash-safe
    2. **Postgres** (async) — durable, queryable, multi-node visible

  If Postgres fails, the snapshot log has the data. Run
  `SnapshotRestore.fill_gaps/0` to replay missing entries.

  If the snapshot log fails (disk full, etc.), we still attempt
  Postgres and log a warning — but this should never happen in
  normal operation.

  ## Recovery scenarios

    - **Postgres corrupted**: `SnapshotRestore.restore_postgres/1`
    - **Node crashed mid-write**: `SnapshotRestore.fill_gaps/0`
    - **Point-in-time restore**: `SnapshotRestore.restore_postgres(up_to: ts)`
    - **Full disaster**: `SnapshotRestore.restore_ets/1` + `restore_postgres/1`
  """

  alias AmmoniaDesk.Repo
  alias AmmoniaDesk.DB.{ContractRecord, SolveAuditRecord, SolveAuditContract, ScenarioRecord, SnapshotLog}

  require Logger

  @doc "Persist a contract: log to WAL, then async to Postgres."
  def persist_contract(%AmmoniaDesk.Contracts.Contract{} = contract) do
    # Step 1: Snapshot log (synchronous — on disk before we return)
    log_result = SnapshotLog.append(:contract, contract)

    if log_result != :ok do
      Logger.warning("SnapshotLog: contract #{contract.id} log failed: #{inspect(log_result)}")
    end

    # Step 2: Postgres (async — never blocks the caller)
    Task.Supervisor.start_child(
      AmmoniaDesk.Contracts.TaskSupervisor,
      fn -> do_persist_contract(contract) end
    )
  end

  @doc "Persist a solve audit: log to WAL, then async to Postgres."
  def persist_solve_audit(%AmmoniaDesk.Solver.SolveAudit{} = audit) do
    log_result = SnapshotLog.append(:audit, audit)

    if log_result != :ok do
      Logger.warning("SnapshotLog: audit #{audit.id} log failed: #{inspect(log_result)}")
    end

    Task.Supervisor.start_child(
      AmmoniaDesk.Contracts.TaskSupervisor,
      fn -> do_persist_solve_audit(audit) end
    )
  end

  @doc "Persist a saved scenario: log to WAL, then async to Postgres."
  def persist_scenario(scenario) when is_map(scenario) do
    log_result = SnapshotLog.append(:scenario, scenario)

    if log_result != :ok do
      Logger.warning("SnapshotLog: scenario log failed: #{inspect(log_result)}")
    end

    Task.Supervisor.start_child(
      AmmoniaDesk.Contracts.TaskSupervisor,
      fn -> do_persist_scenario(scenario) end
    )
  end

  # ──────────────────────────────────────────────────────────
  # CONTRACT PERSISTENCE
  # ──────────────────────────────────────────────────────────

  defp do_persist_contract(contract) do
    attrs = ContractRecord.from_contract(contract)

    %ContractRecord{}
    |> ContractRecord.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace_all_except, [:id, :inserted_at]},
      conflict_target: :id
    )
    |> case do
      {:ok, _} ->
        Logger.debug("DB: contract #{contract.id} persisted (#{contract.counterparty} v#{contract.version})")

      {:error, changeset} ->
        Logger.warning("DB: failed to persist contract #{contract.id}: #{inspect(changeset.errors)}")
    end
  rescue
    e ->
      Logger.warning("DB: contract persist error: #{inspect(e)}")
  end

  # ──────────────────────────────────────────────────────────
  # SOLVE AUDIT PERSISTENCE
  # ──────────────────────────────────────────────────────────

  defp do_persist_solve_audit(audit) do
    Repo.transaction(fn ->
      attrs = SolveAuditRecord.from_solve_audit(audit)

      case %SolveAuditRecord{} |> SolveAuditRecord.changeset(attrs) |> Repo.insert() do
        {:ok, _record} ->
          for contract_snap <- (audit.contracts_used || []) do
            %SolveAuditContract{}
            |> SolveAuditContract.changeset(%{
              solve_audit_id: audit.id,
              contract_id: contract_snap.id,
              counterparty: contract_snap.counterparty,
              contract_version: contract_snap.version
            })
            |> Repo.insert()
          end

          Logger.debug(
            "DB: audit #{audit.id} persisted " <>
            "(#{audit.mode}, #{length(audit.contracts_used || [])} contracts)"
          )

        {:error, changeset} ->
          Logger.warning("DB: failed to persist audit #{audit.id}: #{inspect(changeset.errors)}")
          Repo.rollback(changeset)
      end
    end)
  rescue
    e ->
      Logger.warning("DB: audit persist error: #{inspect(e)}")
  end

  # ──────────────────────────────────────────────────────────
  # SCENARIO PERSISTENCE
  # ──────────────────────────────────────────────────────────

  defp do_persist_scenario(scenario) do
    attrs = %{
      trader_id: scenario.trader_id,
      name: scenario.name,
      variables: serialize_variables(scenario.variables),
      result_data: serialize_result(scenario.result),
      solve_audit_id: scenario[:audit_id]
    }

    %ScenarioRecord{}
    |> ScenarioRecord.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, _} ->
        Logger.debug("DB: scenario '#{scenario.name}' persisted for #{scenario.trader_id}")

      {:error, changeset} ->
        Logger.warning("DB: failed to persist scenario: #{inspect(changeset.errors)}")
    end
  rescue
    e ->
      Logger.warning("DB: scenario persist error: #{inspect(e)}")
  end

  defp serialize_variables(%AmmoniaDesk.Variables{} = v), do: Map.from_struct(v)
  defp serialize_variables(v) when is_map(v), do: v
  defp serialize_variables(_), do: %{}

  defp serialize_result(r) when is_struct(r), do: Map.from_struct(r)
  defp serialize_result(r) when is_map(r), do: r
  defp serialize_result(_), do: %{}
end
