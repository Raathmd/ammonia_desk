defmodule AmmoniaDesk.DB.Writer do
  @moduledoc """
  Asynchronous writer that persists in-memory data to Postgres.

  ETS remains the fast path for real-time operations. The DB writer
  runs in the background, ensuring all data reaches Postgres for
  durable storage, audit trails, and multi-node visibility.

  ## What gets persisted

    - **Contracts**: Written to DB on ingest and status changes.
      The DB row is the durable audit record; ETS is the hot cache.

    - **Solve audits**: Written to DB after every pipeline execution.
      Includes the join table linking to contract versions used.

    - **Scenarios**: Written to DB when a trader saves a scenario.

  ## Usage

  Called from the existing ETS-based stores:

      DB.Writer.persist_contract(contract)
      DB.Writer.persist_solve_audit(audit, contract_ids)
      DB.Writer.persist_scenario(scenario)

  All writes are async (cast) — the caller never blocks on DB I/O.
  """

  alias AmmoniaDesk.Repo
  alias AmmoniaDesk.DB.{ContractRecord, SolveAuditRecord, SolveAuditContract, ScenarioRecord}

  require Logger

  @doc "Persist a contract to Postgres (upsert by ID)."
  def persist_contract(%AmmoniaDesk.Contracts.Contract{} = contract) do
    Task.Supervisor.start_child(
      AmmoniaDesk.Contracts.TaskSupervisor,
      fn -> do_persist_contract(contract) end
    )
  end

  @doc "Persist a solve audit with its contract links."
  def persist_solve_audit(%AmmoniaDesk.Solver.SolveAudit{} = audit) do
    Task.Supervisor.start_child(
      AmmoniaDesk.Contracts.TaskSupervisor,
      fn -> do_persist_solve_audit(audit) end
    )
  end

  @doc "Persist a saved scenario."
  def persist_scenario(scenario) when is_map(scenario) do
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
      # 1. Insert the audit record
      attrs = SolveAuditRecord.from_solve_audit(audit)

      case %SolveAuditRecord{} |> SolveAuditRecord.changeset(attrs) |> Repo.insert() do
        {:ok, _record} ->
          # 2. Insert contract links (join table)
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
