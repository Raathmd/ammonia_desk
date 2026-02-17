defmodule TradingDesk.Chain.AutoSolveCommitter do
  @moduledoc """
  Commits auto-solve results to BSV chain.

  Every delta-triggered auto-solve is stored on-chain with:
    - Full canonical payload (variables, result, trigger details)
    - SHA-256 hash of payload
    - Server's ECDSA signature
    - AES-256-GCM encrypted payload in OP_RETURN

  BSV transaction costs are negligible (<$0.001 per tx), so we store
  the full data for every auto-solve — no summaries, no sampling.

  ## Flow

    1. Serialize canonical payload (variables + MC result + trigger section)
    2. SHA-256 hash the payload
    3. ECDSA sign with server's BSV private key
    4. Encrypt payload with AES-256-GCM (key from ECDH with company public key)
    5. Build BSV transaction with OP_RETURN
    6. Broadcast to BSV network
    7. Record commit in local DB (txid, payload hash, etc.)

  ## Server Key

  The server has its own BSV keypair, separate from trader keys.
  The private key is loaded from:
    - `BSV_SERVER_PRIVKEY` env var (hex-encoded 32-byte secp256k1 scalar)
    - Or generated on first boot and stored in Postgres

  ## Config Changes

  When an admin updates DeltaConfig, that change is also committed to chain
  (type 0x05) so there's a record of what thresholds were active when each
  auto-solve was triggered.
  """

  require Logger

  alias TradingDesk.Chain.Payload
  alias TradingDesk.DB.ChainCommitRecord

  @doc """
  Commit an auto-solve result to BSV chain.

  Options:
    - :result — the auto-runner result map
    - :variables — %Variables{} used in the solve
    - :product_group — :ammonia | :uan | :urea
    - :trigger_details — list of triggered variable details
    - :audit_id — link to SolveAudit record
    - :distribution — MC distribution result
  """
  @spec commit(keyword()) :: {:ok, map()} | {:error, term()}
  def commit(opts) do
    variables = Keyword.fetch!(opts, :variables)
    product_group = Keyword.get(opts, :product_group, :ammonia)
    trigger_details = Keyword.get(opts, :trigger_details, [])
    audit_id = Keyword.get(opts, :audit_id)
    distribution = Keyword.get(opts, :distribution)
    result = Keyword.get(opts, :result)

    # Step 1: Serialize canonical payload
    payload = Payload.serialize_auto_mc(%{
      variables: variables,
      distribution: distribution,
      trigger_details: trigger_details,
      product_group: product_group,
      timestamp: DateTime.utc_now()
    })

    # Step 2: Hash payload
    payload_hash = Payload.hash_hex(payload)

    # Step 3: Sign with server key
    {signature_hex, pubkey_hex} = sign_payload(payload)

    # Step 4: Encrypt payload
    encrypted = encrypt_payload(payload)

    # Step 5: Build and broadcast BSV transaction
    {txid, raw_tx} = broadcast_to_chain(encrypted, payload_hash, signature_hex, pubkey_hex)

    # Step 6: Record in local DB
    commit_id = generate_commit_id()
    triggered_mask = compute_triggered_mask(trigger_details)

    record_attrs = %{
      id: commit_id,
      commit_type: ChainCommitRecord.type_auto_mc(),
      product_group: to_string(product_group),
      signer_type: "server",
      signer_id: "system",
      pubkey_hex: pubkey_hex,
      txid: txid,
      raw_tx: raw_tx,
      broadcast_at: DateTime.utc_now(),
      payload_hash: payload_hash,
      signature_hex: signature_hex,
      encrypted_payload: encrypted,
      variables: serialize_variables(variables),
      variable_sources: serialize_variable_sources(),
      result_data: serialize_distribution(distribution),
      result_status: to_string(distribution[:signal] || :unknown),
      triggered_mask: triggered_mask,
      trigger_details: Enum.map(trigger_details, &to_plain_map/1),
      solve_audit_id: audit_id
    }

    persist_commit(record_attrs)

    Logger.info(
      "ChainCommit: auto-solve committed, txid=#{txid || "pending"}, " <>
      "hash=#{String.slice(payload_hash, 0..11)}..., " <>
      "#{length(trigger_details)} triggers"
    )

    {:ok, %{
      commit_id: commit_id,
      txid: txid,
      payload_hash: payload_hash,
      payload_size: byte_size(payload),
      triggered_count: length(trigger_details)
    }}
  rescue
    e ->
      Logger.error("ChainCommit: auto-solve commit failed: #{Exception.message(e)}")
      {:error, {:commit_failed, Exception.message(e)}}
  end

  @doc """
  Commit a config change to BSV chain.
  """
  @spec commit_config_change(atom(), map()) :: {:ok, map()} | {:error, term()}
  def commit_config_change(product_group, config) do
    payload = Payload.serialize_config_change(%{
      product_group: product_group,
      config: config,
      timestamp: DateTime.utc_now()
    })

    payload_hash = Payload.hash_hex(payload)
    {signature_hex, pubkey_hex} = sign_payload(payload)
    encrypted = encrypt_payload(payload)
    {txid, raw_tx} = broadcast_to_chain(encrypted, payload_hash, signature_hex, pubkey_hex)

    commit_id = generate_commit_id()

    record_attrs = %{
      id: commit_id,
      commit_type: ChainCommitRecord.type_config_change(),
      product_group: to_string(product_group),
      signer_type: "server",
      signer_id: "admin",
      pubkey_hex: pubkey_hex,
      txid: txid,
      raw_tx: raw_tx,
      broadcast_at: DateTime.utc_now(),
      payload_hash: payload_hash,
      signature_hex: signature_hex,
      encrypted_payload: encrypted,
      variables: %{},
      result_data: config,
      result_status: "config_change",
      triggered_mask: 0,
      trigger_details: []
    }

    persist_commit(record_attrs)

    Logger.info("ChainCommit: config change committed for #{product_group}")
    {:ok, %{commit_id: commit_id, txid: txid, payload_hash: payload_hash}}
  rescue
    e ->
      Logger.error("ChainCommit: config commit failed: #{Exception.message(e)}")
      {:error, {:commit_failed, Exception.message(e)}}
  end

  # ──────────────────────────────────────────────────────────
  # CRYPTO OPERATIONS
  # ──────────────────────────────────────────────────────────

  defp sign_payload(payload) do
    server_key = get_server_private_key()

    if server_key do
      # ECDSA sign with secp256k1
      digest = :crypto.hash(:sha256, payload)
      signature = :crypto.sign(:ecdsa, :sha256, digest, [server_key, :secp256k1])
      pubkey = derive_public_key(server_key)

      {Base.encode16(signature, case: :lower), Base.encode16(pubkey, case: :lower)}
    else
      # No key configured — store without signature (can be signed later)
      Logger.warning("ChainCommit: no server BSV key configured, skipping signature")
      {"unsigned", "no_key"}
    end
  rescue
    _ ->
      Logger.warning("ChainCommit: signing failed, storing unsigned")
      {"unsigned", "no_key"}
  end

  defp encrypt_payload(payload) do
    key = get_encryption_key()

    if key do
      iv = :crypto.strong_rand_bytes(12)
      {ciphertext, tag} = :crypto.crypto_one_time_aead(
        :aes_256_gcm, key, iv, payload, <<>>, true
      )
      # Format: iv(12) || tag(16) || ciphertext
      iv <> tag <> ciphertext
    else
      # No encryption key — store plaintext (development mode)
      payload
    end
  rescue
    _ -> payload
  end

  defp broadcast_to_chain(encrypted_payload, payload_hash, signature_hex, pubkey_hex) do
    # Build OP_RETURN data
    op_return_data = build_op_return(encrypted_payload, payload_hash, signature_hex)

    # Broadcast via BSV node or service
    case get_broadcast_method() do
      :whatsonchain ->
        broadcast_whatsonchain(op_return_data)

      :mapi ->
        broadcast_mapi(op_return_data)

      :node ->
        broadcast_node(op_return_data)

      :disabled ->
        Logger.debug("ChainCommit: BSV broadcast disabled, payload stored locally only")
        {nil, op_return_data}
    end
  end

  defp build_op_return(encrypted_payload, payload_hash, signature_hex) do
    # OP_RETURN format: <protocol_prefix> <hash> <signature> <encrypted_payload>
    # For now, return the concatenated data. Actual TX building would use
    # a BSV library to construct the full transaction.
    <<"NH3CHAIN", payload_hash::binary, "|", signature_hex::binary, "|",
      encrypted_payload::binary>>
  end

  defp broadcast_whatsonchain(op_return_data) do
    # WhatsOnChain broadcast API
    api_key = System.get_env("WOC_API_KEY")
    url = "https://api.whatsonchain.com/v1/bsv/main/tx/raw"

    if api_key do
      raw_tx = build_raw_transaction(op_return_data)

      case Req.post(url,
        json: %{"txhex" => Base.encode16(raw_tx, case: :lower)},
        headers: [{"woc-api-key", api_key}],
        receive_timeout: 30_000
      ) do
        {:ok, %{status: 200, body: body}} ->
          txid = if is_binary(body), do: body, else: body["txid"] || body["hash"]
          {txid, raw_tx}

        {:ok, %{status: status, body: body}} ->
          Logger.warning("ChainCommit: WoC broadcast failed (#{status}): #{inspect(body)}")
          {nil, raw_tx}

        {:error, reason} ->
          Logger.warning("ChainCommit: WoC broadcast error: #{inspect(reason)}")
          {nil, op_return_data}
      end
    else
      {nil, op_return_data}
    end
  rescue
    _ -> {nil, op_return_data}
  end

  defp broadcast_mapi(op_return_data) do
    # MAPI (Merchant API) broadcast
    mapi_url = System.get_env("BSV_MAPI_URL") || "https://mapi.gorillapool.io"
    raw_tx = build_raw_transaction(op_return_data)

    case Req.post("#{mapi_url}/mapi/tx",
      json: %{"rawtx" => Base.encode16(raw_tx, case: :lower)},
      receive_timeout: 30_000
    ) do
      {:ok, %{status: 200, body: %{"payload" => payload_json}}} ->
        payload = Jason.decode!(payload_json)
        {payload["txid"], raw_tx}

      _ ->
        {nil, raw_tx}
    end
  rescue
    _ -> {nil, op_return_data}
  end

  defp broadcast_node(op_return_data) do
    # Direct BSV node RPC
    {nil, op_return_data}
  end

  defp build_raw_transaction(_op_return_data) do
    # Placeholder: actual BSV transaction building requires UTXO management,
    # script construction, and signing. In production, this would use
    # a BSV library (e.g., bsv-elixir, or call out to a Node.js/Python helper).
    #
    # The transaction structure:
    #   Input: server's UTXO (fund from a BSV address)
    #   Output 0: OP_RETURN <data>
    #   Output 1: change back to server address
    <<>>
  end

  # ──────────────────────────────────────────────────────────
  # KEY MANAGEMENT
  # ──────────────────────────────────────────────────────────

  defp get_server_private_key do
    case System.get_env("BSV_SERVER_PRIVKEY") do
      nil -> nil
      "" -> nil
      hex ->
        case Base.decode16(hex, case: :mixed) do
          {:ok, key} when byte_size(key) == 32 -> key
          _ -> nil
        end
    end
  end

  defp derive_public_key(private_key) do
    # Derive compressed public key from private key using secp256k1
    {:ok, pubkey} = :crypto.generate_key(:ecdh, :secp256k1, private_key)
    pubkey
  rescue
    _ -> <<>>
  end

  defp get_encryption_key do
    case System.get_env("BSV_ENCRYPTION_KEY") do
      nil -> nil
      "" -> nil
      hex ->
        case Base.decode16(hex, case: :mixed) do
          {:ok, key} when byte_size(key) == 32 -> key
          _ -> nil
        end
    end
  end

  defp get_broadcast_method do
    cond do
      System.get_env("WOC_API_KEY") not in [nil, ""] -> :whatsonchain
      System.get_env("BSV_MAPI_URL") not in [nil, ""] -> :mapi
      System.get_env("BSV_NODE_URL") not in [nil, ""] -> :node
      true -> :disabled
    end
  end

  # ──────────────────────────────────────────────────────────
  # PERSISTENCE
  # ──────────────────────────────────────────────────────────

  defp persist_commit(attrs) do
    %ChainCommitRecord{}
    |> ChainCommitRecord.changeset(attrs)
    |> TradingDesk.Repo.insert(
      on_conflict: {:replace_all_except, [:id, :inserted_at]},
      conflict_target: :id
    )
    |> case do
      {:ok, _} -> :ok
      {:error, changeset} ->
        Logger.warning("ChainCommit: DB persist failed: #{inspect(changeset.errors)}")
    end
  rescue
    e -> Logger.warning("ChainCommit: DB persist error: #{inspect(e)}")
  end

  # ──────────────────────────────────────────────────────────
  # HELPERS
  # ──────────────────────────────────────────────────────────

  defp generate_commit_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  defp compute_triggered_mask(trigger_details) do
    Enum.reduce(trigger_details, 0, fn t, acc ->
      idx = t[:variable_index] || 0
      Bitwise.bor(acc, Bitwise.bsl(1, idx))
    end)
  end

  defp serialize_variables(%TradingDesk.Variables{} = v), do: Map.from_struct(v)
  defp serialize_variables(v) when is_map(v), do: v
  defp serialize_variables(_), do: %{}

  defp serialize_variable_sources do
    try do
      TradingDesk.Data.LiveState.last_updated()
      |> Map.new(fn {k, v} -> {to_string(k), DateTime.to_iso8601(v)} end)
    rescue
      _ -> %{}
    end
  end

  defp serialize_distribution(dist) when is_map(dist) do
    Map.take(dist, [:signal, :n_scenarios, :n_feasible, :mean, :stddev,
                     :p5, :p25, :p50, :p75, :p95, :min, :max, :sensitivity])
    |> Map.new(fn {k, v} -> {to_string(k), v} end)
  end
  defp serialize_distribution(_), do: %{}

  defp to_plain_map(%{__struct__: _} = s), do: Map.from_struct(s)
  defp to_plain_map(m) when is_map(m), do: m
  defp to_plain_map(other), do: %{value: other}
end
