defmodule AmmoniaDesk.Contracts.HashVerifier do
  @moduledoc """
  Computes and verifies document hashes for contract integrity.

  Every ingested contract gets a SHA-256 hash of its original document bytes.
  This hash is stored with the contract and can be re-verified against the
  network copy at any time to detect:
    - Unauthorized modifications to contract files
    - File corruption during transfer
    - Version mismatches between local and network copies

  Verification workflow:
    1. On ingestion: compute hash and store with contract
    2. On demand: re-read file from network_path, compute hash, compare
    3. Periodic: verify_all checks every contract in the store

  All hashing is done locally using Erlang's :crypto module (SHA-256).
  """

  alias AmmoniaDesk.Contracts.{Contract, Store}

  require Logger

  @hash_algorithm :sha256

  # ──────────────────────────────────────────────────────────
  # HASH COMPUTATION
  # ──────────────────────────────────────────────────────────

  @doc """
  Compute the SHA-256 hash of a file's raw bytes.
  Returns {:ok, hash_hex, file_size} or {:error, reason}.
  """
  @spec compute_file_hash(String.t()) :: {:ok, String.t(), non_neg_integer()} | {:error, atom()}
  def compute_file_hash(path) do
    case File.read(path) do
      {:ok, bytes} ->
        hash = :crypto.hash(@hash_algorithm, bytes) |> Base.encode16(case: :lower)
        {:ok, hash, byte_size(bytes)}

      {:error, :enoent} ->
        {:error, :file_not_found}

      {:error, reason} ->
        Logger.error("Failed to read file for hashing: #{path} — #{inspect(reason)}")
        {:error, :read_failed}
    end
  end

  @doc """
  Compute hash from raw bytes (for when we already have the content).
  """
  @spec compute_hash(binary()) :: String.t()
  def compute_hash(bytes) when is_binary(bytes) do
    :crypto.hash(@hash_algorithm, bytes) |> Base.encode16(case: :lower)
  end

  # ──────────────────────────────────────────────────────────
  # SINGLE CONTRACT VERIFICATION
  # ──────────────────────────────────────────────────────────

  @doc """
  Verify a contract's stored hash against the file at its network_path.

  Returns:
    {:ok, :verified}             — hashes match
    {:ok, :mismatch, details}    — hashes differ (contract may have been modified)
    {:error, :no_network_path}   — contract has no network_path set
    {:error, :file_not_found}    — network file doesn't exist
    {:error, reason}             — other failure
  """
  @spec verify_contract(String.t()) :: {:ok, atom()} | {:ok, atom(), map()} | {:error, atom()}
  def verify_contract(contract_id) do
    with {:ok, contract} <- Store.get(contract_id),
         {:ok, path} <- get_network_path(contract),
         {:ok, network_hash, network_size} <- compute_file_hash(path) do
      now = DateTime.utc_now()

      if network_hash == contract.file_hash do
        # Match — update verification timestamp
        Store.update_verification(contract_id, %{
          verification_status: :verified,
          last_verified_at: now
        })

        Logger.info("Contract #{contract_id} verified: hash matches network copy")
        {:ok, :verified}
      else
        # Mismatch — flag it
        details = %{
          stored_hash: contract.file_hash,
          network_hash: network_hash,
          stored_size: contract.file_size,
          network_size: network_size,
          network_path: path,
          detected_at: now
        }

        Store.update_verification(contract_id, %{
          verification_status: :mismatch,
          last_verified_at: now
        })

        Logger.warning(
          "Contract #{contract_id} HASH MISMATCH: " <>
          "stored=#{String.slice(contract.file_hash || "", 0, 12)}... " <>
          "network=#{String.slice(network_hash, 0, 12)}..."
        )

        {:ok, :mismatch, details}
      end
    else
      {:error, :not_found} -> {:error, :contract_not_found}
      {:error, :no_network_path} -> {:error, :no_network_path}
      {:error, :file_not_found} ->
        Store.update_verification(contract_id, %{
          verification_status: :file_not_found,
          last_verified_at: DateTime.utc_now()
        })
        {:error, :file_not_found}
      {:error, reason} ->
        Store.update_verification(contract_id, %{
          verification_status: :error,
          last_verified_at: DateTime.utc_now()
        })
        {:error, reason}
    end
  end

  # ──────────────────────────────────────────────────────────
  # BATCH VERIFICATION
  # ──────────────────────────────────────────────────────────

  @doc """
  Verify all contracts in a product group against their network copies.
  Returns a summary with counts and details of any mismatches.
  """
  @spec verify_product_group(atom()) :: {:ok, map()}
  def verify_product_group(product_group) do
    contracts = Store.list_by_product_group(product_group)

    results =
      contracts
      |> Enum.map(fn contract ->
        result = if contract.network_path do
          verify_contract(contract.id)
        else
          {:error, :no_network_path}
        end

        {contract.id, contract.counterparty, contract.source_file, result}
      end)

    verified = Enum.count(results, fn {_, _, _, r} -> r == {:ok, :verified} end)
    mismatches = Enum.filter(results, fn {_, _, _, r} -> match?({:ok, :mismatch, _}, r) end)
    not_found = Enum.count(results, fn {_, _, _, r} -> r == {:error, :file_not_found} end)
    no_path = Enum.count(results, fn {_, _, _, r} -> r == {:error, :no_network_path} end)
    errors = Enum.count(results, fn {_, _, _, r} ->
      not match?({:ok, _}, r) and not match?({:ok, _, _}, r) and
      r != {:error, :file_not_found} and r != {:error, :no_network_path}
    end)

    {:ok, %{
      total: length(results),
      verified: verified,
      mismatches: length(mismatches),
      mismatch_details: Enum.map(mismatches, fn {id, cp, file, {:ok, :mismatch, details}} ->
        %{contract_id: id, counterparty: cp, source_file: file, details: details}
      end),
      file_not_found: not_found,
      no_network_path: no_path,
      errors: errors,
      verified_at: DateTime.utc_now()
    }}
  end

  @doc """
  Verify all contracts across all product groups.
  """
  @spec verify_all() :: {:ok, map()}
  def verify_all do
    product_groups = [:ammonia, :uan, :urea]

    results =
      Enum.map(product_groups, fn pg ->
        {:ok, summary} = verify_product_group(pg)
        {pg, summary}
      end)

    total_verified = Enum.sum(Enum.map(results, fn {_, s} -> s.verified end))
    total_mismatches = Enum.sum(Enum.map(results, fn {_, s} -> s.mismatches end))

    {:ok, %{
      by_product_group: Map.new(results),
      total_verified: total_verified,
      total_mismatches: total_mismatches,
      verified_at: DateTime.utc_now()
    }}
  end

  # ──────────────────────────────────────────────────────────
  # VERIFICATION REPORT
  # ──────────────────────────────────────────────────────────

  @doc """
  Generate a verification report for a single contract showing
  hash details, verification history, and version chain.
  """
  @spec contract_report(String.t()) :: {:ok, map()} | {:error, atom()}
  def contract_report(contract_id) do
    with {:ok, contract} <- Store.get(contract_id) do
      {:ok, %{
        contract_id: contract.id,
        contract_number: contract.contract_number,
        counterparty: contract.counterparty,
        source_file: contract.source_file,
        network_path: contract.network_path,
        file_hash: contract.file_hash,
        file_size: contract.file_size,
        previous_hash: contract.previous_hash,
        verification_status: contract.verification_status || :pending,
        last_verified_at: contract.last_verified_at,
        version: contract.version,
        status: contract.status,
        expired: Contract.expired?(contract)
      }}
    end
  end

  # ──────────────────────────────────────────────────────────
  # HELPERS
  # ──────────────────────────────────────────────────────────

  defp get_network_path(%Contract{network_path: nil}), do: {:error, :no_network_path}
  defp get_network_path(%Contract{network_path: ""}), do: {:error, :no_network_path}
  defp get_network_path(%Contract{network_path: path}), do: {:ok, path}
end
