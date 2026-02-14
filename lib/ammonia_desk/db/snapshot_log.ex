defmodule AmmoniaDesk.DB.SnapshotLog do
  @moduledoc """
  Append-only snapshot log — the write-ahead log for all audit data.

  Every mutation (contract ingest, status change, solve audit, scenario save)
  is written here as a self-contained snapshot BEFORE hitting Postgres. The
  log entries use Erlang Term Format (ETF) — compact, fast, and lossless.

  ## Why this exists

  The Postgres DB stores FK references for efficiency (solve_audit_contracts
  links to contract rows). But FK references can't survive a corrupted or
  lost database. The snapshot log stores **full data** — complete contract
  structs, complete audit records with embedded contract snapshots, complete
  variable values. It's self-contained.

  This means:

    1. **Postgres corrupted?** Replay the log → rebuild all tables.
    2. **Point-in-time restore?** Replay log entries up to a timestamp.
    3. **Node crash?** Log files survive on disk. On restart, compare
       log entries against Postgres and fill any gaps.
    4. **Compliance audit?** The log is append-only and tamper-evident
       (each entry includes the prior entry's hash).

  ## File layout

      data/snapshots/
        contracts_YYYYMMDD.wal       — contract mutations
        audits_YYYYMMDD.wal          — solve audit records
        scenarios_YYYYMMDD.wal       — saved scenarios
        manifest.etf                 — log metadata + last known good state

  Files rotate daily. The manifest tracks which files exist and the
  sequence number of the last entry per file.

  ## Entry format

  Each entry is a length-prefixed ETF blob:

      <<size::32, etf_bytes::binary-size(size)>>

  Where the ETF blob decodes to:

      %{
        seq: monotonic_integer,           # global sequence number
        ts: DateTime.t(),                 # when this entry was written
        type: :contract | :audit | :scenario,
        data: full_struct,                # self-contained snapshot
        prev_hash: <<16 bytes>>           # MD5 of previous entry (chain)
      }

  ## Usage

      # Write (called from DB.Writer before Postgres)
      SnapshotLog.append(:contract, contract_struct)
      SnapshotLog.append(:audit, solve_audit_struct)

      # Restore
      SnapshotRestore.replay_to_postgres(since: ~U[2026-02-14 00:00:00Z])
      SnapshotRestore.replay_to_ets(up_to: ~U[2026-02-14 12:00:00Z])

      # Verify integrity
      SnapshotLog.verify_chain("data/snapshots/audits_20260214.wal")
  """

  use GenServer

  require Logger

  @default_dir "data/snapshots"

  # ──────────────────────────────────────────────────────────
  # PUBLIC API
  # ──────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Append a snapshot entry to the log.

  This is synchronous — the caller blocks until the entry is fsynced to disk.
  This guarantees that if the caller proceeds to write to Postgres and the
  node crashes mid-write, the snapshot log has the data.

  Types: :contract, :audit, :scenario
  """
  @spec append(atom(), term()) :: :ok | {:error, term()}
  def append(type, data) when type in [:contract, :audit, :scenario] do
    GenServer.call(__MODULE__, {:append, type, data}, 10_000)
  end

  @doc """
  Read all entries from a specific WAL file.

  Returns entries in order. Used by SnapshotRestore.
  """
  @spec read_file(String.t()) :: {:ok, [map()]} | {:error, term()}
  def read_file(path) do
    case File.read(path) do
      {:ok, binary} -> {:ok, decode_entries(binary, [])}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Read entries across all WAL files for a type within a time range.
  """
  @spec read_range(atom(), DateTime.t(), DateTime.t()) :: {:ok, [map()]}
  def read_range(type, from, to) do
    GenServer.call(__MODULE__, {:read_range, type, from, to}, 60_000)
  end

  @doc """
  List all WAL files for a given type, sorted chronologically.
  """
  @spec list_files(atom()) :: [String.t()]
  def list_files(type) do
    GenServer.call(__MODULE__, {:list_files, type})
  end

  @doc """
  Verify the hash chain integrity of a WAL file.

  Returns :ok if the chain is valid, or {:error, {broken_at_seq, detail}}.
  """
  @spec verify_chain(String.t()) :: :ok | {:error, term()}
  def verify_chain(path) do
    case read_file(path) do
      {:ok, entries} -> do_verify_chain(entries)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Get current log statistics."
  @spec stats() :: map()
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  # ──────────────────────────────────────────────────────────
  # GENSERVER
  # ──────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    dir = Keyword.get(opts, :dir) || snapshot_dir()

    # Ensure directory exists
    File.mkdir_p!(dir)

    state = %{
      dir: dir,
      handles: %{},        # %{type => {file_handle, date_string}}
      seq: 0,              # monotonic sequence number
      prev_hashes: %{},    # %{type => <<md5>>} — last hash per type
      entries_written: 0
    }

    # Resume sequence number from manifest if it exists
    state = load_manifest(state)

    Logger.info("SnapshotLog started: dir=#{dir}, seq=#{state.seq}")
    {:ok, state}
  end

  @impl true
  def handle_call({:append, type, data}, _from, state) do
    now = DateTime.utc_now()
    date_str = Calendar.strftime(now, "%Y%m%d")

    # Ensure we have an open file handle for today's date
    {handle, state} = ensure_handle(state, type, date_str)

    # Build the entry
    seq = state.seq + 1
    prev_hash = Map.get(state.prev_hashes, type, <<0::128>>)

    entry = %{
      seq: seq,
      ts: now,
      type: type,
      data: data,
      prev_hash: prev_hash
    }

    # Serialize to ETF
    etf_bytes = :erlang.term_to_binary(entry, [:compressed])
    size = byte_size(etf_bytes)
    frame = <<size::32, etf_bytes::binary>>

    # Compute this entry's hash (for the chain)
    entry_hash = :crypto.hash(:md5, frame)

    # Write and fsync
    case IO.binwrite(handle, frame) do
      :ok ->
        # fsync to guarantee durability
        :file.sync(handle)

        new_state = %{state |
          seq: seq,
          prev_hashes: Map.put(state.prev_hashes, type, entry_hash),
          entries_written: state.entries_written + 1
        }

        # Persist manifest periodically (every 50 entries)
        new_state =
          if rem(new_state.entries_written, 50) == 0 do
            save_manifest(new_state)
            new_state
          else
            new_state
          end

        {:reply, :ok, new_state}

      {:error, reason} ->
        Logger.error("SnapshotLog write failed: #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:read_range, type, from, to}, _from, state) do
    prefix = type_prefix(type)
    dir = state.dir

    entries =
      list_wal_files(dir, prefix)
      |> Enum.flat_map(fn path ->
        case read_file(path) do
          {:ok, entries} ->
            Enum.filter(entries, fn e ->
              DateTime.compare(e.ts, from) != :lt and
              DateTime.compare(e.ts, to) != :gt
            end)
          {:error, _} -> []
        end
      end)
      |> Enum.sort_by(& &1.seq)

    {:reply, {:ok, entries}, state}
  end

  @impl true
  def handle_call({:list_files, type}, _from, state) do
    prefix = type_prefix(type)
    files = list_wal_files(state.dir, prefix)
    {:reply, files, state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = %{
      dir: state.dir,
      seq: state.seq,
      entries_written: state.entries_written,
      open_handles: Map.keys(state.handles),
      file_count: count_wal_files(state.dir)
    }
    {:reply, stats, state}
  end

  @impl true
  def terminate(_reason, state) do
    # Close all file handles
    Enum.each(state.handles, fn {_type, {handle, _date}} ->
      File.close(handle)
    end)

    # Save final manifest
    save_manifest(state)
    :ok
  end

  # ──────────────────────────────────────────────────────────
  # FILE MANAGEMENT
  # ──────────────────────────────────────────────────────────

  defp ensure_handle(state, type, date_str) do
    case Map.get(state.handles, type) do
      {handle, ^date_str} ->
        # Same day, reuse handle
        {handle, state}

      {old_handle, _old_date} ->
        # New day — close old, open new
        File.close(old_handle)
        open_new_handle(state, type, date_str)

      nil ->
        # First write for this type
        open_new_handle(state, type, date_str)
    end
  end

  defp open_new_handle(state, type, date_str) do
    prefix = type_prefix(type)
    path = Path.join(state.dir, "#{prefix}_#{date_str}.wal")

    case File.open(path, [:append, :binary, :raw]) do
      {:ok, handle} ->
        new_handles = Map.put(state.handles, type, {handle, date_str})
        {handle, %{state | handles: new_handles}}

      {:error, reason} ->
        Logger.error("SnapshotLog: failed to open #{path}: #{inspect(reason)}")
        # Return a dummy that will fail on write
        {nil, state}
    end
  end

  defp type_prefix(:contract), do: "contracts"
  defp type_prefix(:audit), do: "audits"
  defp type_prefix(:scenario), do: "scenarios"

  defp list_wal_files(dir, prefix) do
    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.starts_with?(&1, prefix))
        |> Enum.filter(&String.ends_with?(&1, ".wal"))
        |> Enum.sort()
        |> Enum.map(&Path.join(dir, &1))

      {:error, _} -> []
    end
  end

  defp count_wal_files(dir) do
    case File.ls(dir) do
      {:ok, files} -> Enum.count(files, &String.ends_with?(&1, ".wal"))
      {:error, _} -> 0
    end
  end

  # ──────────────────────────────────────────────────────────
  # ENTRY DECODING
  # ──────────────────────────────────────────────────────────

  defp decode_entries(<<size::32, etf_bytes::binary-size(size), rest::binary>>, acc) do
    entry = :erlang.binary_to_term(etf_bytes)
    decode_entries(rest, [entry | acc])
  end

  defp decode_entries(<<>>, acc), do: Enum.reverse(acc)

  # Tolerate trailing garbage (e.g. partial write before crash)
  defp decode_entries(_trailing, acc) do
    Logger.warning("SnapshotLog: ignoring #{byte_size(<<>>)} trailing bytes (partial write?)")
    Enum.reverse(acc)
  end

  # ──────────────────────────────────────────────────────────
  # CHAIN VERIFICATION
  # ──────────────────────────────────────────────────────────

  defp do_verify_chain([]), do: :ok
  defp do_verify_chain([first | rest]) do
    # First entry's prev_hash should be zero
    if first.prev_hash != <<0::128>> do
      {:error, {:unexpected_first_hash, first.seq}}
    else
      verify_chain_links(first, rest)
    end
  end

  defp verify_chain_links(_prev, []), do: :ok
  defp verify_chain_links(prev, [current | rest]) do
    # Recompute prev entry's frame hash
    prev_etf = :erlang.term_to_binary(prev, [:compressed])
    prev_frame = <<byte_size(prev_etf)::32, prev_etf::binary>>
    expected_hash = :crypto.hash(:md5, prev_frame)

    if current.prev_hash == expected_hash do
      verify_chain_links(current, rest)
    else
      {:error, {:chain_broken, current.seq, expected: expected_hash, got: current.prev_hash}}
    end
  end

  # ──────────────────────────────────────────────────────────
  # MANIFEST (sequence number persistence across restarts)
  # ──────────────────────────────────────────────────────────

  defp manifest_path(state), do: Path.join(state.dir, "manifest.etf")

  defp load_manifest(state) do
    path = manifest_path(state)

    case File.read(path) do
      {:ok, binary} ->
        case :erlang.binary_to_term(binary) do
          %{seq: seq, prev_hashes: prev_hashes} ->
            %{state | seq: seq, prev_hashes: prev_hashes}
          _ ->
            state
        end

      {:error, _} ->
        # No manifest yet — scan WAL files to find highest seq
        recover_seq_from_files(state)
    end
  rescue
    _ -> state
  end

  defp save_manifest(state) do
    manifest = %{
      seq: state.seq,
      prev_hashes: state.prev_hashes,
      saved_at: DateTime.utc_now()
    }

    path = manifest_path(state)
    binary = :erlang.term_to_binary(manifest)
    File.write!(path, binary)
  rescue
    e -> Logger.warning("SnapshotLog: failed to save manifest: #{inspect(e)}")
  end

  defp recover_seq_from_files(state) do
    max_seq =
      ["contracts", "audits", "scenarios"]
      |> Enum.flat_map(fn prefix -> list_wal_files(state.dir, prefix) end)
      |> Enum.reduce(0, fn path, max ->
        case read_file(path) do
          {:ok, entries} ->
            file_max = entries |> Enum.map(& &1.seq) |> Enum.max(fn -> 0 end)
            max(max, file_max)
          {:error, _} -> max
        end
      end)

    if max_seq > 0 do
      Logger.info("SnapshotLog: recovered seq=#{max_seq} from WAL files")
    end

    %{state | seq: max_seq}
  end

  defp snapshot_dir do
    System.get_env("SNAPSHOT_LOG_DIR") ||
      Path.join(Application.app_dir(:ammonia_desk, "priv"), "snapshots")
  end
end
