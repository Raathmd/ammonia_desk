defmodule AmmoniaDesk.Contracts.CopilotClient do
  @moduledoc """
  Orchestrates contract extraction using two services:

    1. **Zig NetworkScanner** (via Port) — file I/O, hashing, Graph API
       - Scans SharePoint folders for contract files
       - Checks file hashes via Graph API (no download for delta checks)
       - Downloads changed files and computes SHA-256 on raw bytes
       - Returns file content + hash to Elixir

    2. **Copilot LLM** (via HTTP) — clause extraction
       - Receives document text + canonical clause inventory
       - Returns structured clause data as JSON
       - Only called for files that need extraction (new or changed)

  The app never reads contract files. The Zig scanner handles all file I/O
  and hashing. The LLM only sees extracted text, never raw bytes.

  ```
  SharePoint ←── Graph API ──→ Zig scanner ←── Port ──→ CopilotClient
                                (SHA-256)                     │
                                (file I/O)              ┌─────┴─────┐
                                                        │           │
                                                   LLM API    CopilotIngestion
                                                  (extraction)  (system of record)
  ```

  Two scan modes:
    full_scan  — scanner lists folder, fetches all files, LLM extracts each
    delta_scan — scanner checks hashes via Graph API metadata (no download),
                 only fetches + extracts files where hash changed

  Configure via environment:
    COPILOT_ENDPOINT  — LLM API endpoint (required)
    COPILOT_API_KEY   — LLM API key (required)
    COPILOT_MODEL     — model identifier (default: gpt-4o)
    COPILOT_TIMEOUT   — request timeout in ms (default: 120000)
    GRAPH_TENANT_ID   — Azure AD tenant (for scanner auth)
    GRAPH_CLIENT_ID   — App registration client ID
    GRAPH_CLIENT_SECRET — App registration secret
    GRAPH_DRIVE_ID    — SharePoint document library drive ID
  """

  alias AmmoniaDesk.Contracts.{
    CopilotIngestion,
    DocumentReader,
    NetworkScanner,
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
  # FULL SCAN — scanner lists folder, fetches all, LLM extracts
  # ──────────────────────────────────────────────────────────

  @doc """
  Full scan: discover and extract all contracts in a SharePoint folder.

  1. Zig scanner lists files in the folder via Graph API
  2. For each file, scanner downloads content + computes SHA-256
  3. Elixir extracts text from the binary (DocumentReader)
  4. Text + clause inventory sent to Copilot LLM for extraction
  5. Extraction + hash ingested via CopilotIngestion

  `folder_path` is the SharePoint folder, e.g. "/Contracts/Ammonia".
  """
  @spec full_scan(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def full_scan(folder_path, opts \\ []) do
    with {:config, {:ok, config}} <- {:config, get_config()},
         {:scanner, true} <- {:scanner, NetworkScanner.available?()} do

      broadcast(:copilot_full_scan_started, %{folder: folder_path})
      Logger.info("Full scan: listing files in #{folder_path}")

      # Step 1: Scanner lists files in folder via Graph API
      case NetworkScanner.scan_folder(folder_path, opts) do
        {:ok, %{"files" => files}} ->
          Logger.info("Full scan: found #{length(files)} contract files")

          # Step 2-5: Fetch, extract text, send to LLM, ingest
          results =
            Enum.map(files, fn file_meta ->
              process_file(file_meta, config, opts)
            end)

          summarize_results(results, folder_path)

        {:ok, %{"file_count" => 0}} ->
          {:ok, %{total: 0, succeeded: 0, failed: 0, folder: folder_path,
                  scanned_at: DateTime.utc_now()}}

        {:error, reason} ->
          {:error, {:scan_failed, reason}}
      end
    else
      {:config, {:error, reason}} -> {:error, {:copilot_not_configured, reason}}
      {:scanner, false} -> {:error, :scanner_not_available}
    end
  end

  # ──────────────────────────────────────────────────────────
  # DELTA SCAN — scanner checks hashes, only re-extracts changed
  # ──────────────────────────────────────────────────────────

  @doc """
  Delta scan: check which contracts changed and only re-extract those.

  1. App gathers all contracts for the product group with stored hashes
  2. Zig scanner checks each file's current hash via Graph API metadata
     (NO file download — just metadata request, very fast)
  3. Scanner returns changed/unchanged/missing lists
  4. For changed files only: scanner downloads, Elixir extracts text,
     LLM extracts clauses, app ingests new version
  5. Unchanged contracts marked as verified

  This is the "any contracts changed?" check the user described.
  First scan is slow (full_scan). Every scan after is fast (delta_scan).
  """
  @spec delta_scan(atom(), keyword()) :: {:ok, map()} | {:error, term()}
  def delta_scan(product_group, opts \\ []) do
    with {:config, {:ok, config}} <- {:config, get_config()},
         {:scanner, true} <- {:scanner, NetworkScanner.available?()} do

      broadcast(:copilot_delta_scan_started, %{product_group: product_group})
      Logger.info("Delta scan: #{product_group}")

      # Gather contracts with Graph item IDs and stored hashes
      contracts = Store.list_by_product_group(product_group)

      checkable =
        contracts
        |> Enum.filter(fn c -> c.file_hash && graph_item_id(c) end)
        |> Enum.map(fn c ->
          %{
            contract_id: c.id,
            drive_id: graph_drive_id(c),
            item_id: graph_item_id(c),
            stored_hash: c.file_hash
          }
        end)

      if length(checkable) == 0 do
        Logger.info("Delta scan: no contracts with Graph IDs for #{product_group}")
        {:ok, %{product_group: product_group, unchanged: 0, re_extracted: 0,
                failed: 0, scanned_at: DateTime.utc_now()}}
      else
        # Scanner checks hashes via Graph API (metadata only, no downloads)
        case NetworkScanner.check_hashes(checkable) do
          {:ok, hash_result} ->
            process_delta_result(hash_result, product_group, config, opts)

          {:error, reason} ->
            {:error, {:hash_check_failed, reason}}
        end
      end
    else
      {:config, {:error, reason}} -> {:error, {:copilot_not_configured, reason}}
      {:scanner, false} -> {:error, :scanner_not_available}
    end
  end

  @doc "Delta scan across all product groups."
  def delta_scan_all(opts \\ []) do
    results =
      Enum.map([:ammonia, :uan, :urea], fn pg ->
        case delta_scan(pg, opts) do
          {:ok, summary} -> {pg, summary}
          {:error, reason} -> {pg, %{error: reason}}
        end
      end)

    {:ok, %{by_product_group: Map.new(results), scanned_at: DateTime.utc_now()}}
  end

  # ──────────────────────────────────────────────────────────
  # ASYNC WRAPPERS
  # ──────────────────────────────────────────────────────────

  def full_scan_async(folder_path, opts \\ []) do
    Task.Supervisor.async_nolink(
      AmmoniaDesk.Contracts.TaskSupervisor,
      fn -> full_scan(folder_path, opts) end
    )
  end

  def delta_scan_async(product_group, opts \\ []) do
    Task.Supervisor.async_nolink(
      AmmoniaDesk.Contracts.TaskSupervisor,
      fn -> delta_scan(product_group, opts) end
    )
  end

  def delta_scan_all_async(opts \\ []) do
    Task.Supervisor.async_nolink(
      AmmoniaDesk.Contracts.TaskSupervisor,
      fn -> delta_scan_all(opts) end
    )
  end

  # ──────────────────────────────────────────────────────────
  # AVAILABILITY
  # ──────────────────────────────────────────────────────────

  @doc "Check if both scanner and LLM are available."
  def available? do
    scanner_ok = NetworkScanner.available?()
    llm_ok = case get_config() do
      {:ok, config} ->
        case Req.get(config.endpoint <> "/models",
               headers: auth_headers(config),
               receive_timeout: 5_000) do
          {:ok, %{status: s}} when s in 200..299 -> true
          _ -> false
        end
      _ -> false
    end

    %{scanner: scanner_ok, llm: llm_ok, ready: scanner_ok and llm_ok}
  end

  # ──────────────────────────────────────────────────────────
  # FULL SCAN — process a single file
  # ──────────────────────────────────────────────────────────

  defp process_file(file_meta, config, opts) do
    drive_id = file_meta["drive_id"]
    item_id = file_meta["item_id"]
    name = file_meta["name"]
    graph_hash = file_meta["sha256"]

    Logger.info("Processing: #{name}")

    # Step 2: Scanner downloads file content + computes SHA-256
    case NetworkScanner.fetch_file(drive_id, item_id) do
      {:ok, %{"content" => content, "sha256" => sha256, "size" => size}} ->
        # Step 3: Extract text from binary content
        case extract_text_from_binary(content, name) do
          {:ok, text} ->
            # Step 4: Send text to Copilot LLM for clause extraction
            case call_copilot_llm(text, config) do
              {:ok, extraction} ->
                # Enrich with hash + file metadata from scanner
                enriched = Map.merge(extraction, %{
                  "file_hash" => sha256,
                  "file_size" => size,
                  "source_file" => name,
                  "source_format" => detect_format(name),
                  "graph_item_id" => item_id,
                  "graph_drive_id" => drive_id,
                  "graph_hash" => graph_hash
                })

                # Step 5: Ingest via CopilotIngestion
                ingest_opts = [
                  product_group: Keyword.get(opts, :product_group, :ammonia)
                ]

                case CopilotIngestion.ingest_with_hash(enriched, ingest_opts) do
                  {:ok, contract} ->
                    CurrencyTracker.stamp(contract.id, :copilot_extracted_at)
                    {name, {:ok, contract}}

                  {:error, reason} ->
                    {name, {:error, {:ingest_failed, reason}}}
                end

              {:error, reason} ->
                {name, {:error, {:llm_extraction_failed, reason}}}
            end

          {:error, reason} ->
            {name, {:error, {:text_extraction_failed, reason}}}
        end

      {:error, reason} ->
        {name, {:error, {:fetch_failed, reason}}}
    end
  end

  # ──────────────────────────────────────────────────────────
  # DELTA SCAN — process hash check results
  # ──────────────────────────────────────────────────────────

  defp process_delta_result(hash_result, product_group, config, opts) do
    changed = Map.get(hash_result, "changed", [])
    unchanged = Map.get(hash_result, "unchanged", [])
    errors = Map.get(hash_result, "errors", [])

    broadcast(:copilot_delta_hash_check_complete, %{
      product_group: product_group,
      unchanged: length(unchanged),
      changed: length(changed),
      errors: length(errors)
    })

    Logger.info(
      "Delta hash check: #{length(unchanged)} current, " <>
      "#{length(changed)} changed, #{length(errors)} errors"
    )

    # Mark unchanged as verified
    Enum.each(unchanged, fn entry ->
      cid = entry["contract_id"]
      Store.update_verification(cid, %{
        verification_status: :verified,
        last_verified_at: DateTime.utc_now()
      })
    end)

    # Fetch + re-extract changed files
    ingest_results =
      Enum.map(changed, fn entry ->
        re_extract_changed(entry, config, product_group, opts)
      end)

    succeeded = Enum.count(ingest_results, &match?({:ok, _}, &1))
    failed = Enum.count(ingest_results, &(not match?({:ok, _}, &1)))

    broadcast(:copilot_delta_scan_complete, %{
      product_group: product_group,
      unchanged: length(unchanged),
      re_extracted: succeeded,
      failed: failed
    })

    Logger.info(
      "Delta scan complete: #{length(unchanged)} current, " <>
      "#{succeeded} re-extracted, #{failed} failed"
    )

    {:ok, %{
      product_group: product_group,
      unchanged: length(unchanged),
      re_extracted: succeeded,
      failed: failed,
      errors: length(errors),
      scanned_at: DateTime.utc_now()
    }}
  end

  defp re_extract_changed(entry, config, product_group, opts) do
    contract_id = entry["contract_id"]
    drive_id = entry["drive_id"]
    item_id = entry["item_id"]

    # Fetch the changed file
    case NetworkScanner.fetch_file(drive_id, item_id) do
      {:ok, %{"content" => content, "sha256" => sha256, "size" => size}} ->
        # Get existing contract for metadata
        existing = case Store.get(contract_id) do
          {:ok, c} -> c
          _ -> nil
        end

        name = if existing, do: existing.source_file, else: "unknown"

        case extract_text_from_binary(content, name) do
          {:ok, text} ->
            case call_copilot_llm(text, config) do
              {:ok, extraction} ->
                enriched = Map.merge(extraction, %{
                  "file_hash" => sha256,
                  "file_size" => size,
                  "graph_item_id" => item_id,
                  "graph_drive_id" => drive_id
                })

                ingest_opts =
                  if existing do
                    [
                      product_group: existing.product_group,
                      network_path: existing.network_path,
                      sap_contract_id: existing.sap_contract_id
                    ]
                  else
                    [product_group: product_group]
                  end

                case CopilotIngestion.ingest_with_hash(enriched, ingest_opts) do
                  {:ok, new_contract} ->
                    CurrencyTracker.stamp(new_contract.id, :copilot_re_extracted_at)
                    Logger.info("Delta re-extracted: #{new_contract.counterparty}")
                    {:ok, new_contract}

                  {:error, reason} ->
                    {:error, {:ingest_failed, reason}}
                end

              {:error, reason} -> {:error, {:llm_failed, reason}}
            end

          {:error, reason} -> {:error, {:text_extraction_failed, reason}}
        end

      {:error, reason} -> {:error, {:fetch_failed, reason}}
    end
  end

  # ──────────────────────────────────────────────────────────
  # TEXT EXTRACTION — convert binary content to text for LLM
  # ──────────────────────────────────────────────────────────
  #
  # The scanner returns raw file bytes. We need to extract text
  # before sending to the LLM. We write the bytes to a temp file
  # and use DocumentReader (which handles PDF, DOCX, DOCM, TXT).

  defp extract_text_from_binary(content, filename) do
    ext = Path.extname(filename)
    tmp_path = Path.join(System.tmp_dir!(), "scanner_#{:erlang.unique_integer([:positive])}#{ext}")

    try do
      File.write!(tmp_path, content)
      DocumentReader.read(tmp_path)
    after
      File.rm(tmp_path)
    end
  end

  # ──────────────────────────────────────────────────────────
  # COPILOT LLM CALL — clause extraction from text
  # ──────────────────────────────────────────────────────────

  defp call_copilot_llm(contract_text, config) do
    body = %{
      model: config.model,
      messages: [
        %{role: "system", content: system_prompt()},
        %{role: "user", content: extraction_prompt(contract_text)}
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
        parse_llm_response(json_str)

      {:ok, %{status: status, body: body}} ->
        Logger.error("LLM API error (#{status}): #{inspect(body)}")
        {:error, {:api_error, status}}

      {:error, reason} ->
        Logger.error("LLM API unreachable: #{inspect(reason)}")
        {:error, {:api_unreachable, reason}}
    end
  end

  defp system_prompt do
    inventory = clause_inventory_text()
    families = family_signatures_text()

    """
    You are a contract extraction specialist for Trammo's ammonia trading desk.
    Extract structured clause data from commodity trading contracts.

    Return a JSON object with the exact structure specified in the user prompt.
    Be precise with numerical values. Preserve original units and currencies.

    ## Known Clause Inventory
    #{inventory}

    ## Known Contract Families
    #{families}
    """
  end

  defp extraction_prompt(contract_text) do
    """
    Extract all clauses from this contract. Return JSON:

    {
      "contract_number": "string or null",
      "counterparty": "name",
      "counterparty_type": "supplier" or "customer",
      "direction": "purchase" or "sale",
      "incoterm": "FOB" etc.,
      "term_type": "spot" or "long_term",
      "company": "trammo_inc" or "trammo_sas" or "trammo_dmcc",
      "effective_date": "YYYY-MM-DD or null",
      "expiry_date": "YYYY-MM-DD or null",
      "family_id": "matched family ID or null",
      "clauses": [
        {
          "clause_id": "PRICE",
          "category": "commercial",
          "extracted_fields": {"price_value": 340.00, "price_uom": "$/ton"},
          "source_text": "exact contract text",
          "section_ref": "Section 5",
          "confidence": "high",
          "anchors_matched": ["Price", "US $"]
        }
      ],
      "new_clause_definitions": []
    }

    Rules:
    - Extract EVERY identifiable clause, not just known types
    - Include exact source_text from the contract
    - Precise numerical values (prices, quantities, percentages)
    - confidence: "low" if uncertain
    - new_clause_definitions only for clauses NOT in the inventory

    CONTRACT:
    ---
    #{contract_text}
    ---
    """
  end

  defp parse_llm_response(json_str) do
    case Jason.decode(json_str) do
      {:ok, %{"clauses" => clauses} = extraction} when is_list(clauses) ->
        {:ok, extraction}
      {:ok, _} ->
        {:error, :missing_clauses_key}
      {:error, reason} ->
        {:error, {:json_parse_failed, reason}}
    end
  end

  # ──────────────────────────────────────────────────────────
  # PROMPT CONTEXT — inventory for LLM
  # ──────────────────────────────────────────────────────────

  defp clause_inventory_text do
    TemplateRegistry.canonical_clauses()
    |> Enum.sort_by(fn {id, _} -> id end)
    |> Enum.map(fn {id, d} ->
      "- #{id} (#{d.category}): anchors=[#{Enum.join(d.anchors, ", ")}], " <>
      "fields=[#{Enum.join(Enum.map(d.extract_fields, &to_string/1), ", ")}]"
    end)
    |> Enum.join("\n")
  end

  defp family_signatures_text do
    TemplateRegistry.family_signatures()
    |> Enum.sort_by(fn {id, _} -> id end)
    |> Enum.map(fn {id, f} ->
      "- #{id}: #{f.direction}/#{f.term_type}/#{f.transport}, " <>
      "incoterms=[#{Enum.join(Enum.map(f.default_incoterms, &to_string/1), ", ")}]"
    end)
    |> Enum.join("\n")
  end

  # ──────────────────────────────────────────────────────────
  # HELPERS
  # ──────────────────────────────────────────────────────────

  defp summarize_results(results, folder_path) do
    succeeded = Enum.count(results, fn {_, r} -> match?({:ok, _}, r) end)
    failed = Enum.count(results, fn {_, r} -> not match?({:ok, _}, r) end)

    failures =
      results
      |> Enum.filter(fn {_, r} -> not match?({:ok, _}, r) end)
      |> Enum.map(fn {name, {:error, reason}} -> {name, reason} end)

    broadcast(:copilot_full_scan_complete, %{
      folder: folder_path,
      total: length(results),
      succeeded: succeeded,
      failed: failed
    })

    {:ok, %{
      folder: folder_path,
      total: length(results),
      succeeded: succeeded,
      failed: failed,
      failures: failures,
      scanned_at: DateTime.utc_now()
    }}
  end

  defp graph_item_id(contract) do
    Map.get(contract, :graph_item_id) || Map.get(contract, "graph_item_id")
  end

  defp graph_drive_id(contract) do
    Map.get(contract, :graph_drive_id) ||
      Map.get(contract, "graph_drive_id") ||
      System.get_env("GRAPH_DRIVE_ID") || ""
  end

  defp detect_format(filename) do
    case Path.extname(filename) |> String.downcase() do
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
      is_nil(endpoint) or endpoint == "" -> {:error, :endpoint_not_configured}
      is_nil(api_key) or api_key == "" -> {:error, :api_key_not_configured}
      true ->
        {:ok, %{
          endpoint: String.trim_trailing(endpoint, "/"),
          api_key: api_key,
          model: System.get_env("COPILOT_MODEL") || @default_model
        }}
    end
  end

  defp auth_headers(%{api_key: key}), do: [{"authorization", "Bearer #{key}"}]

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
