defmodule AmmoniaDesk.Contracts.Pipeline do
  @moduledoc """
  Async contract processing pipeline running independently on the BEAM.

  Each stage runs as a supervised task that can be triggered on-demand
  by any role. Extraction and verification are decoupled — they run
  independently and can be refreshed at any time.

  Pipeline stages (each independent):
    1. Extract     — read document, parse clauses (local only, no network)
    2. SAP Fetch   — retrieve contract data from SAP (on-network only)
    3. Compare     — Elixir compares extracted vs SAP data
    4. Legal       — legal team reviews clauses and approves/rejects
    5. Ops Confirm — operations confirms SAP alignment
    6. Activate    — contract becomes active for optimization

  Product group operations:
    - Extract all contracts for a product group in parallel
    - Validate entire product group against SAP in one pass
    - Refresh open positions for all counterparties in a product group

  All progress is broadcast via PubSub for real-time UI updates.
  """

  alias AmmoniaDesk.Contracts.{
    Contract,
    DocumentReader,
    Parser,
    Store,
    SapValidator
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

  @doc """
  Synchronous extraction — reads document, parses clauses, stores contract.
  All local, no external calls.
  """
  def extract(file_path, counterparty, counterparty_type, product_group, opts \\ []) do
    with {:read, {:ok, text}} <- {:read, DocumentReader.read(file_path)},
         {:parse, {clauses, warnings}} <- {:parse, Parser.parse(text)} do

      if length(warnings) > 0 do
        Logger.warning(
          "Contract parse warnings for #{counterparty}: #{length(warnings)} items\n" <>
          Enum.join(warnings, "\n")
        )
      end

      contract = %Contract{
        counterparty: counterparty,
        counterparty_type: counterparty_type,
        product_group: product_group,
        source_file: Path.basename(file_path),
        source_format: DocumentReader.detect_format(file_path),
        clauses: clauses,
        contract_date: Keyword.get(opts, :contract_date),
        expiry_date: Keyword.get(opts, :expiry_date),
        sap_contract_id: Keyword.get(opts, :sap_contract_id)
      }

      Store.ingest(contract)
    else
      {:read, {:error, reason}} ->
        {:error, {:document_read_failed, reason}}

      {:parse, _} ->
        {:error, :parse_failed}
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

  # --- Product group batch operations ---

  @doc """
  Extract all contracts in a product group from a directory of files.
  Each file is processed in parallel on the BEAM.

  file_manifest is a list of:
    %{path: "path/to/file.pdf", counterparty: "Koch", type: :customer}
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
  Full pipeline for a product group: extract all + SAP validate all + refresh positions.
  Each stage runs in sequence but individual contracts within each stage run in parallel.
  """
  def full_product_group_refresh_async(product_group, file_manifest) do
    Task.Supervisor.async_nolink(
      AmmoniaDesk.Contracts.TaskSupervisor,
      fn ->
        # Stage 1: Extract all contracts
        extract_results =
          file_manifest
          |> Task.async_stream(
            fn entry ->
              extract(entry.path, entry.counterparty, entry[:type] || :customer, product_group,
                Map.to_list(Map.drop(entry, [:path, :counterparty, :type])))
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

        # Stage 2: SAP validate all
        SapValidator.validate_product_group(product_group)

        broadcast(:product_group_validation_complete, %{product_group: product_group})

        # Stage 3: Refresh open positions
        SapValidator.refresh_open_positions(product_group)

        broadcast(:product_group_refresh_complete, %{product_group: product_group})

        {:ok, %{product_group: product_group, contracts_processed: length(extract_results)}}
      end
    )
  end

  @doc """
  Re-extract a contract from the same source file (creates a new version).
  """
  def re_extract(contract_id) do
    with {:ok, contract} <- Store.get(contract_id) do
      source_path = locate_source_file(contract.source_file)

      if source_path do
        extract_async(
          source_path,
          contract.counterparty,
          contract.counterparty_type,
          contract.product_group,
          contract_date: contract.contract_date,
          expiry_date: contract.expiry_date,
          sap_contract_id: contract.sap_contract_id
        )
      else
        {:error, :source_file_not_found}
      end
    end
  end

  # --- Private ---

  defp broadcast(event, payload) do
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:contract_event, event, payload})
  end

  defp locate_source_file(filename) do
    upload_dir = System.get_env("CONTRACT_UPLOAD_DIR") || "priv/contracts"
    path = Path.join(upload_dir, filename)
    if File.exists?(path), do: path
  end
end
