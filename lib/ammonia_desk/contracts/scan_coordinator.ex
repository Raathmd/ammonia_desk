defmodule AmmoniaDesk.Contracts.ScanCoordinator do
  @moduledoc """
  App-initiated contract scan flow.

  This is the entry point for all contract scanning. The app decides
  when to scan, what changed, and what to ingest. The Zig scanner and
  Copilot LLM are called on-demand as utilities.

  ## The Flow

  1. App calls `run/2` (manually, on schedule, or on demand)
  2. App asks Zig scanner for current file hashes from Graph API
  3. App compares hashes against its own database:
     - Hash not in DB           → new file → request Copilot extraction
     - Hash differs from DB     → changed file → request Copilot re-extraction
     - Hash matches DB          → unchanged → skip
  4. Sends all new/changed files to Copilot in a batch:
     - CopilotClient downloads each file from Graph API
     - CopilotClient extracts text + sends to LLM
     - CopilotClient returns structured clauses per file
  5. App ingests extractions as versioned contracts
  6. Contracts available for LP solver

  ```
  App (this module)
    │
    ├── "scanner, what files + hashes are in this folder?"
    │     └── Zig scanner → Graph API (metadata only, no downloads)
    │
    ├── compares hashes against Store (its own database)
    │
    ├── "copilot, extract these files" (batch)
    │     └── CopilotClient.extract_files/2
    │           ├── Graph API: download each file
    │           ├── DocumentReader: convert binary → text
    │           └── LLM: extract clauses from text
    │
    ├── CopilotIngestion.ingest_with_hash/2 per file → versioned contracts
    │
    └── contracts available for LP solver
  ```
  """

  alias AmmoniaDesk.Contracts.{
    CopilotClient,
    CopilotIngestion,
    NetworkScanner,
    Store,
    CurrencyTracker
  }

  require Logger

  @pubsub AmmoniaDesk.PubSub
  @topic "contracts"

  # ──────────────────────────────────────────────────────────
  # PUBLIC API
  # ──────────────────────────────────────────────────────────

  @doc """
  Run a full scan cycle for a SharePoint folder.

  Steps:
    1. Get all file hashes from Graph API via scanner
    2. Compare against database
    3. Ingest new files, re-ingest changed files, skip unchanged

  Options:
    - :product_group — product group for new contracts (default: :ammonia)
    - :drive_id — SharePoint drive ID (default: GRAPH_DRIVE_ID env)
    - :folder_path — folder to scan (required)
  """
  @spec run(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(folder_path, opts \\ []) do
    product_group = Keyword.get(opts, :product_group, :ammonia)

    broadcast(:scan_started, %{folder: folder_path, product_group: product_group})
    Logger.info("Scan started: #{folder_path} (#{product_group})")

    with {:ok, remote_files} <- get_remote_hashes(folder_path, opts),
         {:ok, diff} <- compare_against_database(remote_files, product_group),
         {:ok, results} <- process_diff(diff, product_group, opts) do

      summary = build_summary(results, diff, folder_path, product_group)

      broadcast(:scan_complete, summary)
      Logger.info("Scan complete: #{summary.new_ingested} new, #{summary.re_ingested} updated, #{summary.unchanged} current")

      {:ok, summary}
    end
  end

  @doc """
  Quick delta check — only checks existing contracts for hash changes.
  Does NOT discover new files. Use `run/2` for that.

  Sends stored hashes to the scanner, which batch-checks them against
  Graph API metadata (no downloads). Only fetches + re-extracts changed files.
  """
  @spec check_existing(atom(), keyword()) :: {:ok, map()} | {:error, term()}
  def check_existing(product_group, opts \\ []) do
    broadcast(:delta_check_started, %{product_group: product_group})
    Logger.info("Delta check: #{product_group}")

    contracts = Store.list_by_product_group(product_group)

    # Build list of known hashes to send to scanner
    known =
      contracts
      |> Enum.filter(fn c -> c.file_hash && c.graph_item_id && c.graph_drive_id end)
      |> Enum.map(fn c ->
        %{
          id: c.id,
          drive_id: c.graph_drive_id,
          item_id: c.graph_item_id,
          hash: c.file_hash
        }
      end)

    if length(known) == 0 do
      {:ok, %{product_group: product_group, message: "no contracts with Graph IDs to check",
              changed: 0, unchanged: 0, missing: 0, scanned_at: DateTime.utc_now()}}
    else
      # Scanner batch-checks all hashes against Graph API (metadata only)
      case NetworkScanner.diff_hashes(known) do
        {:ok, diff_result} ->
          process_delta_diff(diff_result, product_group, opts)

        {:error, reason} ->
          {:error, {:scanner_diff_failed, reason}}
      end
    end
  end

  @doc "Run scan in background."
  def run_async(folder_path, opts \\ []) do
    Task.Supervisor.async_nolink(
      AmmoniaDesk.Contracts.TaskSupervisor,
      fn -> run(folder_path, opts) end
    )
  end

  @doc "Run delta check in background."
  def check_existing_async(product_group, opts \\ []) do
    Task.Supervisor.async_nolink(
      AmmoniaDesk.Contracts.TaskSupervisor,
      fn -> check_existing(product_group, opts) end
    )
  end

  # ──────────────────────────────────────────────────────────
  # STEP 1: Get remote file hashes from Graph API via scanner
  # ──────────────────────────────────────────────────────────

  defp get_remote_hashes(folder_path, opts) do
    case NetworkScanner.scan_folder(folder_path, opts) do
      {:ok, %{"files" => files}} ->
        Logger.info("Scanner returned #{length(files)} files from #{folder_path}")
        {:ok, files}

      {:ok, %{"file_count" => 0}} ->
        {:ok, []}

      {:error, reason} ->
        {:error, {:scan_failed, reason}}
    end
  end

  # ──────────────────────────────────────────────────────────
  # STEP 2: Compare remote hashes against the app's database
  # ──────────────────────────────────────────────────────────

  defp compare_against_database(remote_files, product_group) do
    # Get all contracts we know about for this product group
    existing = Store.list_by_product_group(product_group)

    # Build lookup: graph_item_id → contract
    by_item_id =
      existing
      |> Enum.filter(& &1.graph_item_id)
      |> Map.new(fn c -> {c.graph_item_id, c} end)

    # Build lookup: sha256 hash → contract (for matching by hash when item_id unknown)
    by_hash =
      existing
      |> Enum.filter(& &1.file_hash)
      |> Map.new(fn c -> {c.file_hash, c} end)

    # Classify each remote file
    {new_files, changed_files, unchanged_files} =
      Enum.reduce(remote_files, {[], [], []}, fn file, {new, changed, unchanged} ->
        item_id = file["item_id"]
        remote_hash = file["sha256"]

        cond do
          # Known by item_id — check if hash changed
          is_binary(item_id) and Map.has_key?(by_item_id, item_id) ->
            contract = by_item_id[item_id]

            if remote_hash && contract.file_hash == remote_hash do
              # Hash matches — file unchanged
              {new, changed, [{file, contract} | unchanged]}
            else
              # Hash differs (or no remote hash available) — needs re-extraction
              {new, [{file, contract} | changed], unchanged}
            end

          # Known by hash — already ingested this exact version
          is_binary(remote_hash) and Map.has_key?(by_hash, remote_hash) ->
            contract = by_hash[remote_hash]
            {new, changed, [{file, contract} | unchanged]}

          # Not in database — new file
          true ->
            {[file | new], changed, unchanged}
        end
      end)

    diff = %{
      new: Enum.reverse(new_files),
      changed: Enum.reverse(changed_files),
      unchanged: Enum.reverse(unchanged_files)
    }

    Logger.info(
      "Hash comparison: #{length(diff.new)} new, " <>
      "#{length(diff.changed)} changed, " <>
      "#{length(diff.unchanged)} unchanged"
    )

    {:ok, diff}
  end

  # ──────────────────────────────────────────────────────────
  # STEP 3: Process the diff — send all files to Copilot as batch
  # ──────────────────────────────────────────────────────────

  defp process_diff(diff, product_group, _opts) do
    # Mark unchanged contracts as verified
    Enum.each(diff.unchanged, fn {_file, contract} ->
      Store.update_verification(contract.id, %{
        verification_status: :verified,
        last_verified_at: DateTime.utc_now()
      })
    end)

    # Collect all files that need extraction (new + changed)
    all_new = Enum.map(diff.new, fn file -> {file, nil} end)
    all_changed = diff.changed  # already {file, existing_contract} tuples

    files_to_extract = all_new ++ all_changed

    if length(files_to_extract) == 0 do
      {:ok, %{new: [], changed: []}}
    else
      # Get Graph API token for CopilotClient to download files
      case NetworkScanner.graph_token() do
        {:ok, graph_token} ->
          batch_extract_and_ingest(files_to_extract, graph_token, product_group, diff)

        {:error, reason} ->
          Logger.error("Cannot get Graph token for extraction: #{inspect(reason)}")
          {:error, {:token_error, reason}}
      end
    end
  end

  # ──────────────────────────────────────────────────────────
  # BATCH EXTRACTION VIA COPILOT
  #
  # Sends all files to CopilotClient.extract_files/2 which:
  #   1. Downloads each file from Graph API
  #   2. Extracts text via DocumentReader
  #   3. Sends text to LLM for clause extraction
  # Then ingests each extraction as a versioned contract.
  # ──────────────────────────────────────────────────────────

  defp batch_extract_and_ingest(files_to_extract, graph_token, product_group, diff) do
    # Build file list for CopilotClient (just the file metadata)
    file_list = Enum.map(files_to_extract, fn {file, _existing} -> file end)

    count = length(file_list)
    Logger.info("Sending #{count} file(s) to Copilot for extraction")
    broadcast(:batch_extraction_started, %{file_count: count})

    # CopilotClient downloads + extracts all files concurrently
    extraction_results = CopilotClient.extract_files(file_list, graph_token)

    # Match results back to existing contracts for ingestion
    results =
      Enum.zip(files_to_extract, extraction_results)
      |> Enum.map(fn {{file, existing_contract}, {_file_ref, extract_result}} ->
        name = file["name"] || "unknown"

        case extract_result do
          {:ok, extraction} ->
            ingest_extraction(extraction, file, existing_contract, product_group)

          {:error, reason} ->
            Logger.warning("Failed to extract #{name}: #{inspect(reason)}")
            {name, {:error, reason}}
        end
      end)

    # Split back into new vs changed for the summary
    n_new = length(diff.new)
    {new_results, changed_results} = Enum.split(results, n_new)

    broadcast(:batch_extraction_complete, %{
      extracted: Enum.count(results, fn {_, r} -> match?({:ok, _}, r) end),
      failed: Enum.count(results, fn {_, r} -> not match?({:ok, _}, r) end)
    })

    {:ok, %{new: new_results, changed: changed_results}}
  end

  defp ingest_extraction(extraction, file, existing_contract, product_group) do
    name = file["name"] || "unknown"

    enriched = Map.merge(extraction, %{
      "source_file" => name,
      "source_format" => detect_format(name),
      "web_url" => file["web_url"]
    })

    ingest_opts = build_ingest_opts(existing_contract, product_group)

    case CopilotIngestion.ingest_with_hash(enriched, ingest_opts) do
      {:ok, contract} ->
        CurrencyTracker.stamp(contract.id, :copilot_extracted_at)
        action = if existing_contract, do: "re-ingested", else: "ingested"
        Logger.info("#{action}: #{name} → #{contract.counterparty} v#{contract.version}")
        {name, {:ok, contract}}

      {:error, reason} ->
        Logger.warning("Failed to ingest #{name}: #{inspect(reason)}")
        {name, {:error, reason}}
    end
  end

  # ──────────────────────────────────────────────────────────
  # DELTA DIFF PROCESSING (for check_existing/2)
  # ──────────────────────────────────────────────────────────

  defp process_delta_diff(diff_result, product_group, _opts) do
    changed = Map.get(diff_result, "changed", [])
    unchanged = Map.get(diff_result, "unchanged", [])
    missing = Map.get(diff_result, "missing", [])

    # Mark unchanged as verified
    Enum.each(unchanged, fn entry ->
      Store.update_verification(entry["id"], %{
        verification_status: :verified,
        last_verified_at: DateTime.utc_now()
      })
    end)

    # Mark missing files
    Enum.each(missing, fn entry ->
      Store.update_verification(entry["id"], %{
        verification_status: :file_not_found,
        last_verified_at: DateTime.utc_now()
      })
    end)

    # Build file list + existing contracts for batch extraction
    files_to_extract =
      Enum.map(changed, fn entry ->
        existing = case Store.get(entry["id"]) do
          {:ok, c} -> c
          _ -> nil
        end

        file_meta = %{
          "drive_id" => entry["drive_id"],
          "item_id" => entry["item_id"],
          "name" => if(existing, do: existing.source_file, else: "unknown")
        }

        {file_meta, existing}
      end)

    re_ingest_results =
      if length(files_to_extract) > 0 do
        case NetworkScanner.graph_token() do
          {:ok, graph_token} ->
            file_list = Enum.map(files_to_extract, fn {file, _} -> file end)

            Logger.info("Delta: sending #{length(file_list)} changed file(s) to Copilot")
            extraction_results = CopilotClient.extract_files(file_list, graph_token)

            Enum.zip(files_to_extract, extraction_results)
            |> Enum.map(fn {{file, existing}, {_ref, extract_result}} ->
              name = file["name"] || "unknown"
              case extract_result do
                {:ok, extraction} -> ingest_extraction(extraction, file, existing, product_group)
                {:error, reason} -> {name, {:error, reason}}
              end
            end)

          {:error, reason} ->
            Logger.error("Cannot get Graph token for delta extraction: #{inspect(reason)}")
            [{:error, {:token_error, reason}}]
        end
      else
        []
      end

    succeeded = Enum.count(re_ingest_results, fn {_, r} -> match?({:ok, _}, r) end)
    failed = Enum.count(re_ingest_results, fn {_, r} -> not match?({:ok, _}, r) end)

    summary = %{
      product_group: product_group,
      changed: succeeded,
      failed: failed,
      unchanged: length(unchanged),
      missing: length(missing),
      scanned_at: DateTime.utc_now()
    }

    broadcast(:delta_check_complete, summary)
    Logger.info("Delta check complete: #{succeeded} re-ingested, #{length(unchanged)} current, #{length(missing)} missing")

    {:ok, summary}
  end

  # ──────────────────────────────────────────────────────────
  # HELPERS
  # ──────────────────────────────────────────────────────────

  defp build_ingest_opts(nil, product_group) do
    [product_group: product_group]
  end

  defp build_ingest_opts(existing_contract, _product_group) do
    [
      product_group: existing_contract.product_group,
      network_path: existing_contract.network_path,
      sap_contract_id: existing_contract.sap_contract_id
    ]
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

  defp build_summary(results, diff, folder_path, product_group) do
    new_ok = Enum.count(results.new, fn {_, r} -> match?({:ok, _}, r) end)
    new_fail = Enum.count(results.new, fn {_, r} -> not match?({:ok, _}, r) end)
    changed_ok = Enum.count(results.changed, fn {_, r} -> match?({:ok, _}, r) end)
    changed_fail = Enum.count(results.changed, fn {_, r} -> not match?({:ok, _}, r) end)

    failures =
      (results.new ++ results.changed)
      |> Enum.filter(fn {_, r} -> not match?({:ok, _}, r) end)
      |> Enum.map(fn {name, {:error, reason}} -> {name, reason} end)

    %{
      folder: folder_path,
      product_group: product_group,
      new_ingested: new_ok,
      re_ingested: changed_ok,
      unchanged: length(diff.unchanged),
      failed: new_fail + changed_fail,
      failures: failures,
      scanned_at: DateTime.utc_now()
    }
  end

  defp broadcast(event, payload) do
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:contract_event, event, payload})
  end
end
