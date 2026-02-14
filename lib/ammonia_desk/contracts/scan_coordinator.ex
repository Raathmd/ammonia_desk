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
  4. For each file needing extraction:
     a. App tells Zig scanner to fetch the file (returns content + SHA-256)
     b. App extracts text from binary (DocumentReader)
     c. App sends text to Copilot LLM for clause extraction
     d. App ingests extraction as a versioned contract
  5. App persists contract data and uses it in LP solves

  ```
  App (this module)
    │
    ├── "scanner, what files + hashes are in this folder?"
    │     └── Zig scanner → Graph API (metadata only, no downloads)
    │
    ├── compares hashes against Store (its own database)
    │
    ├── for each new/changed file:
    │     ├── "scanner, download this file"
    │     │     └── Zig scanner → Graph API (download + SHA-256)
    │     │
    │     ├── DocumentReader.read(content)  → plain text
    │     │
    │     ├── "copilot, extract clauses from this text"
    │     │     └── CopilotClient.extract_text/2  → structured clauses
    │     │
    │     └── CopilotIngestion.ingest_with_hash/2  → versioned contract
    │
    └── contracts available for LP solver
  ```
  """

  alias AmmoniaDesk.Contracts.{
    CopilotClient,
    CopilotIngestion,
    DocumentReader,
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
  # STEP 3: Process the diff — ingest new, re-ingest changed
  # ──────────────────────────────────────────────────────────

  defp process_diff(diff, product_group, opts) do
    # Mark unchanged contracts as verified
    Enum.each(diff.unchanged, fn {_file, contract} ->
      Store.update_verification(contract.id, %{
        verification_status: :verified,
        last_verified_at: DateTime.utc_now()
      })
    end)

    # Ingest new files
    new_results =
      Enum.map(diff.new, fn file ->
        ingest_file(file, nil, product_group, opts)
      end)

    # Re-ingest changed files (creates new version)
    changed_results =
      Enum.map(diff.changed, fn {file, existing_contract} ->
        ingest_file(file, existing_contract, product_group, opts)
      end)

    {:ok, %{new: new_results, changed: changed_results}}
  end

  # ──────────────────────────────────────────────────────────
  # INGEST A SINGLE FILE
  #
  # 1. Scanner downloads file → content + SHA-256
  # 2. DocumentReader extracts text
  # 3. CopilotClient extracts clauses from text
  # 4. CopilotIngestion stores versioned contract
  # ──────────────────────────────────────────────────────────

  defp ingest_file(file, existing_contract, product_group, _opts) do
    drive_id = file["drive_id"]
    item_id = file["item_id"]
    name = file["name"] || "unknown"

    Logger.info("Ingesting: #{name}")

    # Step 1: Scanner fetches file content + computes SHA-256
    with {:ok, fetch_result} <- NetworkScanner.fetch_file(drive_id, item_id),
         content = fetch_result["content"],
         sha256 = fetch_result["sha256"],
         size = fetch_result["size"],

         # Step 2: Extract text from binary
         {:ok, text} <- extract_text(content, name),

         # Step 3: Copilot LLM extracts clauses
         {:ok, extraction} <- CopilotClient.extract_text(text),

         # Enrich extraction with file metadata
         enriched = Map.merge(extraction, %{
           "file_hash" => sha256,
           "file_size" => size,
           "source_file" => name,
           "source_format" => detect_format(name),
           "graph_item_id" => item_id,
           "graph_drive_id" => drive_id,
           "web_url" => file["web_url"]
         }),

         # Step 4: Ingest as versioned contract
         ingest_opts = build_ingest_opts(existing_contract, product_group),
         {:ok, contract} <- CopilotIngestion.ingest_with_hash(enriched, ingest_opts) do

      CurrencyTracker.stamp(contract.id, :copilot_extracted_at)

      action = if existing_contract, do: "re-ingested", else: "ingested"
      Logger.info("#{action}: #{name} → #{contract.counterparty} v#{contract.version}")

      {name, {:ok, contract}}
    else
      {:error, reason} ->
        Logger.warning("Failed to ingest #{name}: #{inspect(reason)}")
        {name, {:error, reason}}
    end
  end

  # ──────────────────────────────────────────────────────────
  # DELTA DIFF PROCESSING (for check_existing/2)
  # ──────────────────────────────────────────────────────────

  defp process_delta_diff(diff_result, product_group, opts) do
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

    # Re-ingest changed files
    re_ingest_results =
      Enum.map(changed, fn entry ->
        contract_id = entry["id"]
        drive_id = entry["drive_id"]
        item_id = entry["item_id"]

        existing = case Store.get(contract_id) do
          {:ok, c} -> c
          _ -> nil
        end

        file_meta = %{
          "drive_id" => drive_id,
          "item_id" => item_id,
          "name" => if(existing, do: existing.source_file, else: "unknown")
        }

        ingest_file(file_meta, existing, product_group, opts)
      end)

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

  defp extract_text(content, filename) do
    ext = Path.extname(filename)
    tmp_path = Path.join(System.tmp_dir!(), "scan_#{:erlang.unique_integer([:positive])}#{ext}")

    try do
      File.write!(tmp_path, content)
      DocumentReader.read(tmp_path)
    after
      File.rm(tmp_path)
    end
  end

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
