defmodule AmmoniaDesk.Contracts.NetworkScanner do
  @moduledoc """
  Elixir port wrapper for the Zig contract_scanner binary.

  The scanner is a utility — it does I/O and hashing, nothing else.
  The app (ScanCoordinator) decides when to scan, what changed, and what to ingest.

  ## Commands (mapped to Zig scanner)

    scan_folder/2   → `scan`        — list files + hashes from a SharePoint folder
    diff_hashes/1   → `diff_hashes` — batch-compare app's stored hashes against Graph API
    hash_local/1    → `hash_local`  — SHA-256 of a local file
    ping/0          → `ping`        — health check
    graph_token/0   → returns current Graph API bearer token for CopilotClient

  ## Token Management

  Graph API auth tokens are managed here (client_credentials flow).
  Tokens are passed to the scanner with each command — the Zig binary
  never stores credentials.

  ## Environment

    GRAPH_TENANT_ID     — Azure AD tenant ID
    GRAPH_CLIENT_ID     — App registration client ID
    GRAPH_CLIENT_SECRET — App registration client secret
    GRAPH_DRIVE_ID      — SharePoint document library drive ID
    SCANNER_BINARY      — path to contract_scanner binary
  """

  use GenServer

  require Logger

  @default_binary_path "native/scanner/zig-out/bin/contract_scanner"
  @call_timeout 120_000
  @token_refresh_interval :timer.minutes(45)

  # ──────────────────────────────────────────────────────────
  # PUBLIC API
  # ──────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Health check. Returns :ok or {:error, reason}."
  def ping do
    GenServer.call(__MODULE__, :ping, 5_000)
  end

  @doc """
  List files + hashes from a SharePoint folder.
  Returns the current state of the folder — the app compares
  these against its database.

  Returns:
    {:ok, %{"files" => [...], "file_count" => N}}
  """
  @spec scan_folder(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def scan_folder(folder_path, opts \\ []) do
    drive_id = Keyword.get(opts, :drive_id) || graph_drive_id()
    GenServer.call(__MODULE__, {:scan, folder_path, drive_id}, @call_timeout)
  end

  @doc """
  Batch-compare stored hashes against current Graph API metadata.
  No file downloads — metadata requests only.

  The app sends a list of known contracts:
    [%{id: "contract-uuid", drive_id: "...", item_id: "...", hash: "abc123"}]

  Scanner hits Graph API for each file's current hash and returns:
    {:ok, %{"changed" => [...], "unchanged" => [...], "missing" => [...]}}
  """
  @spec diff_hashes([map()]) :: {:ok, map()} | {:error, term()}
  def diff_hashes(known) do
    GenServer.call(__MODULE__, {:diff_hashes, known}, @call_timeout)
  end

  @doc """
  Get the current Graph API bearer token.
  Used by CopilotClient to download file content directly.

  Returns:
    {:ok, "Bearer eyJ..."} | {:error, reason}
  """
  @spec graph_token() :: {:ok, String.t()} | {:error, term()}
  def graph_token do
    GenServer.call(__MODULE__, :graph_token, 5_000)
  end

  @doc """
  SHA-256 of a local file.

  Returns:
    {:ok, %{"sha256" => "hex...", "size" => 12345}}
  """
  @spec hash_local(String.t()) :: {:ok, map()} | {:error, term()}
  def hash_local(path) do
    GenServer.call(__MODULE__, {:hash_local, path}, @call_timeout)
  end

  @doc "Check if the scanner binary exists and is responding."
  def available? do
    case ping() do
      :ok -> true
      {:ok, _} -> true
      _ -> false
    end
  catch
    :exit, _ -> false
  end

  # ──────────────────────────────────────────────────────────
  # GENSERVER
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
        Process.send_after(self(), :refresh_token, 100)
        {:ok, state}

      {:error, reason} ->
        Logger.warning("Scanner binary not available at #{binary_path}: #{inspect(reason)}")
        {:ok, %{state | port: nil}}
    end
  end

  @impl true
  def handle_call(:ping, _from, %{port: nil} = state) do
    {:reply, {:error, :scanner_not_running}, state}
  end

  def handle_call(:ping, from, state) do
    send_and_pend(state, %{cmd: "ping"}, from)
  end

  def handle_call({:scan, folder_path, drive_id}, from, state) do
    with {:ok, token} <- ensure_token(state) do
      send_and_pend(state, %{cmd: "scan", token: token, drive_id: drive_id, folder_path: folder_path}, from)
    else
      {:error, reason} -> {:reply, {:error, {:token_error, reason}}, state}
    end
  end

  def handle_call({:diff_hashes, known}, from, state) do
    with {:ok, token} <- ensure_token(state) do
      # Normalize the known list for the scanner
      normalized =
        Enum.map(known, fn k ->
          %{
            id: k[:id] || k["id"],
            drive_id: k[:drive_id] || k["drive_id"] || graph_drive_id(),
            item_id: k[:item_id] || k["item_id"],
            hash: k[:hash] || k["hash"]
          }
        end)

      send_and_pend(state, %{cmd: "diff_hashes", token: token, known: normalized}, from)
    else
      {:error, reason} -> {:reply, {:error, {:token_error, reason}}, state}
    end
  end

  def handle_call(:graph_token, _from, state) do
    case ensure_token(state) do
      {:ok, token} -> {:reply, {:ok, token}, state}
      {:error, reason} -> {:reply, {:error, {:token_error, reason}}, state}
    end
  end

  def handle_call({:hash_local, path}, from, state) do
    send_and_pend(state, %{cmd: "hash_local", path: path}, from)
  end

  # Send command and register caller as pending
  defp send_and_pend(%{port: nil} = state, _cmd, _from) do
    {:reply, {:error, :scanner_not_running}, state}
  end

  defp send_and_pend(state, cmd, from) do
    case send_command(state, cmd) do
      {:ok, new_state} ->
        {:noreply, %{new_state | pending: Map.put(new_state.pending, new_state.request_id, from)}}
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    lines = case data do
      {:eol, line} -> [line]
      line when is_binary(line) -> String.split(line, "\n", trim: true)
    end

    new_state =
      Enum.reduce(lines, state, fn line, acc ->
        case Jason.decode(line) do
          {:ok, response} ->
            case pop_pending(acc) do
              {from, new_pending} ->
                result = parse_response(response)
                GenServer.reply(from, result)
                %{acc | pending: new_pending}

              nil ->
                Logger.debug("Scanner response with no pending caller")
                acc
            end

          {:error, _} ->
            Logger.debug("Scanner non-JSON: #{line}")
            acc
        end
      end)

    {:noreply, new_state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning("Scanner exited with status #{status}, restarting...")

    Enum.each(state.pending, fn {_id, from} ->
      GenServer.reply(from, {:error, :scanner_crashed})
    end)

    Process.send_after(self(), :restart_scanner, 1_000)
    {:noreply, %{state | port: nil, pending: %{}}}
  end

  def handle_info(:restart_scanner, state) do
    case start_scanner(state) do
      {:ok, new_state} ->
        Logger.info("Scanner restarted")
        {:noreply, new_state}

      {:error, reason} ->
        Logger.error("Scanner restart failed: #{inspect(reason)}")
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

  def handle_info(_msg, state), do: {:noreply, state}

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

  defp send_command(%{port: port} = state, cmd) do
    json_line = Jason.encode!(cmd) <> "\n"
    Port.command(port, json_line)
    {:ok, %{state | request_id: state.request_id + 1}}
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

  defp parse_response(%{"status" => "ok"} = response) do
    result =
      response
      |> Map.drop(["status"])
      |> decode_content_if_present()

    {:ok, result}
  end

  defp parse_response(%{"status" => "error", "error" => error} = response) do
    detail = Map.get(response, "detail", "")
    {:error, {String.to_atom(error), detail}}
  end

  defp parse_response(other) do
    {:error, {:unexpected_response, other}}
  end

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
  # TOKEN MANAGEMENT
  # ──────────────────────────────────────────────────────────

  defp ensure_token(state) do
    now = System.system_time(:second)

    if state.token && state.token_expires_at && state.token_expires_at > now do
      {:ok, "Bearer " <> state.token}
    else
      case fetch_graph_token() do
        {:ok, token, _} -> {:ok, "Bearer " <> token}
        {:error, reason} -> {:error, reason}
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
end
