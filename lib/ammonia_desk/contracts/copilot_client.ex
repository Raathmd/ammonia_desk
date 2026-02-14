defmodule AmmoniaDesk.Contracts.CopilotClient do
  @moduledoc """
  HTTP client for the Copilot extraction service.

  Architecture — clean separation of concerns:
    - Copilot reads contract documents (it has native SharePoint/network access)
    - Copilot computes the SHA-256 hash of each file it reads
    - Copilot extracts structured clause data using the canonical inventory
    - Copilot returns extraction + hash + file metadata to the app
    - The app never reads contract files directly — Copilot is the only
      thing touching the documents

  The app is the system of record:
    - Stores extractions, hashes, versions
    - Runs deterministic parser cross-check
    - Validates against SAP
    - Gates approval workflow
    - Feeds LP solver

  Two scan modes:
    full_scan  — first pass, sends file references to Copilot,
                 Copilot reads and extracts everything, returns hashes
    delta_scan — sends known contract hashes to Copilot,
                 Copilot checks each file, only extracts changed ones,
                 returns new hashes for those that changed

  Configure via environment:
    COPILOT_ENDPOINT  — Copilot service URL (required)
    COPILOT_API_KEY   — API key or bearer token (required)
    COPILOT_MODEL     — model identifier (default: gpt-4o)
    COPILOT_TIMEOUT   — request timeout in ms (default: 120000)
  """

  alias AmmoniaDesk.Contracts.{
    CopilotIngestion,
    Store,
    CurrencyTracker,
    TemplateRegistry
  }

  require Logger

  @pubsub AmmoniaDesk.PubSub
  @topic "contracts"

  @default_timeout 120_000
  @default_model "gpt-4o"

  # ──────────────────────────────────────────────────────────
  # FULL SCAN — initial ingestion, Copilot reads all files
  # ──────────────────────────────────────────────────────────

  @doc """
  Full scan: send file references to Copilot for extraction.

  The app does NOT read the files — Copilot has network access and does:
    1. Read each document from the provided paths/references
    2. Compute SHA-256 hash of the raw file bytes
    3. Extract structured clause data using the canonical inventory
    4. Return extractions + hashes + file metadata

  `file_refs` is a list of file references Copilot can access:

      [
        %{path: "//server/contracts/Koch_FOB_2026.docx", product_group: :ammonia},
        %{path: "//server/contracts/Yara_CFR_2026.pdf", product_group: :ammonia},
        ...
      ]

  Returns a summary. Each successfully extracted contract is ingested
  via CopilotIngestion.ingest_with_hash/2 (hash from Copilot, no local read).
  """
  @spec full_scan([map()], keyword()) :: {:ok, map()} | {:error, term()}
  def full_scan(file_refs, opts \\ []) do
    with {:ok, config} <- get_config() do
      broadcast(:copilot_full_scan_started, %{file_count: length(file_refs)})
      Logger.info("Copilot full scan: #{length(file_refs)} files")

      results =
        Enum.map(file_refs, fn ref ->
          case call_extract(ref, config) do
            {:ok, extraction} ->
              ingest_opts = build_ingest_opts(ref, opts)
              case CopilotIngestion.ingest_with_hash(extraction, ingest_opts) do
                {:ok, contract} ->
                  CurrencyTracker.stamp(contract.id, :copilot_extracted_at)
                  {ref.path, {:ok, contract}}
                {:error, reason} ->
                  {ref.path, {:error, {:ingest_failed, reason}}}
              end

            {:error, reason} ->
              {ref.path, {:error, reason}}
          end
        end)

      succeeded = Enum.count(results, fn {_, r} -> match?({:ok, _}, r) end)
      failed = Enum.count(results, fn {_, r} -> not match?({:ok, _}, r) end)

      failures =
        results
        |> Enum.filter(fn {_, r} -> not match?({:ok, _}, r) end)
        |> Enum.map(fn {path, {:error, reason}} -> {path, reason} end)

      broadcast(:copilot_full_scan_complete, %{
        total: length(file_refs),
        succeeded: succeeded,
        failed: failed
      })

      Logger.info("Copilot full scan complete: #{succeeded}/#{length(file_refs)} succeeded")

      {:ok, %{
        total: length(file_refs),
        succeeded: succeeded,
        failed: failed,
        failures: failures,
        scanned_at: DateTime.utc_now()
      }}
    end
  end

  # ──────────────────────────────────────────────────────────
  # DELTA SCAN — send known hashes, Copilot checks & re-extracts
  # ──────────────────────────────────────────────────────────

  @doc """
  Delta scan: send known contract hashes to Copilot.

  Copilot checks each file on the network:
    - Computes current hash of the file at network_path
    - Compares against the hash the app provided
    - Only extracts files whose hashes differ (document changed)
    - Returns: changed extractions + new hashes, plus a list of unchanged

  This is dramatically faster than full_scan after the initial pass.
  The app sends one request with all known contracts, Copilot returns
  only the delta.

  Flow:
    1. App gathers all contracts for the product group with their stored hashes
    2. App sends {network_path, stored_hash} pairs to Copilot
    3. Copilot checks each file, returns changed extractions + unchanged list
    4. App ingests changed contracts as new versions (hash chain preserved)
  """
  @spec delta_scan(atom(), keyword()) :: {:ok, map()} | {:error, term()}
  def delta_scan(product_group, opts \\ []) do
    with {:ok, config} <- get_config() do
      broadcast(:copilot_delta_scan_started, %{product_group: product_group})
      Logger.info("Copilot delta scan: #{product_group}")

      # Gather all known contracts with their hashes
      contracts = Store.list_by_product_group(product_group)

      known_hashes =
        contracts
        |> Enum.filter(&(&1.network_path && &1.file_hash))
        |> Enum.map(fn c ->
          %{
            contract_id: c.id,
            network_path: c.network_path,
            stored_hash: c.file_hash,
            counterparty: c.counterparty,
            source_file: c.source_file
          }
        end)

      if length(known_hashes) == 0 do
        Logger.info("Delta scan: no contracts with hashes for #{product_group}, nothing to check")

        {:ok, %{
          product_group: product_group,
          unchanged: 0,
          re_extracted: 0,
          failed: 0,
          scanned_at: DateTime.utc_now()
        }}
      else
        case call_delta_check(known_hashes, config) do
          {:ok, delta_result} ->
            process_delta_result(delta_result, product_group, opts)

          {:error, reason} ->
            Logger.error("Copilot delta check failed: #{inspect(reason)}")
            {:error, {:delta_check_failed, reason}}
        end
      end
    end
  end

  @doc "Delta scan across all product groups."
  @spec delta_scan_all(keyword()) :: {:ok, map()}
  def delta_scan_all(opts \\ []) do
    product_groups = [:ammonia, :uan, :urea]

    results =
      Enum.map(product_groups, fn pg ->
        case delta_scan(pg, opts) do
          {:ok, summary} -> {pg, summary}
          {:error, reason} -> {pg, %{error: reason}}
        end
      end)

    {:ok, %{
      by_product_group: Map.new(results),
      scanned_at: DateTime.utc_now()
    }}
  end

  # ──────────────────────────────────────────────────────────
  # ASYNC WRAPPERS — non-blocking for UI
  # ──────────────────────────────────────────────────────────

  @doc "Run full scan in a background BEAM task."
  def full_scan_async(file_refs, opts \\ []) do
    Task.Supervisor.async_nolink(
      AmmoniaDesk.Contracts.TaskSupervisor,
      fn -> full_scan(file_refs, opts) end
    )
  end

  @doc "Run delta scan in a background BEAM task."
  def delta_scan_async(product_group, opts \\ []) do
    Task.Supervisor.async_nolink(
      AmmoniaDesk.Contracts.TaskSupervisor,
      fn -> delta_scan(product_group, opts) end
    )
  end

  @doc "Run delta scan across all product groups in background."
  def delta_scan_all_async(opts \\ []) do
    Task.Supervisor.async_nolink(
      AmmoniaDesk.Contracts.TaskSupervisor,
      fn -> delta_scan_all(opts) end
    )
  end

  # ──────────────────────────────────────────────────────────
  # AVAILABILITY
  # ──────────────────────────────────────────────────────────

  @doc "Check if Copilot service is configured and reachable."
  @spec available?() :: boolean()
  def available? do
    case get_config() do
      {:ok, config} ->
        case Req.get(config.endpoint <> "/health",
               headers: auth_headers(config),
               receive_timeout: 5_000
             ) do
          {:ok, %{status: status}} when status in 200..299 -> true
          _ -> false
        end

      _ ->
        false
    end
  end

  # ──────────────────────────────────────────────────────────
  # COPILOT SERVICE CALLS
  # ──────────────────────────────────────────────────────────

  # Full extraction — Copilot reads the file, hashes it, extracts clauses
  defp call_extract(file_ref, config) do
    body = %{
      action: "extract",
      file_path: file_ref.path,
      model: config.model,
      clause_inventory: clause_inventory_payload(),
      family_signatures: family_signatures_payload(),
      instructions: extraction_instructions()
    }

    case post_to_copilot(config, "/extract", body) do
      {:ok, %{"extraction" => extraction, "file_hash" => hash, "file_size" => size}} ->
        # Merge hash/size into extraction so ingest_with_hash can use them
        enriched = Map.merge(extraction, %{
          "file_hash" => hash,
          "file_size" => size,
          "network_path" => file_ref.path,
          "source_file" => Path.basename(file_ref.path),
          "source_format" => detect_format_string(file_ref.path)
        })
        {:ok, enriched}

      {:ok, %{"clauses" => _} = extraction} ->
        # Copilot returned flat format with hash at top level
        {:ok, Map.put_new(extraction, "network_path", file_ref.path)}

      {:ok, other} ->
        Logger.warning("Unexpected Copilot extract response: #{inspect(Map.keys(other))}")
        {:error, :unexpected_response_format}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Delta check — Copilot checks file hashes, only extracts changed ones
  defp call_delta_check(known_hashes, config) do
    body = %{
      action: "delta_check",
      model: config.model,
      contracts: Enum.map(known_hashes, fn kh ->
        %{
          contract_id: kh.contract_id,
          network_path: kh.network_path,
          stored_hash: kh.stored_hash
        }
      end),
      clause_inventory: clause_inventory_payload(),
      family_signatures: family_signatures_payload(),
      instructions: extraction_instructions()
    }

    post_to_copilot(config, "/delta", body)
  end

  defp post_to_copilot(config, path, body) do
    url = config.endpoint <> path

    case Req.post(url,
           json: body,
           headers: auth_headers(config),
           receive_timeout: timeout()
         ) do
      {:ok, %{status: 200, body: response}} when is_map(response) ->
        {:ok, response}

      {:ok, %{status: 200, body: json_str}} when is_binary(json_str) ->
        case Jason.decode(json_str) do
          {:ok, parsed} -> {:ok, parsed}
          {:error, reason} -> {:error, {:json_parse_failed, reason}}
        end

      {:ok, %{status: status, body: body}} ->
        Logger.error("Copilot service error (#{status}): #{inspect(body)}")
        {:error, {:api_error, status}}

      {:error, reason} ->
        Logger.error("Copilot service unreachable: #{inspect(reason)}")
        {:error, {:api_unreachable, reason}}
    end
  end

  # ──────────────────────────────────────────────────────────
  # DELTA RESULT PROCESSING
  # ──────────────────────────────────────────────────────────

  # Copilot returns:
  #   %{
  #     "changed" => [
  #       %{"contract_id" => "...", "extraction" => %{...}, "file_hash" => "...", "file_size" => 123}
  #     ],
  #     "unchanged" => ["contract_id_1", "contract_id_2", ...],
  #     "not_found" => ["contract_id_3", ...]
  #   }

  defp process_delta_result(delta_result, product_group, opts) do
    changed = Map.get(delta_result, "changed", [])
    unchanged = Map.get(delta_result, "unchanged", [])
    not_found = Map.get(delta_result, "not_found", [])

    broadcast(:copilot_delta_hash_check_complete, %{
      product_group: product_group,
      unchanged: length(unchanged),
      changed: length(changed),
      missing: length(not_found)
    })

    Logger.info(
      "Delta check results: #{length(unchanged)} unchanged, " <>
      "#{length(changed)} changed, #{length(not_found)} missing"
    )

    # Update verification status for unchanged contracts
    Enum.each(unchanged, fn contract_id ->
      Store.update_verification(contract_id, %{
        verification_status: :verified,
        last_verified_at: DateTime.utc_now()
      })
    end)

    # Mark missing contracts
    Enum.each(not_found, fn contract_id ->
      Store.update_verification(contract_id, %{
        verification_status: :file_not_found,
        last_verified_at: DateTime.utc_now()
      })
    end)

    # Ingest changed contracts as new versions
    ingest_results =
      Enum.map(changed, fn entry ->
        extraction = Map.get(entry, "extraction", %{})
        file_hash = Map.get(entry, "file_hash")
        file_size = Map.get(entry, "file_size")
        contract_id = Map.get(entry, "contract_id")

        enriched = Map.merge(extraction, %{
          "file_hash" => file_hash,
          "file_size" => file_size
        })

        # Get existing contract to carry forward metadata
        ingest_opts = case Store.get(contract_id) do
          {:ok, existing} ->
            [
              product_group: existing.product_group,
              network_path: existing.network_path,
              sap_contract_id: existing.sap_contract_id
            ] ++ Keyword.take(opts, [:product_group])

          _ ->
            [product_group: product_group]
        end

        case CopilotIngestion.ingest_with_hash(enriched, ingest_opts) do
          {:ok, new_contract} ->
            CurrencyTracker.stamp(new_contract.id, :copilot_re_extracted_at)

            Logger.info(
              "Delta re-extraction: #{new_contract.counterparty} " <>
              "(hash=#{String.slice(file_hash || "", 0, 12)}...)"
            )

            {:ok, new_contract}

          {:error, reason} ->
            Logger.warning("Delta ingest failed for #{contract_id}: #{inspect(reason)}")
            {:error, {:ingest_failed, reason}}
        end
      end)

    succeeded = Enum.count(ingest_results, &match?({:ok, _}, &1))
    failed = Enum.count(ingest_results, &(not match?({:ok, _}, &1)))

    broadcast(:copilot_delta_scan_complete, %{
      product_group: product_group,
      unchanged: length(unchanged),
      re_extracted: succeeded,
      failed: failed,
      missing: length(not_found)
    })

    Logger.info(
      "Delta scan complete: #{length(unchanged)} current, " <>
      "#{succeeded} re-extracted, #{failed} failed, #{length(not_found)} missing"
    )

    {:ok, %{
      product_group: product_group,
      unchanged: length(unchanged),
      re_extracted: succeeded,
      failed: failed,
      missing: length(not_found),
      scanned_at: DateTime.utc_now()
    }}
  end

  # ──────────────────────────────────────────────────────────
  # PAYLOADS — canonical inventory sent to Copilot as context
  # ──────────────────────────────────────────────────────────

  defp clause_inventory_payload do
    TemplateRegistry.canonical_clauses()
    |> Enum.map(fn {clause_id, definition} ->
      %{
        clause_id: clause_id,
        category: definition.category,
        anchors: definition.anchors,
        extract_fields: definition.extract_fields,
        lp_mapping: definition[:lp_mapping],
        level_default: definition[:level_default]
      }
    end)
  end

  defp family_signatures_payload do
    TemplateRegistry.family_signatures()
    |> Enum.map(fn {family_id, family} ->
      %{
        family_id: family_id,
        direction: family.direction,
        term_type: family.term_type,
        transport: family.transport,
        default_incoterms: family.default_incoterms,
        detect_anchors: family.detect_anchors,
        expected_clause_ids: family.expected_clause_ids
      }
    end)
  end

  defp extraction_instructions do
    """
    Extract all clauses from the contract document. For each file:
    1. Read the document bytes and compute SHA-256 hash (hex, lowercase)
    2. Extract the document text
    3. Identify all clauses, mapping to the provided clause inventory where possible
    4. For clauses not in the inventory, create new definitions
    5. Return the extraction payload with file_hash and file_size included

    Be precise with numerical values. Preserve original units and currencies.
    Set confidence to "low" for uncertain extractions.
    Include exact source_text from the contract for each clause.
    """
  end

  # ──────────────────────────────────────────────────────────
  # HELPERS
  # ──────────────────────────────────────────────────────────

  defp build_ingest_opts(file_ref, opts) do
    default_pg = Keyword.get(opts, :product_group, :ammonia)

    [
      product_group: file_ref[:product_group] || default_pg,
      network_path: file_ref.path,
      sap_contract_id: file_ref[:sap_contract_id]
    ]
  end

  defp detect_format_string(path) do
    case Path.extname(path) |> String.downcase() do
      ".pdf" -> "pdf"
      ".docx" -> "docx"
      ".docm" -> "docm"
      ".txt" -> "txt"
      ext -> ext
    end
  end

  defp get_config do
    endpoint = System.get_env("COPILOT_ENDPOINT")
    api_key = System.get_env("COPILOT_API_KEY")

    cond do
      is_nil(endpoint) or endpoint == "" ->
        {:error, :endpoint_not_configured}

      is_nil(api_key) or api_key == "" ->
        {:error, :api_key_not_configured}

      true ->
        {:ok, %{
          endpoint: String.trim_trailing(endpoint, "/"),
          api_key: api_key,
          model: System.get_env("COPILOT_MODEL") || @default_model
        }}
    end
  end

  defp auth_headers(%{api_key: key}) do
    [{"authorization", "Bearer #{key}"}]
  end

  defp timeout do
    case System.get_env("COPILOT_TIMEOUT") do
      nil -> @default_timeout
      val ->
        case Integer.parse(val) do
          {n, _} -> n
          :error -> @default_timeout
        end
    end
  end

  defp broadcast(event, payload) do
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:contract_event, event, payload})
  end
end
