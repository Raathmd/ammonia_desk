defmodule AmmoniaDesk.Contracts.NetworkScanner do
  @moduledoc """
  Elixir port wrapper for the Zig contract_scanner binary.

  The scanner is a long-running OS process that communicates with the BEAM
  via JSON lines over stdin/stdout. It handles:

    1. Scanning SharePoint folders for contract files via Microsoft Graph API
    2. Checking file hashes against stored values (delta detection)
    3. Downloading changed files and computing SHA-256 on raw bytes
    4. Hashing local files (testing / UNC path fallback)

  The scanner never touches the BEAM's memory. File content arrives as
  base64-encoded JSON, decoded in Elixir only when needed.

  ## Architecture

  ```
  SharePoint ←── Graph API ──→ Zig scanner ←── Port ──→ Elixir (this module)
                                (hashing)                       │
                                (scanning)                      ▼
                                                        CopilotClient
                                                               │
                                                               ▼
                                                       CopilotIngestion
                                                        (system of record)
  ```

  ## Configuration

  Graph API authentication requires a bearer token. The token is passed
  with each command (not stored in the scanner) so the app controls
  token refresh and can use different tenants.

  Environment:
    GRAPH_TENANT_ID     — Azure AD tenant ID
    GRAPH_CLIENT_ID     — App registration client ID
    GRAPH_CLIENT_SECRET — App registration client secret
    GRAPH_DRIVE_ID      — SharePoint document library drive ID
    SCANNER_BINARY      — path to contract_scanner binary
                          (default: native/scanner/zig-out/bin/contract_scanner)
  """

  use GenServer

  alias AmmoniaDesk.Contracts.{Store, CurrencyTracker}

  require Logger

  @pubsub AmmoniaDesk.PubSub
  @topic "contracts"

  @default_binary_path "native/scanner/zig-out/bin/contract_scanner"
  @call_timeout 120_000
  @token_refresh_interval :timer.minutes(45)

  # ──────────────────────────────────────────────────────────
  # PUBLIC API
  # ──────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Ping the scanner to check it's alive.
  Returns :ok or {:error, reason}.
  """
  def ping do
    GenServer.call(__MODULE__, :ping, 5_000)
  end

  @doc """
  Scan a SharePoint folder for contract files.
  Returns a list of file metadata (id, name, hash, size, modified_at).

  `folder_path` is the SharePoint folder path, e.g. "/Contracts/Ammonia".
  """
  @spec scan_folder(String.t(), keyword()) :: {:ok, list(map())} | {:error, term()}
  def scan_folder(folder_path, opts \\ []) do
    drive_id = Keyword.get(opts, :drive_id) || graph_drive_id()

    GenServer.call(__MODULE__, {:scan, folder_path, drive_id}, @call_timeout)
  end

  @doc """
  Check stored hashes against current files on SharePoint.
  Only makes metadata requests (no file downloads).

  `files` is a list of:
    %{contract_id: "...", drive_id: "...", item_id: "...", stored_hash: "..."}

  Returns:
    {:ok, %{changed: [...], unchanged: [...], errors: [...]}}
  """
  @spec check_hashes([map()]) :: {:ok, map()} | {:error, term()}
  def check_hashes(files) do
    GenServer.call(__MODULE__, {:check_hashes, files}, @call_timeout)
  end

  @doc """
  Download a file from SharePoint and get its content + SHA-256 hash.
  Content is returned as raw binary (decoded from base64).

  Returns:
    {:ok, %{sha256: "hex...", size: 12345, content: <<bytes>>}}
  """
  @spec fetch_file(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def fetch_file(drive_id, item_id) do
    GenServer.call(__MODULE__, {:fetch, drive_id, item_id}, @call_timeout)
  end

  @doc """
  Compute SHA-256 hash of a local file (for testing or UNC paths).

  Returns:
    {:ok, %{sha256: "hex...", size: 12345}}
  """
  @spec hash_local(String.t()) :: {:ok, map()} | {:error, term()}
  def hash_local(path) do
    GenServer.call(__MODULE__, {:hash_local, path}, @call_timeout)
  end

  @doc """
  Full delta scan for a product group:
    1. Get all contracts with their stored hashes and item_ids
    2. Send to scanner for hash comparison via Graph API
    3. For changed files, fetch content and return for re-extraction

  Returns:
    {:ok, %{
      changed: [%{contract_id: ..., content: <<bytes>>, sha256: ..., size: ...}],
      unchanged: [contract_id, ...],
      errors: [...]
    }}
  """
  @spec delta_scan(atom()) :: {:ok, map()} | {:error, term()}
  def delta_scan(product_group) do
    GenServer.call(__MODULE__, {:delta_scan, product_group}, @call_timeout * 2)
  end

  @doc "Check if the scanner binary exists and is responding."
  def available? do
    case ping() do
      :ok -> true
      _ -> false
    end
  catch
    :exit, _ -> false
  end

  # ──────────────────────────────────────────────────────────
  # GENSERVER IMPLEMENTATION
  # ──────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    binary_path = Keyword.get(opts, :binary_path) || scanner_binary_path()

    state = %{
      port: nil,
      binary_path: binary_path,
      pending: %{},
      request_id: 0,
      token: nil,
      token_expires_at: nil
    }

    case start_scanner(state) do
      {:ok, state} ->
        # Schedule token refresh
        Process.send_after(self(), :refresh_token, 100)
        {:ok, state}

      {:error, reason} ->
        Logger.warning("Scanner binary not available at #{binary_path}: #{inspect(reason)}")
        {:ok, %{state | port: nil}}
    end
  end

  @impl true
  def handle_call(:ping, from, %{port: nil} = state) do
    {:reply, {:error, :scanner_not_running}, state}
  end

  def handle_call(:ping, from, state) do
    case send_command(state, %{cmd: "ping"}) do
      {:ok, state} ->
        {:noreply, %{state | pending: Map.put(state.pending, state.request_id, from)}}
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:scan, folder_path, drive_id}, from, state) do
    with {:ok, token} <- ensure_token(state) do
      cmd = %{cmd: "scan", token: token, drive_id: drive_id, folder_path: folder_path}
      case send_command(state, cmd) do
        {:ok, state} ->
          {:noreply, %{state | pending: Map.put(state.pending, state.request_id, from)}}
        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    else
      {:error, reason} -> {:reply, {:error, {:token_error, reason}}, state}
    end
  end

  def handle_call({:check_hashes, files}, from, state) do
    with {:ok, token} <- ensure_token(state) do
      cmd = %{
        cmd: "check_hashes",
        token: token,
        files: Enum.map(files, fn f ->
          %{
            contract_id: f.contract_id,
            drive_id: f[:drive_id] || graph_drive_id(),
            item_id: f.item_id,
            stored_hash: f.stored_hash
          }
        end)
      }
      case send_command(state, cmd) do
        {:ok, state} ->
          {:noreply, %{state | pending: Map.put(state.pending, state.request_id, from)}}
        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    else
      {:error, reason} -> {:reply, {:error, {:token_error, reason}}, state}
    end
  end

  def handle_call({:fetch, drive_id, item_id}, from, state) do
    with {:ok, token} <- ensure_token(state) do
      cmd = %{cmd: "fetch", token: token, drive_id: drive_id, item_id: item_id}
      case send_command(state, cmd) do
        {:ok, state} ->
          {:noreply, %{state | pending: Map.put(state.pending, state.request_id, from)}}
        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    else
      {:error, reason} -> {:reply, {:error, {:token_error, reason}}, state}
    end
  end

  def handle_call({:hash_local, path}, from, state) do
    cmd = %{cmd: "hash_local", path: path}
    case send_command(state, cmd) do
      {:ok, state} ->
        {:noreply, %{state | pending: Map.put(state.pending, state.request_id, from)}}
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:delta_scan, product_group}, from, state) do
    # Run the full delta flow in a Task to avoid blocking GenServer
    task = Task.async(fn -> run_delta_scan(product_group) end)

    # We reply synchronously when the task completes
    result = Task.await(task, @call_timeout * 2)
    {:reply, result, state}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    # Scanner sent a response line
    data
    |> String.split("\n", trim: true)
    |> Enum.each(fn line ->
      case Jason.decode(line) do
        {:ok, response} ->
          # Reply to the oldest pending caller
          case pop_pending(state) do
            {from, new_pending} ->
              result = parse_scanner_response(response)
              GenServer.reply(from, result)
              send(self(), {:update_pending, new_pending})

            nil ->
              Logger.debug("Scanner response with no pending caller: #{inspect(response)}")
          end

        {:error, _} ->
          Logger.debug("Scanner non-JSON output: #{line}")
      end
    end)

    {:noreply, state}
  end

  def handle_info({:update_pending, new_pending}, state) do
    {:noreply, %{state | pending: new_pending}}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning("Scanner exited with status #{status}, restarting...")

    # Reply to all pending callers with error
    Enum.each(state.pending, fn {_id, from} ->
      GenServer.reply(from, {:error, :scanner_crashed})
    end)

    # Restart after a brief delay
    Process.send_after(self(), :restart_scanner, 1_000)

    {:noreply, %{state | port: nil, pending: %{}}}
  end

  def handle_info(:restart_scanner, state) do
    case start_scanner(state) do
      {:ok, new_state} ->
        Logger.info("Scanner restarted successfully")
        {:noreply, new_state}

      {:error, reason} ->
        Logger.error("Scanner restart failed: #{inspect(reason)}")
        # Retry in 5 seconds
        Process.send_after(self(), :restart_scanner, 5_000)
        {:noreply, state}
    end
  end

  def handle_info(:refresh_token, state) do
    case fetch_graph_token() do
      {:ok, token, expires_in} ->
        expires_at = System.system_time(:second) + expires_in - 60
        Process.send_after(self(), :refresh_token, @token_refresh_interval)
        {:noreply, %{state | token: token, token_expires_at: expires_at}}

      {:error, reason} ->
        Logger.warning("Graph token refresh failed: #{inspect(reason)}")
        Process.send_after(self(), :refresh_token, 30_000)
        {:noreply, state}
    end
  end

  def handle_info(msg, state) do
    Logger.debug("NetworkScanner unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # ──────────────────────────────────────────────────────────
  # PORT MANAGEMENT
  # ──────────────────────────────────────────────────────────

  defp start_scanner(state) do
    binary = state.binary_path

    if File.exists?(binary) do
      port = Port.open({:spawn_executable, binary}, [
        :binary,
        :exit_status,
        :use_stdio,
        {:line, 1_024_000},
        {:env, []}
      ])

      {:ok, %{state | port: port}}
    else
      {:error, :binary_not_found}
    end
  end

  defp send_command(%{port: nil}, _cmd), do: {:error, :scanner_not_running}

  defp send_command(%{port: port} = state, cmd) do
    json_line = Jason.encode!(cmd) <> "\n"
    Port.command(port, json_line)
    new_id = state.request_id + 1
    {:ok, %{state | request_id: new_id}}
  end

  defp pop_pending(%{pending: pending}) do
    case Enum.min_by(pending, fn {id, _} -> id end, fn -> nil end) do
      nil -> nil
      {id, from} -> {from, Map.delete(pending, id)}
    end
  end

  # ──────────────────────────────────────────────────────────
  # RESPONSE PARSING
  # ──────────────────────────────────────────────────────────

  defp parse_scanner_response(%{"status" => "ok"} = response) do
    result =
      response
      |> Map.drop(["status"])
      |> decode_content_if_present()

    {:ok, result}
  end

  defp parse_scanner_response(%{"status" => "error", "error" => error} = response) do
    detail = Map.get(response, "detail", "")
    {:error, {String.to_atom(error), detail}}
  end

  defp parse_scanner_response(other) do
    {:error, {:unexpected_response, other}}
  end

  # Decode base64 content from fetch responses
  defp decode_content_if_present(%{"content_base64" => b64} = response) when is_binary(b64) do
    case Base.decode64(b64) do
      {:ok, bytes} ->
        response
        |> Map.delete("content_base64")
        |> Map.put("content", bytes)

      :error ->
        response
    end
  end

  defp decode_content_if_present(response), do: response

  # ──────────────────────────────────────────────────────────
  # GRAPH API TOKEN MANAGEMENT
  # ──────────────────────────────────────────────────────────

  defp ensure_token(state) do
    now = System.system_time(:second)

    if state.token && state.token_expires_at && state.token_expires_at > now do
      {:ok, "Bearer " <> state.token}
    else
      case fetch_graph_token() do
        {:ok, token, _expires_in} ->
          {:ok, "Bearer " <> token}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp fetch_graph_token do
    tenant_id = System.get_env("GRAPH_TENANT_ID")
    client_id = System.get_env("GRAPH_CLIENT_ID")
    client_secret = System.get_env("GRAPH_CLIENT_SECRET")

    if is_nil(tenant_id) or is_nil(client_id) or is_nil(client_secret) do
      {:error, :graph_not_configured}
    else
      url = "https://login.microsoftonline.com/#{tenant_id}/oauth2/v2.0/token"

      body =
        URI.encode_query(%{
          "grant_type" => "client_credentials",
          "client_id" => client_id,
          "client_secret" => client_secret,
          "scope" => "https://graph.microsoft.com/.default"
        })

      case Req.post(url,
             body: body,
             headers: [{"content-type", "application/x-www-form-urlencoded"}],
             receive_timeout: 10_000
           ) do
        {:ok, %{status: 200, body: %{"access_token" => token, "expires_in" => expires_in}}} ->
          {:ok, token, expires_in}

        {:ok, %{status: status, body: body}} ->
          Logger.error("Graph token request failed (#{status}): #{inspect(body)}")
          {:error, {:token_request_failed, status}}

        {:error, reason} ->
          {:error, {:token_request_error, reason}}
      end
    end
  end

  # ──────────────────────────────────────────────────────────
  # DELTA SCAN ORCHESTRATION
  # ──────────────────────────────────────────────────────────

  defp run_delta_scan(product_group) do
    broadcast(:scanner_delta_started, %{product_group: product_group})

    contracts = Store.list_by_product_group(product_group)

    # Filter to contracts that have Graph item_id and stored hash
    checkable =
      contracts
      |> Enum.filter(fn c ->
        c.file_hash && Map.get(c, :graph_item_id)
      end)
      |> Enum.map(fn c ->
        %{
          contract_id: c.id,
          drive_id: Map.get(c, :graph_drive_id) || graph_drive_id(),
          item_id: Map.get(c, :graph_item_id),
          stored_hash: c.file_hash
        }
      end)

    if length(checkable) == 0 do
      {:ok, %{
        product_group: product_group,
        changed: [],
        unchanged: [],
        errors: [],
        message: "no contracts with Graph item IDs"
      }}
    else
      case check_hashes(checkable) do
        {:ok, %{"changed" => changed_list, "unchanged" => unchanged_list} = hash_result} ->
          errors = Map.get(hash_result, "errors", [])

          # Fetch content for changed files
          changed_with_content =
            Enum.map(changed_list, fn changed_entry ->
              drive_id = changed_entry["drive_id"]
              item_id = changed_entry["item_id"]

              case fetch_file(drive_id, item_id) do
                {:ok, %{"content" => content, "sha256" => sha256, "size" => size}} ->
                  %{
                    contract_id: changed_entry["contract_id"],
                    content: content,
                    sha256: sha256,
                    size: size,
                    item_id: item_id
                  }

                {:error, reason} ->
                  %{contract_id: changed_entry["contract_id"], error: reason}
              end
            end)

          succeeded = Enum.filter(changed_with_content, &(not Map.has_key?(&1, :error)))
          fetch_errors = Enum.filter(changed_with_content, &Map.has_key?(&1, :error))

          # Update unchanged contracts as verified
          unchanged_ids = Enum.map(unchanged_list, & &1["contract_id"])
          Enum.each(unchanged_ids, fn cid ->
            Store.update_verification(cid, %{
              verification_status: :verified,
              last_verified_at: DateTime.utc_now()
            })
          end)

          broadcast(:scanner_delta_complete, %{
            product_group: product_group,
            unchanged: length(unchanged_ids),
            changed: length(succeeded),
            errors: length(errors) + length(fetch_errors)
          })

          {:ok, %{
            product_group: product_group,
            changed: succeeded,
            unchanged: unchanged_ids,
            errors: errors ++ Enum.map(fetch_errors, &Map.take(&1, [:contract_id, :error])),
            scanned_at: DateTime.utc_now()
          }}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # ──────────────────────────────────────────────────────────
  # HELPERS
  # ──────────────────────────────────────────────────────────

  defp scanner_binary_path do
    System.get_env("SCANNER_BINARY") ||
      Path.join(Application.app_dir(:ammonia_desk, "priv"), "contract_scanner") ||
      @default_binary_path
  end

  defp graph_drive_id do
    System.get_env("GRAPH_DRIVE_ID") || ""
  end

  defp broadcast(event, payload) do
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:contract_event, event, payload})
  end
end
