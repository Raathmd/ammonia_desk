defmodule AmmoniaDesk.Contracts.Pipeline do
  @moduledoc """
  Async contract processing pipeline running independently on the BEAM.

  Each stage runs as a supervised task that can be triggered on-demand
  by any role. Extraction and verification are decoupled — they run
  independently and can be refreshed at any time.

  Full pipeline chain (run by full_extract_async):
    1. Extract     — read document, parse clauses (local only, no network)
    2. Template    — validate extraction completeness against template
    3. LLM Verify  — local LLM second-pass check (if available)
    4. SAP Fetch   — retrieve contract data from SAP (on-network only)
    5. Compare     — Elixir compares extracted vs SAP data
    6. Legal       — legal team reviews clauses and approves/rejects
    7. Ops Confirm — operations confirms SAP alignment
    8. Activate    — contract becomes active for optimization

  CurrencyTracker is stamped at every stage for staleness tracking.
  StrictGate is checked at every transition.

  Product group operations:
    - Extract all contracts for a product group in parallel
    - Template validate all + LLM validate all
    - Validate entire product group against SAP in one pass
    - Refresh open positions for all counterparties in a product group
    - Full chain: extract → template → LLM → SAP → positions

  All progress is broadcast via PubSub for real-time UI updates.
  """

  alias AmmoniaDesk.Contracts.{
    Contract,
    CopilotIngestion,
    DocumentReader,
    Parser,
    Store,
    HashVerifier,
    SapValidator,
    TemplateValidator,
    LlmValidator,
    CurrencyTracker,
    StrictGate
  }

  require Logger

  @pubsub AmmoniaDesk.PubSub
  @topic "contracts"

  # --- Single contract operations ---

  @doc """
  Extract clauses from a document in a background BEAM process.
  Returns {:ok, task_ref} immediately. Results arrive via PubSub.

  Entirely local — no data leaves the network.
  """
  def extract_async(file_path, counterparty, counterparty_type, product_group, opts \\ []) do
    Task.Supervisor.async_nolink(
      AmmoniaDesk.Contracts.TaskSupervisor,
      fn ->
        broadcast(:extraction_started, %{
          file: Path.basename(file_path),
          counterparty: counterparty,
          product_group: product_group
        })

        result = extract(file_path, counterparty, counterparty_type, product_group, opts)

        case result do
          {:ok, contract} ->
            broadcast(:extraction_complete, %{
              contract_id: contract.id,
              counterparty: contract.counterparty,
              product_group: contract.product_group,
              version: contract.version,
              clause_count: length(contract.clauses || [])
            })

          {:error, reason} ->
            broadcast(:extraction_failed, %{
              file: Path.basename(file_path),
              counterparty: counterparty,
              reason: inspect(reason)
            })
        end

        result
      end
    )
  end

  # ──────────────────────────────────────────────────────────
  # COPILOT EXTRACTION PATH (primary)
  # ──────────────────────────────────────────────────────────

  @doc """
  Ingest a contract using Copilot's pre-extracted clause data.
  This is the primary ingestion path — Copilot is the extraction service,
  the app is the system of record.

  Runs: Copilot ingest → template validate → parser cross-check → SAP validate.
  """
  def ingest_copilot_async(file_path, extraction, opts \\ []) do
    Task.Supervisor.async_nolink(
      AmmoniaDesk.Contracts.TaskSupervisor,
      fn ->
        broadcast(:copilot_chain_started, %{
          file: if(file_path, do: Path.basename(file_path), else: "from_copilot"),
          counterparty: extraction["counterparty"]
        })

        case CopilotIngestion.ingest(file_path, extraction, opts) do
          {:ok, contract} ->
            # Template validate
            contract = run_template_validation(contract)
            CurrencyTracker.stamp(contract.id, :template_validated_at)

            # SAP validate if available
            if contract.sap_contract_id do
              case SapValidator.validate(contract.id) do
                {:ok, _updated} ->
                  CurrencyTracker.stamp(contract.id, :sap_validated_at)
                _ -> :ok
              end
            end

            gate1 = StrictGate.gate_extraction(contract)
            broadcast(:copilot_chain_complete, %{
              contract_id: contract.id,
              counterparty: contract.counterparty,
              clause_count: length(contract.clauses || []),
              gate1: elem(gate1, 0)
            })

            {:ok, contract}

          {:error, reason} ->
            broadcast(:copilot_chain_failed, %{
              file: if(file_path, do: Path.basename(file_path), else: "from_copilot"),
              reason: inspect(reason)
            })
            {:error, reason}
        end
      end
    )
  end

  @doc """
  Batch ingest from Copilot — processes multiple contracts in parallel.
  `batch` is a list of {file_path, extraction_map} tuples.
  """
  def ingest_copilot_batch_async(batch, opts \\ []) do
    Task.Supervisor.async_nolink(
      AmmoniaDesk.Contracts.TaskSupervisor,
      fn ->
        broadcast(:copilot_batch_started, %{count: length(batch)})

        results =
          batch
          |> Task.async_stream(
            fn {file_path, extraction} ->
              CopilotIngestion.ingest(file_path, extraction, opts)
            end,
            max_concurrency: 4,
            timeout: 60_000
          )
          |> Enum.map(fn
            {:ok, result} -> result
            {:exit, reason} -> {:error, {:task_failed, reason}}
          end)

        succeeded = Enum.count(results, &match?({:ok, _}, &1))
        failed = Enum.count(results, &(not match?({:ok, _}, &1)))

        broadcast(:copilot_batch_complete, %{
          total: length(batch),
          succeeded: succeeded,
          failed: failed
        })

        {:ok, %{total: length(batch), succeeded: succeeded, failed: failed}}
      end
    )
  end

  # ──────────────────────────────────────────────────────────
  # DETERMINISTIC PARSER PATH (verification / fallback)
  # ──────────────────────────────────────────────────────────

  @doc """
  Full extraction chain: read → parse → template validate → LLM verify → SAP validate.
  Runs everything in sequence in a single background task. Stamps CurrencyTracker.
  Use this when Copilot is unavailable, or as a fallback verification path.
  """
  def full_extract_async(file_path, counterparty, counterparty_type, product_group, opts \\ []) do
    Task.Supervisor.async_nolink(
      AmmoniaDesk.Contracts.TaskSupervisor,
      fn ->
        broadcast(:full_chain_started, %{
          file: Path.basename(file_path),
          counterparty: counterparty,
          product_group: product_group
        })

        # Stage 1: Extract
        case extract(file_path, counterparty, counterparty_type, product_group, opts) do
          {:ok, contract} ->
            CurrencyTracker.stamp(contract.id, :parsed_at)

            # Stage 2: Template validate
            contract = run_template_validation(contract)
            CurrencyTracker.stamp(contract.id, :template_validated_at)

            broadcast(:template_validation_complete, %{
              contract_id: contract.id,
              template_type: contract.template_type,
              blocks_submission: get_in_safe(contract.template_validation, :blocks_submission)
            })

            # Stage 3: LLM verify (if available, non-blocking)
            contract = run_llm_validation(contract)
            CurrencyTracker.stamp(contract.id, :llm_validated_at)

            broadcast(:llm_validation_complete, %{
              contract_id: contract.id,
              errors: get_in_safe(contract.llm_validation, :errors),
              warnings: get_in_safe(contract.llm_validation, :warnings)
            })

            # Stage 4: SAP validate (if SAP contract ID provided)
            if contract.sap_contract_id do
              case SapValidator.validate(contract.id) do
                {:ok, updated} ->
                  CurrencyTracker.stamp(contract.id, :sap_validated_at)
                  broadcast(:sap_validation_complete, %{
                    contract_id: updated.id,
                    sap_validated: updated.sap_validated,
                    discrepancy_count: length(updated.sap_discrepancies || [])
                  })

                {:error, reason} ->
                  broadcast(:sap_validation_failed, %{
                    contract_id: contract.id,
                    reason: inspect(reason)
                  })
              end
            end

            # Check gate status
            gate1 = StrictGate.gate_extraction(contract)
            broadcast(:full_chain_complete, %{
              contract_id: contract.id,
              counterparty: contract.counterparty,
              gate1: elem(gate1, 0)
            })

            {:ok, contract}

          {:error, reason} ->
            broadcast(:full_chain_failed, %{
              file: Path.basename(file_path),
              counterparty: counterparty,
              reason: inspect(reason)
            })
            {:error, reason}
        end
      end
    )
  end

  @doc """
  Synchronous extraction — reads document, parses clauses, stores contract.
  All local, no external calls.
  """
  def extract(file_path, counterparty, counterparty_type, product_group, opts \\ []) do
    with {:read, {:ok, text}} <- {:read, DocumentReader.read(file_path)},
         {:hash, {:ok, file_hash, file_size}} <- {:hash, HashVerifier.compute_file_hash(file_path)} do
      {clauses, warnings, detected_family} = Parser.parse(text)

      if length(warnings) > 0 do
        Logger.warning(
          "Contract parse warnings for #{counterparty}: #{length(warnings)} items\n" <>
          Enum.join(warnings, "\n")
        )
      end

      # Auto-detect family if not specified in opts
      {family_id, family_direction, family_incoterm, family_term_type} =
        case detected_family do
          {:ok, fid, family} ->
            {fid, family.direction,
             List.first(family.default_incoterms),
             family.term_type}
          _ ->
            {nil, nil, nil, nil}
        end

      contract = %Contract{
        counterparty: counterparty,
        counterparty_type: counterparty_type,
        product_group: product_group,
        template_type: Keyword.get(opts, :template_type) || family_direction,
        incoterm: Keyword.get(opts, :incoterm) || family_incoterm,
        term_type: Keyword.get(opts, :term_type) || family_term_type,
        company: Keyword.get(opts, :company),
        source_file: Path.basename(file_path),
        source_format: DocumentReader.detect_format(file_path),
        clauses: clauses,
        contract_date: Keyword.get(opts, :contract_date),
        expiry_date: Keyword.get(opts, :expiry_date),
        sap_contract_id: Keyword.get(opts, :sap_contract_id),
        # Hash and inventory fields
        family_id: family_id,
        file_hash: file_hash,
        file_size: file_size,
        network_path: Keyword.get(opts, :network_path) || file_path,
        verification_status: :pending
      }

      Store.ingest(contract)
    else
      {:read, {:error, reason}} ->
        {:error, {:document_read_failed, reason}}
      {:hash, {:error, reason}} ->
        {:error, {:hash_failed, reason}}
    end
  end

  @doc """
  Run SAP validation in a background BEAM process.
  SapClient fetches data, SapValidator compares in Elixir.
  Can be triggered on-demand by operations team.
  """
  def validate_sap_async(contract_id) do
    Task.Supervisor.async_nolink(
      AmmoniaDesk.Contracts.TaskSupervisor,
      fn ->
        broadcast(:sap_validation_started, %{contract_id: contract_id})

        result = SapValidator.validate(contract_id)

        case result do
          {:ok, contract} ->
            CurrencyTracker.stamp(contract_id, :sap_validated_at)

            broadcast(:sap_validation_complete, %{
              contract_id: contract.id,
              sap_validated: contract.sap_validated,
              discrepancy_count: length(contract.sap_discrepancies || [])
            })

          {:error, reason} ->
            broadcast(:sap_validation_failed, %{
              contract_id: contract_id,
              reason: inspect(reason)
            })
        end

        result
      end
    )
  end

  @doc """
  Run template validation on a contract (re-check after template change).
  """
  def validate_template_async(contract_id) do
    Task.Supervisor.async_nolink(
      AmmoniaDesk.Contracts.TaskSupervisor,
      fn ->
        with {:ok, contract} <- Store.get(contract_id) do
          updated = run_template_validation(contract)
          CurrencyTracker.stamp(contract_id, :template_validated_at)

          broadcast(:template_validation_complete, %{
            contract_id: contract_id,
            template_type: updated.template_type,
            blocks_submission: get_in_safe(updated.template_validation, :blocks_submission)
          })

          {:ok, updated}
        end
      end
    )
  end

  @doc """
  Run LLM validation on a contract.
  """
  def validate_llm_async(contract_id) do
    Task.Supervisor.async_nolink(
      AmmoniaDesk.Contracts.TaskSupervisor,
      fn ->
        with {:ok, contract} <- Store.get(contract_id) do
          updated = run_llm_validation(contract)
          CurrencyTracker.stamp(contract_id, :llm_validated_at)

          broadcast(:llm_validation_complete, %{
            contract_id: contract_id,
            errors: get_in_safe(updated.llm_validation, :errors),
            warnings: get_in_safe(updated.llm_validation, :warnings)
          })

          {:ok, updated}
        end
      end
    )
  end

  # --- Product group batch operations ---

  @doc """
  Extract all contracts in a product group from a directory of files.
  Each file is processed in parallel on the BEAM.

  file_manifest is a list of:
    %{path: "path/to/file.pdf", counterparty: "Koch", type: :customer,
      template_type: :purchase, incoterm: :cfr, term_type: :long_term,
      company: :trammo_inc}
  """
  def extract_product_group_async(product_group, file_manifest) do
    Task.Supervisor.async_nolink(
      AmmoniaDesk.Contracts.TaskSupervisor,
      fn ->
        broadcast(:product_group_extraction_started, %{
          product_group: product_group,
          file_count: length(file_manifest)
        })

        results =
          file_manifest
          |> Task.async_stream(
            fn entry ->
              {entry.counterparty,
               extract(
                 entry.path,
                 entry.counterparty,
                 entry[:type] || :customer,
                 product_group,
                 Map.to_list(Map.drop(entry, [:path, :counterparty, :type]))
               )}
            end,
            max_concurrency: 4,
            timeout: 60_000
          )
          |> Enum.map(fn
            {:ok, result} -> result
            {:exit, reason} -> {:error, {:task_failed, reason}}
          end)

        succeeded = Enum.count(results, fn {_cp, r} -> match?({:ok, _}, r) end)
        failed = Enum.count(results, fn {_cp, r} -> not match?({:ok, _}, r) end)

        broadcast(:product_group_extraction_complete, %{
          product_group: product_group,
          total: length(file_manifest),
          succeeded: succeeded,
          failed: failed
        })

        {:ok, %{total: length(file_manifest), succeeded: succeeded, failed: failed, details: results}}
      end
    )
  end

  @doc """
  Validate all contracts in a product group against SAP.
  Runs in background on the BEAM.
  """
  def validate_product_group_async(product_group) do
    Task.Supervisor.async_nolink(
      AmmoniaDesk.Contracts.TaskSupervisor,
      fn ->
        broadcast(:product_group_validation_started, %{product_group: product_group})

        result = SapValidator.validate_product_group(product_group)

        case result do
          {:ok, summary} ->
            # Stamp currency for all validated contracts
            Store.list_by_product_group(product_group)
            |> Enum.each(fn c ->
              if c.sap_validated, do: CurrencyTracker.stamp(c.id, :sap_validated_at)
            end)

            broadcast(:product_group_validation_complete, %{
              product_group: product_group,
              validated: summary.validated,
              failed: summary.failed
            })

          {:error, reason} ->
            broadcast(:product_group_validation_failed, %{
              product_group: product_group,
              reason: inspect(reason)
            })
        end

        result
      end
    )
  end

  @doc """
  Template validate all contracts in a product group.
  """
  def validate_templates_async(product_group) do
    Task.Supervisor.async_nolink(
      AmmoniaDesk.Contracts.TaskSupervisor,
      fn ->
        contracts = Store.list_by_product_group(product_group)

        results =
          contracts
          |> Enum.map(fn c ->
            updated = run_template_validation(c)
            CurrencyTracker.stamp(c.id, :template_validated_at)
            {c.id, updated.template_validation}
          end)

        broadcast(:product_group_template_validation_complete, %{
          product_group: product_group,
          total: length(results)
        })

        {:ok, results}
      end
    )
  end

  @doc """
  Refresh all open positions for a product group from SAP.
  Runs in background. Operations team can trigger this on-demand.
  """
  def refresh_positions_async(product_group) do
    Task.Supervisor.async_nolink(
      AmmoniaDesk.Contracts.TaskSupervisor,
      fn ->
        broadcast(:positions_refresh_started, %{product_group: product_group})

        result = SapValidator.refresh_open_positions(product_group)

        case result do
          {:ok, summary} ->
            # Stamp currency for all contracts with refreshed positions
            Store.get_active_set(product_group)
            |> Enum.each(fn c ->
              if not is_nil(c.open_position) do
                CurrencyTracker.stamp(c.id, :position_refreshed_at)
              end
            end)

            broadcast(:positions_refresh_complete, %{
              product_group: product_group,
              total: summary.total,
              succeeded: summary.succeeded
            })

          {:error, reason} ->
            broadcast(:positions_refresh_failed, %{
              product_group: product_group,
              reason: inspect(reason)
            })
        end

        result
      end
    )
  end

  @doc """
  Full pipeline for a product group:
    1. Extract all contracts
    2. Template validate all
    3. LLM validate all (if available)
    4. SAP validate all
    5. Refresh open positions

  Each stage runs in sequence but individual contracts within each stage
  run in parallel. CurrencyTracker is stamped at every stage.
  """
  def full_product_group_refresh_async(product_group, file_manifest) do
    Task.Supervisor.async_nolink(
      AmmoniaDesk.Contracts.TaskSupervisor,
      fn ->
        broadcast(:full_pg_chain_started, %{
          product_group: product_group,
          file_count: length(file_manifest)
        })

        # Stage 1: Extract all contracts
        extract_results =
          file_manifest
          |> Task.async_stream(
            fn entry ->
              result = extract(
                entry.path, entry.counterparty, entry[:type] || :customer, product_group,
                Map.to_list(Map.drop(entry, [:path, :counterparty, :type]))
              )
              case result do
                {:ok, c} -> CurrencyTracker.stamp(c.id, :parsed_at)
                _ -> :ok
              end
              result
            end,
            max_concurrency: 4,
            timeout: 60_000
          )
          |> Enum.map(fn
            {:ok, result} -> result
            {:exit, reason} -> {:error, reason}
          end)

        broadcast(:product_group_extraction_complete, %{
          product_group: product_group,
          total: length(file_manifest)
        })

        # Stage 2: Template validate all
        contracts = Store.list_by_product_group(product_group)
        Enum.each(contracts, fn c ->
          run_template_validation(c)
          CurrencyTracker.stamp(c.id, :template_validated_at)
        end)

        broadcast(:product_group_template_validation_complete, %{
          product_group: product_group
        })

        # Stage 3: LLM validate all (if available)
        if LlmValidator.available?() do
          Enum.each(contracts, fn c ->
            run_llm_validation(c)
            CurrencyTracker.stamp(c.id, :llm_validated_at)
          end)
        end

        broadcast(:product_group_llm_validation_complete, %{
          product_group: product_group
        })

        # Stage 4: SAP validate all
        SapValidator.validate_product_group(product_group)
        contracts = Store.list_by_product_group(product_group)
        Enum.each(contracts, fn c ->
          if c.sap_validated, do: CurrencyTracker.stamp(c.id, :sap_validated_at)
        end)

        broadcast(:product_group_validation_complete, %{product_group: product_group})

        # Stage 5: Refresh open positions
        SapValidator.refresh_open_positions(product_group)
        Store.get_active_set(product_group)
        |> Enum.each(fn c ->
          if not is_nil(c.open_position) do
            CurrencyTracker.stamp(c.id, :position_refreshed_at)
          end
        end)

        # Stamp product group level
        CurrencyTracker.stamp_product_group(product_group, :full_refresh_at)

        broadcast(:full_pg_chain_complete, %{product_group: product_group})

        # Run master gate check
        gate4 = StrictGate.gate_product_group(product_group)

        {:ok, %{
          product_group: product_group,
          contracts_processed: length(extract_results),
          master_gate: elem(gate4, 0)
        }}
      end
    )
  end

  @doc """
  Re-extract a contract from the same source file (creates a new version).
  Carries forward template_type, incoterm, term_type, company.
  """
  def re_extract(contract_id) do
    with {:ok, contract} <- Store.get(contract_id) do
      source_path = locate_source_file(contract.source_file)

      if source_path do
        full_extract_async(
          source_path,
          contract.counterparty,
          contract.counterparty_type,
          contract.product_group,
          template_type: contract.template_type,
          incoterm: contract.incoterm,
          term_type: contract.term_type,
          company: contract.company,
          contract_date: contract.contract_date,
          expiry_date: contract.expiry_date,
          sap_contract_id: contract.sap_contract_id
        )
      else
        {:error, :source_file_not_found}
      end
    end
  end

  @doc """
  Run gate check and return status for UI.
  """
  def check_gates(contract_id) do
    with {:ok, contract} <- Store.get(contract_id) do
      {:ok, %{
        gate1_extraction: StrictGate.gate_extraction(contract),
        gate2_review: StrictGate.gate_review(contract),
        gate3_activation: StrictGate.gate_activation(contract)
      }}
    end
  end

  # --- Private ---

  defp run_template_validation(contract) do
    case TemplateValidator.validate(contract) do
      {:ok, result} ->
        updated = %{contract | template_validation: result}
        Store.update_template_validation(contract.id, result)
        updated

      {:error, reason} ->
        Logger.warning("Template validation failed for #{contract.id}: #{inspect(reason)}")
        contract
    end
  end

  defp run_llm_validation(contract) do
    if LlmValidator.available?() do
      case LlmValidator.validate(contract.id) do
        {:ok, result} ->
          updated = %{contract | llm_validation: result}
          Store.update_llm_validation(contract.id, result)
          updated

        {:error, reason} ->
          Logger.warning("LLM validation failed for #{contract.id}: #{inspect(reason)}")
          contract
      end
    else
      contract
    end
  end

  defp get_in_safe(nil, _key), do: nil
  defp get_in_safe(map, key) when is_map(map), do: Map.get(map, key)
  defp get_in_safe(_, _), do: nil

  defp broadcast(event, payload) do
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:contract_event, event, payload})
  end

  defp locate_source_file(filename) do
    upload_dir = System.get_env("CONTRACT_UPLOAD_DIR") || "priv/contracts"
    path = Path.join(upload_dir, filename)
    if File.exists?(path), do: path
  end
end
