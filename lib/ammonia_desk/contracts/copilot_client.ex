defmodule AmmoniaDesk.Contracts.CopilotClient do
  @moduledoc """
  HTTP client for Microsoft 365 Copilot as the primary contract extraction service.

  Architecture:
    - Copilot reads actual contract documents and extracts structured clause data
    - This module sends contract text + the canonical clause inventory as context
    - Copilot returns structured JSON matching the CopilotIngestion payload format
    - The app is the system of record (hashing, versioning, validation, LP mapping)

  Delta extraction:
    - First pass scans all contracts (slow — Copilot reads every document)
    - Subsequent passes check document hashes against network copies
    - Only changed documents (hash mismatch) are sent to Copilot for re-extraction
    - Verified documents keep their existing extraction data

  Configure via environment:
    COPILOT_ENDPOINT  — Copilot API endpoint (required)
    COPILOT_API_KEY   — API key or bearer token (required)
    COPILOT_MODEL     — model identifier (default: gpt-4o)
    COPILOT_TIMEOUT   — request timeout in ms (default: 120000)
  """

  alias AmmoniaDesk.Contracts.{
    CopilotIngestion,
    DocumentReader,
    HashVerifier,
    Store,
    CurrencyTracker,
    TemplateRegistry
  }

  require Logger

  @pubsub AmmoniaDesk.PubSub
  @topic "contracts"

  @default_timeout 120_000
  @default_model "gpt-4o"
  @max_concurrency 3

  # ──────────────────────────────────────────────────────────
  # SINGLE CONTRACT EXTRACTION
  # ──────────────────────────────────────────────────────────

  @doc """
  Send a single contract document to Copilot for extraction.

  1. Reads the document text locally
  2. Builds a structured prompt with the clause inventory
  3. Sends to Copilot API
  4. Parses the response into CopilotIngestion format
  5. Ingests via CopilotIngestion (hashing, versioning, cross-check)

  Returns {:ok, contract} or {:error, reason}.
  """
  @spec extract(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def extract(file_path, opts \\ []) do
    with {:config, {:ok, config}} <- {:config, get_config()},
         {:read, {:ok, text}} <- {:read, DocumentReader.read(file_path)},
         {:copilot, {:ok, extraction}} <- {:copilot, call_copilot(text, config)} do
      CopilotIngestion.ingest(file_path, extraction, opts)
    else
      {:config, {:error, reason}} -> {:error, {:copilot_not_configured, reason}}
      {:read, {:error, reason}} -> {:error, {:document_read_failed, reason}}
      {:copilot, {:error, reason}} -> {:error, {:copilot_extraction_failed, reason}}
    end
  end

  @doc """
  Send a contract to Copilot and return the raw extraction payload
  without ingesting. Useful for preview/review before committing.
  """
  @spec extract_preview(String.t()) :: {:ok, map()} | {:error, term()}
  def extract_preview(file_path) do
    with {:ok, config} <- get_config(),
         {:ok, text} <- DocumentReader.read(file_path) do
      call_copilot(text, config)
    end
  end

  # ──────────────────────────────────────────────────────────
  # FULL SCAN — first pass, all contracts
  # ──────────────────────────────────────────────────────────

  @doc """
  Full scan of all contract files in a directory.
  This is the initial pass — sends every document to Copilot.

  `manifest` maps filenames to metadata:
    %{
      "contract_file.docx" => %{
        product_group: :ammonia,
        network_path: "/shared/contracts/contract_file.docx"
      }
    }

  Returns a summary of extraction results.
  """
  @spec full_scan(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def full_scan(dir_path, manifest \\ %{}, opts \\ []) do
    with {:ok, config} <- get_config() do
      unless File.dir?(dir_path) do
        {:error, :directory_not_found}
      else
        supported = ~w(.pdf .docx .docm .txt)

        files =
          File.ls!(dir_path)
          |> Enum.filter(fn f -> Path.extname(f) in supported end)
          |> Enum.sort()

        broadcast(:copilot_full_scan_started, %{
          directory: dir_path,
          file_count: length(files)
        })

        Logger.info("Copilot full scan: #{length(files)} files in #{dir_path}")

        results =
          files
          |> Task.async_stream(
            fn filename ->
              file_path = Path.join(dir_path, filename)
              file_opts = build_file_opts(filename, file_path, manifest, opts)

              case extract_single(file_path, config, file_opts) do
                {:ok, contract} -> {filename, {:ok, contract}}
                {:error, reason} -> {filename, {:error, reason}}
              end
            end,
            max_concurrency: @max_concurrency,
            timeout: timeout() * 2
          )
          |> Enum.map(fn
            {:ok, result} -> result
            {:exit, reason} -> {"unknown", {:error, {:task_failed, reason}}}
          end)

        succeeded = Enum.count(results, fn {_, r} -> match?({:ok, _}, r) end)
        failed = Enum.count(results, fn {_, r} -> not match?({:ok, _}, r) end)

        failures =
          results
          |> Enum.filter(fn {_, r} -> not match?({:ok, _}, r) end)
          |> Enum.map(fn {f, {:error, reason}} -> {f, reason} end)

        broadcast(:copilot_full_scan_complete, %{
          directory: dir_path,
          total: length(files),
          succeeded: succeeded,
          failed: failed
        })

        Logger.info("Copilot full scan complete: #{succeeded}/#{length(files)} succeeded")

        {:ok, %{
          directory: dir_path,
          total: length(files),
          succeeded: succeeded,
          failed: failed,
          failures: failures,
          scanned_at: DateTime.utc_now()
        }}
      end
    end
  end

  # ──────────────────────────────────────────────────────────
  # DELTA SCAN — only re-extract changed contracts
  # ──────────────────────────────────────────────────────────

  @doc """
  Delta scan: check which contracts have changed since last extraction
  and only send those to Copilot.

  Flow:
    1. Hash-verify all contracts in the product group against network copies
    2. Filter to only mismatches and new files
    3. Send only changed documents to Copilot for re-extraction
    4. Re-ingest changed contracts (new version, preserving history)

  This is dramatically faster than a full scan after the initial pass.
  Returns a summary including which contracts were unchanged vs re-extracted.
  """
  @spec delta_scan(atom(), keyword()) :: {:ok, map()} | {:error, term()}
  def delta_scan(product_group, opts \\ []) do
    with {:ok, config} <- get_config() do
      broadcast(:copilot_delta_scan_started, %{product_group: product_group})

      Logger.info("Copilot delta scan: checking hashes for #{product_group}")

      # Step 1: Verify all contract hashes against network copies
      {:ok, verification} = HashVerifier.verify_product_group(product_group)

      unchanged = verification.verified
      mismatches = verification.mismatch_details
      not_found = verification.file_not_found

      Logger.info(
        "Delta scan hash check: #{unchanged} unchanged, " <>
        "#{length(mismatches)} changed, #{not_found} missing"
      )

      broadcast(:copilot_delta_hash_check_complete, %{
        product_group: product_group,
        unchanged: unchanged,
        changed: length(mismatches),
        missing: not_found
      })

      # Step 2: Re-extract only changed contracts
      if length(mismatches) == 0 do
        broadcast(:copilot_delta_scan_complete, %{
          product_group: product_group,
          unchanged: unchanged,
          re_extracted: 0,
          failed: 0
        })

        Logger.info("Delta scan complete: all contracts current, nothing to re-extract")

        {:ok, %{
          product_group: product_group,
          unchanged: unchanged,
          re_extracted: 0,
          failed: 0,
          details: [],
          scanned_at: DateTime.utc_now()
        }}
      else
        results =
          mismatches
          |> Task.async_stream(
            fn mismatch ->
              contract_id = mismatch.contract_id
              re_extract_contract(contract_id, config, opts)
            end,
            max_concurrency: @max_concurrency,
            timeout: timeout() * 2
          )
          |> Enum.map(fn
            {:ok, result} -> result
            {:exit, reason} -> {:error, {:task_failed, reason}}
          end)

        succeeded = Enum.count(results, &match?({:ok, _}, &1))
        failed = Enum.count(results, &(not match?({:ok, _}, &1)))

        broadcast(:copilot_delta_scan_complete, %{
          product_group: product_group,
          unchanged: unchanged,
          re_extracted: succeeded,
          failed: failed
        })

        Logger.info(
          "Delta scan complete: #{unchanged} unchanged, " <>
          "#{succeeded} re-extracted, #{failed} failed"
        )

        {:ok, %{
          product_group: product_group,
          unchanged: unchanged,
          re_extracted: succeeded,
          failed: failed,
          details: results,
          scanned_at: DateTime.utc_now()
        }}
      end
    end
  end

  @doc """
  Delta scan across all product groups.
  Checks every ingested contract against its network copy.
  """
  @spec delta_scan_all(keyword()) :: {:ok, map()}
  def delta_scan_all(opts \\ []) do
    product_groups = [:ammonia, :uan, :urea]

    results =
      Enum.map(product_groups, fn pg ->
        {:ok, summary} = delta_scan(pg, opts)
        {pg, summary}
      end)

    total_unchanged = Enum.sum(Enum.map(results, fn {_, s} -> s.unchanged end))
    total_re_extracted = Enum.sum(Enum.map(results, fn {_, s} -> s.re_extracted end))

    {:ok, %{
      by_product_group: Map.new(results),
      total_unchanged: total_unchanged,
      total_re_extracted: total_re_extracted,
      scanned_at: DateTime.utc_now()
    }}
  end

  # ──────────────────────────────────────────────────────────
  # ASYNC WRAPPERS — for non-blocking UI integration
  # ──────────────────────────────────────────────────────────

  @doc "Run full scan in a background BEAM task."
  def full_scan_async(dir_path, manifest \\ %{}, opts \\ []) do
    Task.Supervisor.async_nolink(
      AmmoniaDesk.Contracts.TaskSupervisor,
      fn -> full_scan(dir_path, manifest, opts) end
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
  # AVAILABILITY CHECK
  # ──────────────────────────────────────────────────────────

  @doc "Check if Copilot API is configured and reachable."
  @spec available?() :: boolean()
  def available? do
    case get_config() do
      {:ok, config} ->
        case Req.get(config.endpoint <> "/models",
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
  # COPILOT API INTERACTION
  # ──────────────────────────────────────────────────────────

  defp call_copilot(contract_text, config) do
    prompt = build_extraction_prompt(contract_text)

    body = %{
      model: config.model,
      messages: [
        %{role: "system", content: system_prompt()},
        %{role: "user", content: prompt}
      ],
      temperature: 0.1,
      response_format: %{type: "json_object"}
    }

    case Req.post(config.endpoint <> "/chat/completions",
           json: body,
           headers: auth_headers(config),
           receive_timeout: timeout()
         ) do
      {:ok, %{status: 200, body: %{"choices" => [%{"message" => %{"content" => json_str}} | _]}}} ->
        parse_copilot_response(json_str)

      {:ok, %{status: status, body: body}} ->
        Logger.error("Copilot API error (#{status}): #{inspect(body)}")
        {:error, {:api_error, status}}

      {:error, reason} ->
        Logger.error("Copilot API unreachable: #{inspect(reason)}")
        {:error, {:api_unreachable, reason}}
    end
  end

  defp system_prompt do
    clause_inventory = build_clause_inventory_context()

    """
    You are a contract extraction specialist for Trammo's ammonia trading desk.
    Your task is to read commodity trading contracts and extract structured clause data.

    You MUST return a JSON object with the exact structure specified in the user prompt.
    Be precise with numerical values — extract exact numbers from the contract text.
    Preserve original units and currency symbols.

    ## Known Clause Inventory

    The following clause types are expected in ammonia trading contracts.
    Map extracted clauses to these IDs where they match. If you find clauses
    that don't fit any known type, include them with a new clause_id and add
    the definition to "new_clause_definitions".

    #{clause_inventory}

    ## Known Contract Families

    #{build_family_context()}

    When you identify the contract family, set the "family_id" field accordingly.
    """
  end

  defp build_extraction_prompt(contract_text) do
    """
    Extract all clauses from the following contract. Return a JSON object with this structure:

    {
      "contract_number": "extracted contract number or null",
      "counterparty": "counterparty name",
      "counterparty_type": "supplier" or "customer",
      "direction": "purchase" or "sale",
      "incoterm": "FOB" or "CFR" or "CIF" or "DAP" or "CPT" etc.,
      "term_type": "spot" or "long_term",
      "company": "trammo_inc" or "trammo_sas" or "trammo_dmcc",
      "effective_date": "YYYY-MM-DD or null",
      "expiry_date": "YYYY-MM-DD or null",
      "family_id": "matched family ID or null",
      "clauses": [
        {
          "clause_id": "PRICE",
          "category": "commercial",
          "extracted_fields": {
            "price_value": 340.00,
            "price_uom": "$/ton",
            "pricing_mechanism": "fixed"
          },
          "source_text": "exact text from the contract for this clause",
          "section_ref": "Section 5",
          "confidence": "high" or "medium" or "low",
          "anchors_matched": ["Price", "US $"]
        }
      ],
      "new_clause_definitions": [
        {
          "clause_id": "NEW_CLAUSE_ID",
          "category": "category_name",
          "anchors": ["anchor1", "anchor2"],
          "extract_fields": ["field1", "field2"],
          "lp_mapping": null,
          "level_default": "expected"
        }
      ]
    }

    Rules:
    - Extract EVERY clause you can identify, not just the known types
    - For each clause, include the exact source_text from the contract
    - Extract numerical values precisely (prices, quantities, percentages, rates)
    - Set confidence to "low" if the extraction is uncertain
    - Include section_ref if the clause has a numbered section heading
    - anchors_matched should list which anchor patterns from the inventory matched
    - new_clause_definitions should only include clauses NOT in the known inventory
    - If you cannot determine a field, set it to null rather than guessing

    CONTRACT TEXT:
    ---
    #{contract_text}
    ---
    """
  end

  defp build_clause_inventory_context do
    TemplateRegistry.canonical_clauses()
    |> Enum.sort_by(fn {id, _} -> id end)
    |> Enum.map(fn {clause_id, def} ->
      fields = Map.get(def, :extract_fields, []) |> Enum.join(", ")
      anchors = Map.get(def, :anchors, []) |> Enum.join(", ")
      category = Map.get(def, :category, :unknown)

      "- #{clause_id} (#{category}): anchors=[#{anchors}], fields=[#{fields}]"
    end)
    |> Enum.join("\n")
  end

  defp build_family_context do
    TemplateRegistry.family_signatures()
    |> Enum.sort_by(fn {id, _} -> id end)
    |> Enum.map(fn {family_id, family} ->
      anchors = Map.get(family, :detect_anchors, []) |> Enum.join(", ")
      dir = Map.get(family, :direction, :unknown)
      term = Map.get(family, :term_type, :unknown)
      transport = Map.get(family, :transport, :unknown)
      incoterms = Map.get(family, :default_incoterms, []) |> Enum.join(", ")

      "- #{family_id}: #{dir}/#{term}/#{transport}, incoterms=[#{incoterms}], detect=[#{anchors}]"
    end)
    |> Enum.join("\n")
  end

  defp parse_copilot_response(json_str) do
    case Jason.decode(json_str) do
      {:ok, %{"clauses" => clauses} = extraction} when is_list(clauses) ->
        {:ok, extraction}

      {:ok, other} ->
        Logger.warning("Copilot response missing 'clauses' key: #{inspect(Map.keys(other))}")
        {:error, :invalid_extraction_format}

      {:error, reason} ->
        Logger.error("Failed to parse Copilot JSON: #{inspect(reason)}")
        {:error, {:json_parse_failed, reason}}
    end
  end

  # ──────────────────────────────────────────────────────────
  # PRIVATE HELPERS
  # ──────────────────────────────────────────────────────────

  defp extract_single(file_path, config, opts) do
    with {:ok, text} <- DocumentReader.read(file_path),
         {:ok, extraction} <- call_copilot(text, config) do
      CopilotIngestion.ingest(file_path, extraction, opts)
    end
  end

  defp re_extract_contract(contract_id, config, opts) do
    with {:ok, contract} <- Store.get(contract_id),
         {:ok, path} <- resolve_network_path(contract),
         {:ok, text} <- DocumentReader.read(path),
         {:ok, extraction} <- call_copilot(text, config) do
      # Carry forward metadata
      file_opts =
        [
          product_group: contract.product_group,
          network_path: contract.network_path,
          sap_contract_id: contract.sap_contract_id
        ] ++ Keyword.take(opts, [:product_group])

      case CopilotIngestion.ingest(path, extraction, file_opts) do
        {:ok, new_contract} ->
          CurrencyTracker.stamp(new_contract.id, :copilot_re_extracted_at)

          Logger.info(
            "Delta re-extraction complete: #{contract.counterparty} " <>
            "v#{contract.version} → v#{new_contract.version}"
          )

          {:ok, new_contract}

        {:error, reason} ->
          {:error, {:reingest_failed, reason}}
      end
    end
  end

  defp resolve_network_path(%{network_path: nil}), do: {:error, :no_network_path}
  defp resolve_network_path(%{network_path: ""}), do: {:error, :no_network_path}
  defp resolve_network_path(%{network_path: path}) do
    if File.exists?(path), do: {:ok, path}, else: {:error, :file_not_found}
  end

  defp build_file_opts(filename, file_path, manifest, opts) do
    default_pg = Keyword.get(opts, :product_group, :ammonia)

    case Map.get(manifest, filename) do
      %{} = entry ->
        [
          product_group: entry[:product_group] || default_pg,
          network_path: entry[:network_path] || file_path,
          sap_contract_id: entry[:sap_contract_id]
        ]

      nil ->
        [
          product_group: default_pg,
          network_path: file_path
        ]
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
