defmodule TradingDesk.Solver.Pipeline do
  @moduledoc """
  Solve pipeline that ensures contract data is current before solving.

  Every solve goes through this pipeline:

    1. Check contract hashes against Graph API (via Zig scanner)
    2. If any contracts changed or are new:
       a. Notify caller: "waiting for Copilot to ingest changes"
       b. Fetch changed files, extract via Copilot LLM, ingest
       c. Reload contract-derived variables
    3. Snapshot active contracts + variable sources (for audit)
    4. Run the LP solve (single or Monte Carlo) with current data
    5. Write audit record (immutable — contract versions, variables, result)
    6. SAP write-back stub (if trader decides to act on solver outcome)
    7. Return result

  SAP position refresh is NOT part of the solve pipeline. SAP positions
  are refreshed independently via:
    - SAP ping webhook (POST /api/sap/ping) — SAP calls this when a
      contract position changes
    - SapRefreshScheduler — periodic scheduled refresh
  The solver uses whatever positions are currently in the Store.

  Every pipeline execution writes a `SolveAudit` record capturing exactly
  which contract versions and variable values were used. This enables:

    - Auditing: which contract data drove a particular decision
    - DAG visualization: trace decision paths over time
    - Performance tracking: compare auto-runner vs trader decisions
    - Management reporting: product group and company-wide views

  The pipeline runs asynchronously. The dashboard subscribes to PubSub
  events and updates as each phase completes:

    :pipeline_started       — solve requested, checking contracts
    :pipeline_contracts_ok  — contracts current, solving now
    :pipeline_ingesting     — N contracts changed, ingesting first
    :pipeline_ingest_done   — ingestion complete, solving now
    :pipeline_solve_done    — solve complete, result available
    :pipeline_error         — something failed

  ## Usage

      # From LiveView:
      Pipeline.solve_async(variables, product_group: :ammonia, trader_id: "trader@trammo.com")
      # Dashboard gets PubSub updates as phases complete

      # Synchronous (for AutoRunner):
      Pipeline.solve(variables, product_group: :ammonia, trigger: :auto_runner)
  """

  alias TradingDesk.Contracts.{ScanCoordinator, NetworkScanner, Store, SapPositions}
  alias TradingDesk.Solver.{Port, SolveAudit, SolveAuditStore}
  alias TradingDesk.Data.LiveState

  require Logger

  @pubsub TradingDesk.PubSub
  @topic "solve_pipeline"

  # ──────────────────────────────────────────────────────────
  # PUBLIC API
  # ──────────────────────────────────────────────────────────

  @doc """
  Run the full pipeline: check contracts → solve → audit → write-back stub.

  Options:
    :product_group   — which contracts to check (default: :ammonia)
    :mode            — :solve or :monte_carlo (default: :solve)
    :n_scenarios     — Monte Carlo scenario count (default: 1000)
    :skip_contracts  — skip contract check (default: false)
    :caller_ref      — opaque reference passed through to events
    :trader_id       — who triggered this solve (nil for auto-runner)
    :trigger         — :dashboard | :auto_runner | :api | :scheduled
    :sap_write_back  — params for SAP write-back after solve (default: nil)
  """
  @spec run(TradingDesk.Variables.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(variables, opts \\ []) do
    product_group = Keyword.get(opts, :product_group, :ammonia)
    mode = Keyword.get(opts, :mode, :solve)
    n_scenarios = Keyword.get(opts, :n_scenarios, 1000)
    skip_contracts = Keyword.get(opts, :skip_contracts, false)
    caller_ref = Keyword.get(opts, :caller_ref)
    trader_id = Keyword.get(opts, :trader_id)
    trigger = Keyword.get(opts, :trigger, :dashboard)
    solver_opts = Keyword.get(opts, :solver_opts, [])
    sap_write_back = Keyword.get(opts, :sap_write_back)

    run_id = generate_run_id()
    started_at = DateTime.utc_now()

    # Initialize audit record — will be populated as we go
    audit = %SolveAudit{
      id: run_id,
      mode: mode,
      product_group: product_group,
      trader_id: trader_id,
      trigger: trigger,
      caller_ref: caller_ref,
      variables: variables,
      variable_sources: SolveAudit.snapshot_variable_sources(),
      contracts_checked: false,
      contracts_stale: false,
      contracts_ingested: 0,
      started_at: started_at
    }

    broadcast(:pipeline_started, %{
      run_id: run_id,
      mode: mode,
      product_group: product_group,
      caller_ref: caller_ref
    })

    Logger.info("Pipeline #{run_id}: #{mode} for #{product_group}")

    # Phase 1: Contract freshness check
    {contract_result, audit} =
      if skip_contracts or not scanner_available?() do
        {{:ok, :skipped}, audit}
      else
        check_and_ingest_contracts(run_id, product_group, caller_ref, audit)
      end

    # Snapshot active contracts AFTER any ingestion (positions from SAP
    # are already in the Store, refreshed by the SAP ping/scheduler)
    audit = %{audit |
      contracts_used: SolveAudit.snapshot_active_contracts(product_group),
      contracts_checked_at: if(audit.contracts_checked, do: DateTime.utc_now())
    }

    case contract_result do
      {:ok, _} ->
        # Phase 2: Solve
        broadcast(:pipeline_solving, %{
          run_id: run_id,
          mode: mode,
          caller_ref: caller_ref
        })

        audit = %{audit | solve_started_at: DateTime.utc_now()}
        solve_result = execute_solve(variables, product_group, mode, n_scenarios, solver_opts)

        case solve_result do
          {:ok, result} ->
            completed_at = DateTime.utc_now()
            audit = %{audit |
              result: result,
              result_status: extract_result_status(result, mode),
              completed_at: completed_at
            }

            # Write the audit record
            write_audit(audit)

            # Phase 3: SAP write-back stub (if trader wants to push action to SAP)
            write_back_result = maybe_sap_write_back(sap_write_back, run_id)

            broadcast(:pipeline_solve_done, %{
              run_id: run_id,
              mode: mode,
              result: result,
              audit_id: run_id,
              caller_ref: caller_ref,
              completed_at: completed_at,
              sap_write_back: write_back_result
            })

            {:ok, %{
              run_id: run_id,
              audit_id: run_id,
              result: result,
              mode: mode,
              contracts_checked: audit.contracts_checked,
              completed_at: completed_at
            }}

          {:error, reason} ->
            audit = %{audit |
              result_status: :error,
              completed_at: DateTime.utc_now()
            }
            write_audit(audit)

            broadcast(:pipeline_error, %{
              run_id: run_id,
              phase: :solve,
              error: reason,
              caller_ref: caller_ref
            })
            {:error, {:solve_failed, reason}}
        end

      {:error, reason} ->
        # Contract check failed — solve anyway with stale data
        Logger.warning("Pipeline #{run_id}: contract check failed (#{inspect(reason)}), solving with existing data")

        audit = %{audit |
          contracts_stale: true,
          contracts_stale_reason: reason
        }

        broadcast(:pipeline_contracts_stale, %{
          run_id: run_id,
          reason: reason,
          caller_ref: caller_ref
        })

        audit = %{audit | solve_started_at: DateTime.utc_now()}
        solve_result = execute_solve(variables, product_group, mode, n_scenarios, solver_opts)

        case solve_result do
          {:ok, result} ->
            completed_at = DateTime.utc_now()
            audit = %{audit |
              result: result,
              result_status: extract_result_status(result, mode),
              completed_at: completed_at
            }

            write_audit(audit)

            write_back_result = maybe_sap_write_back(sap_write_back, run_id)

            broadcast(:pipeline_solve_done, %{
              run_id: run_id,
              mode: mode,
              result: result,
              contracts_stale: true,
              audit_id: run_id,
              caller_ref: caller_ref,
              completed_at: completed_at,
              sap_write_back: write_back_result
            })

            {:ok, %{
              run_id: run_id,
              audit_id: run_id,
              result: result,
              mode: mode,
              contracts_checked: false,
              contracts_stale_reason: reason,
              completed_at: completed_at
            }}

          {:error, reason} ->
            audit = %{audit | result_status: :error, completed_at: DateTime.utc_now()}
            write_audit(audit)
            {:error, {:solve_failed, reason}}
        end
    end
  end

  @doc "Run pipeline asynchronously — broadcasts events to PubSub."
  def run_async(variables, opts \\ []) do
    Task.Supervisor.async_nolink(
      TradingDesk.Contracts.TaskSupervisor,
      fn -> run(variables, opts) end
    )
  end

  @doc "Convenience: solve mode."
  def solve(variables, opts \\ []) do
    run(variables, Keyword.put(opts, :mode, :solve))
  end

  def solve_async(variables, opts \\ []) do
    run_async(variables, Keyword.put(opts, :mode, :solve))
  end

  @doc "Convenience: Monte Carlo mode."
  def monte_carlo(variables, opts \\ []) do
    run(variables, Keyword.put(opts, :mode, :monte_carlo))
  end

  def monte_carlo_async(variables, opts \\ []) do
    run_async(variables, Keyword.put(opts, :mode, :monte_carlo))
  end

  @doc """
  Create a contract in SAP based on solver outcome.

  This is the pipeline entry point for SAP write-back. The trader
  reviews a solver result, decides to act, and this pushes the action
  to SAP as a new contract or delivery.

  Delegates to SapPositions.create_contract/1.
  Currently a stub — does not call SAP.
  """
  def sap_create_contract(params) do
    SapPositions.create_contract(params)
  end

  @doc """
  Create a delivery in SAP under an existing contract.

  Delegates to SapPositions.create_delivery/1.
  Currently a stub — does not call SAP.
  """
  def sap_create_delivery(params) do
    SapPositions.create_delivery(params)
  end

  # ──────────────────────────────────────────────────────────
  # PHASE 1: CONTRACT FRESHNESS CHECK
  # ──────────────────────────────────────────────────────────

  defp check_and_ingest_contracts(run_id, product_group, caller_ref, audit) do
    contracts = Store.list_by_product_group(product_group)

    # Build list of contracts with Graph IDs and stored hashes
    known =
      contracts
      |> Enum.filter(fn c -> c.file_hash && c.graph_item_id && c.graph_drive_id end)
      |> Enum.map(fn c ->
        %{id: c.id, drive_id: c.graph_drive_id, item_id: c.graph_item_id, hash: c.file_hash}
      end)

    audit = %{audit | contracts_checked: true}

    if length(known) == 0 do
      broadcast(:pipeline_contracts_ok, %{
        run_id: run_id,
        message: "no contracts with Graph IDs to check",
        caller_ref: caller_ref
      })
      {{:ok, :no_contracts_to_check}, audit}
    else
      Logger.info("Pipeline #{run_id}: checking #{length(known)} contract hashes")

      case NetworkScanner.diff_hashes(known) do
        {:ok, diff} ->
          changed = Map.get(diff, "changed", [])
          missing = Map.get(diff, "missing", [])
          unchanged = Map.get(diff, "unchanged", [])

          if length(changed) == 0 and length(missing) == 0 do
            broadcast(:pipeline_contracts_ok, %{
              run_id: run_id,
              checked: length(unchanged),
              caller_ref: caller_ref
            })

            Logger.info("Pipeline #{run_id}: all #{length(unchanged)} contracts current")
            {{:ok, :all_current}, audit}
          else
            broadcast(:pipeline_ingesting, %{
              run_id: run_id,
              changed: length(changed),
              missing: length(missing),
              unchanged: length(unchanged),
              caller_ref: caller_ref
            })

            Logger.info(
              "Pipeline #{run_id}: #{length(changed)} changed, " <>
              "#{length(missing)} missing — ingesting before solve"
            )

            case ScanCoordinator.check_existing(product_group) do
              {:ok, ingest_result} ->
                ingested_count = ingest_result[:changed] || 0
                audit = %{audit |
                  contracts_ingested: ingested_count,
                  ingestion_completed_at: DateTime.utc_now()
                }

                broadcast(:pipeline_ingest_done, %{
                  run_id: run_id,
                  re_ingested: ingested_count,
                  caller_ref: caller_ref
                })

                Logger.info("Pipeline #{run_id}: ingestion complete, proceeding to solve")
                {{:ok, :ingested}, audit}

              {:error, reason} ->
                {{:error, {:ingest_failed, reason}}, audit}
            end
          end

        {:error, reason} ->
          {{:error, {:hash_check_failed, reason}}, audit}
      end
    end
  end

  # ──────────────────────────────────────────────────────────
  # PHASE 2: EXECUTE SOLVE
  # ──────────────────────────────────────────────────────────

  defp execute_solve(%TradingDesk.Variables{} = variables, _product_group, :solve, _n_scenarios, _solver_opts) do
    Port.solve(variables)
  end

  defp execute_solve(%TradingDesk.Variables{} = variables, _product_group, :monte_carlo, n_scenarios, _solver_opts) do
    Port.monte_carlo(variables, n_scenarios)
  end

  defp execute_solve(variables, product_group, :solve, _n_scenarios, solver_opts) when is_map(variables) do
    Port.solve(product_group, variables, solver_opts)
  end

  defp execute_solve(variables, product_group, :monte_carlo, n_scenarios, solver_opts) when is_map(variables) do
    Port.monte_carlo(product_group, variables, n_scenarios, solver_opts)
  end

  # ──────────────────────────────────────────────────────────
  # PHASE 3: SAP WRITE-BACK STUB
  # ──────────────────────────────────────────────────────────

  defp maybe_sap_write_back(nil, _run_id), do: nil

  defp maybe_sap_write_back(%{type: :contract} = params, run_id) do
    Logger.info("Pipeline #{run_id}: SAP write-back — creating contract")
    case SapPositions.create_contract(Map.put(params, :solver_run_id, run_id)) do
      {:ok, result} -> result
      {:error, reason} ->
        Logger.warning("Pipeline #{run_id}: SAP create_contract failed: #{inspect(reason)}")
        %{status: :failed, error: reason}
    end
  end

  defp maybe_sap_write_back(%{type: :delivery} = params, run_id) do
    Logger.info("Pipeline #{run_id}: SAP write-back — creating delivery")
    case SapPositions.create_delivery(Map.put(params, :solver_run_id, run_id)) do
      {:ok, result} -> result
      {:error, reason} ->
        Logger.warning("Pipeline #{run_id}: SAP create_delivery failed: #{inspect(reason)}")
        %{status: :failed, error: reason}
    end
  end

  defp maybe_sap_write_back(params, run_id) do
    Logger.warning("Pipeline #{run_id}: unknown SAP write-back type: #{inspect(params)}")
    nil
  end

  # ──────────────────────────────────────────────────────────
  # AUDIT
  # ──────────────────────────────────────────────────────────

  defp write_audit(audit) do
    # ETS (fast, in-process — powers real-time queries and DAG visualization)
    case SolveAuditStore.record(audit) do
      {:ok, _} ->
        Logger.debug("Audit #{audit.id} recorded (#{audit.mode}, #{length(audit.contracts_used || [])} contracts)")

      error ->
        Logger.warning("Failed to write audit #{audit.id}: #{inspect(error)}")
    end

    # Postgres (durable, multi-node — powers audit trail and management reporting)
    TradingDesk.DB.Writer.persist_solve_audit(audit)
  end

  defp extract_result_status(result, :solve) do
    Map.get(result, :status, :unknown)
  end

  defp extract_result_status(result, :monte_carlo) do
    Map.get(result, :signal, :unknown)
  end

  # ──────────────────────────────────────────────────────────
  # HELPERS
  # ──────────────────────────────────────────────────────────

  defp scanner_available? do
    try do
      NetworkScanner.available?()
    catch
      :exit, _ -> false
    end
  end

  defp generate_run_id do
    :crypto.strong_rand_bytes(6) |> Base.hex_encode32(case: :lower, padding: false)
  end

  defp broadcast(event, payload) do
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:pipeline_event, event, payload})
  end
end
