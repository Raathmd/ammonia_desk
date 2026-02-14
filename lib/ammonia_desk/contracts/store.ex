defmodule AmmoniaDesk.Contracts.Store do
  @moduledoc """
  Stores parsed contracts with unique identity and version control.

  Identity: {counterparty, product_group} — only ONE approved contract
  per counterparty+product_group at any time. Uploading a new version
  supersedes the prior (but prior versions are retained for audit).

  Tables:
    :contracts       — {contract_id, %Contract{}}
    :contract_index  — {{counterparty, product_group}, [contract_ids]} ordered by version
    :active_set      — {{counterparty, product_group}, contract_id} for currently approved
  """
  use GenServer
  require Logger

  alias AmmoniaDesk.Contracts.Contract

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  # --- Public API ---

  @doc "Ingest a new contract. Auto-assigns version number. Returns {:ok, contract} or {:error, reason}."
  def ingest(%Contract{} = contract) do
    GenServer.call(__MODULE__, {:ingest, contract})
  end

  @doc "Get a contract by ID"
  def get(contract_id) do
    GenServer.call(__MODULE__, {:get, contract_id})
  end

  @doc "List all contracts for a counterparty+product_group, newest first"
  def list_versions(counterparty, product_group) do
    GenServer.call(__MODULE__, {:list_versions, counterparty, product_group})
  end

  @doc "List all contracts in a product group"
  def list_by_product_group(product_group) do
    GenServer.call(__MODULE__, {:list_by_product_group, product_group})
  end

  @doc "Get the active (approved) contract for a counterparty+product_group"
  def get_active(counterparty, product_group) do
    GenServer.call(__MODULE__, {:get_active, counterparty, product_group})
  end

  @doc "Get all active contracts for a product group"
  def get_active_set(product_group) do
    GenServer.call(__MODULE__, {:get_active_set, product_group})
  end

  @doc "Update contract status (used by legal review workflow)"
  def update_status(contract_id, new_status, opts \\ []) do
    GenServer.call(__MODULE__, {:update_status, contract_id, new_status, opts})
  end

  @doc "Update open position for a counterparty+product_group"
  def update_open_position(counterparty, product_group, position_tons) do
    GenServer.call(__MODULE__, {:update_open_position, counterparty, product_group, position_tons})
  end

  @doc "Update SAP validation results on a contract"
  def update_sap_validation(contract_id, sap_result) do
    GenServer.call(__MODULE__, {:update_sap_validation, contract_id, sap_result})
  end

  @doc "Update template validation results on a contract"
  def update_template_validation(contract_id, validation_result) do
    GenServer.call(__MODULE__, {:update_template_validation, contract_id, validation_result})
  end

  @doc "Update LLM validation results on a contract"
  def update_llm_validation(contract_id, validation_result) do
    GenServer.call(__MODULE__, {:update_llm_validation, contract_id, validation_result})
  end

  @doc "Update hash verification results on a contract"
  def update_verification(contract_id, verification_result) do
    GenServer.call(__MODULE__, {:update_verification, contract_id, verification_result})
  end

  @doc "List all contracts across all product groups"
  def list_all do
    GenServer.call(__MODULE__, :list_all)
  end

  @doc "Get all unique counterparties in a product group"
  def counterparties(product_group) do
    GenServer.call(__MODULE__, {:counterparties, product_group})
  end

  # --- GenServer ---

  @impl true
  def init(_) do
    contracts = :ets.new(:contracts, [:set, :protected])
    index = :ets.new(:contract_index, [:set, :protected])
    active = :ets.new(:active_set, [:set, :protected])

    {:ok, %{contracts: contracts, index: index, active: active}}
  end

  @impl true
  def handle_call({:ingest, contract}, _from, state) do
    key = Contract.canonical_key(contract)

    # Auto-assign version: max existing version + 1
    version = next_version(state.index, key)

    contract = %{contract |
      id: Contract.generate_id(),
      version: version,
      status: :draft,
      scan_date: DateTime.utc_now(),
      sap_validated: false,
      created_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    }

    # Store contract
    :ets.insert(state.contracts, {contract.id, contract})

    # Update version index
    existing_ids = case :ets.lookup(state.index, key) do
      [{^key, ids}] -> ids
      [] -> []
    end
    :ets.insert(state.index, {key, existing_ids ++ [contract.id]})

    Logger.info(
      "Contract ingested: #{contract.counterparty} / #{contract.product_group} v#{version} " <>
      "(#{length(contract.clauses || [])} clauses, id=#{contract.id})"
    )

    # Persist to Postgres (async — never blocks)
    AmmoniaDesk.DB.Writer.persist_contract(contract)

    {:reply, {:ok, contract}, state}
  end

  @impl true
  def handle_call({:get, contract_id}, _from, state) do
    case :ets.lookup(state.contracts, contract_id) do
      [{^contract_id, contract}] -> {:reply, {:ok, contract}, state}
      [] -> {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:list_versions, counterparty, product_group}, _from, state) do
    key = {normalize_name(counterparty), product_group}
    contracts = get_contracts_for_key(state, key)
    {:reply, Enum.reverse(contracts), state}
  end

  @impl true
  def handle_call({:list_by_product_group, product_group}, _from, state) do
    contracts =
      :ets.tab2list(state.index)
      |> Enum.filter(fn {{_cp, pg}, _ids} -> pg == product_group end)
      |> Enum.flat_map(fn {_key, ids} ->
        Enum.map(ids, fn id ->
          case :ets.lookup(state.contracts, id) do
            [{^id, c}] -> c
            [] -> nil
          end
        end)
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.sort_by(& &1.updated_at, {:desc, DateTime})

    {:reply, contracts, state}
  end

  @impl true
  def handle_call({:get_active, counterparty, product_group}, _from, state) do
    key = {normalize_name(counterparty), product_group}
    case :ets.lookup(state.active, key) do
      [{^key, contract_id}] ->
        case :ets.lookup(state.contracts, contract_id) do
          [{^contract_id, contract}] -> {:reply, {:ok, contract}, state}
          [] -> {:reply, {:error, :not_found}, state}
        end
      [] ->
        {:reply, {:error, :no_active_contract}, state}
    end
  end

  @impl true
  def handle_call({:get_active_set, product_group}, _from, state) do
    active_contracts =
      :ets.tab2list(state.active)
      |> Enum.filter(fn {{_cp, pg}, _id} -> pg == product_group end)
      |> Enum.map(fn {_key, contract_id} ->
        case :ets.lookup(state.contracts, contract_id) do
          [{^contract_id, c}] -> c
          [] -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    {:reply, active_contracts, state}
  end

  @impl true
  def handle_call({:update_status, contract_id, new_status, opts}, _from, state) do
    case :ets.lookup(state.contracts, contract_id) do
      [{^contract_id, contract}] ->
        case validate_transition(contract.status, new_status) do
          :ok ->
            updated = %{contract |
              status: new_status,
              reviewed_by: Keyword.get(opts, :reviewed_by),
              reviewed_at: if(new_status in [:approved, :rejected], do: DateTime.utc_now()),
              review_notes: Keyword.get(opts, :notes),
              updated_at: DateTime.utc_now()
            }

            :ets.insert(state.contracts, {contract_id, updated})

            # If approved, set as active (deactivating any prior version)
            if new_status == :approved do
              key = Contract.canonical_key(updated)
              # Deactivate previous active contract for this key
              case :ets.lookup(state.active, key) do
                [{^key, old_id}] when old_id != contract_id ->
                  case :ets.lookup(state.contracts, old_id) do
                    [{^old_id, old_contract}] ->
                      deactivated = %{old_contract | status: :superseded, updated_at: DateTime.utc_now()}
                      :ets.insert(state.contracts, {old_id, deactivated})
                    _ -> :ok
                  end
                _ -> :ok
              end

              :ets.insert(state.active, {key, contract_id})

              Logger.info(
                "Contract approved and activated: #{updated.counterparty} / " <>
                "#{updated.product_group} v#{updated.version}"
              )
            end

            # Persist status change to Postgres
            AmmoniaDesk.DB.Writer.persist_contract(updated)

            {:reply, {:ok, updated}, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:update_open_position, counterparty, product_group, position}, _from, state) do
    key = {normalize_name(counterparty), product_group}
    case :ets.lookup(state.active, key) do
      [{^key, contract_id}] ->
        case :ets.lookup(state.contracts, contract_id) do
          [{^contract_id, contract}] ->
            updated = %{contract | open_position: position, updated_at: DateTime.utc_now()}
            :ets.insert(state.contracts, {contract_id, updated})
            {:reply, {:ok, updated}, state}
          [] ->
            {:reply, {:error, :not_found}, state}
        end
      [] ->
        {:reply, {:error, :no_active_contract}, state}
    end
  end

  @impl true
  def handle_call({:update_sap_validation, contract_id, sap_result}, _from, state) do
    case :ets.lookup(state.contracts, contract_id) do
      [{^contract_id, contract}] ->
        updated = %{contract |
          sap_validated: sap_result.valid,
          sap_contract_id: sap_result.sap_contract_id,
          sap_discrepancies: sap_result.discrepancies,
          updated_at: DateTime.utc_now()
        }
        :ets.insert(state.contracts, {contract_id, updated})
        {:reply, {:ok, updated}, state}
      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:update_template_validation, contract_id, result}, _from, state) do
    case :ets.lookup(state.contracts, contract_id) do
      [{^contract_id, contract}] ->
        updated = %{contract | template_validation: result, updated_at: DateTime.utc_now()}
        :ets.insert(state.contracts, {contract_id, updated})
        {:reply, {:ok, updated}, state}
      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:update_llm_validation, contract_id, result}, _from, state) do
    case :ets.lookup(state.contracts, contract_id) do
      [{^contract_id, contract}] ->
        updated = %{contract | llm_validation: result, updated_at: DateTime.utc_now()}
        :ets.insert(state.contracts, {contract_id, updated})
        {:reply, {:ok, updated}, state}
      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:update_verification, contract_id, result}, _from, state) do
    case :ets.lookup(state.contracts, contract_id) do
      [{^contract_id, contract}] ->
        updated = %{contract |
          verification_status: Map.get(result, :verification_status, contract.verification_status),
          last_verified_at: Map.get(result, :last_verified_at, contract.last_verified_at),
          updated_at: DateTime.utc_now()
        }
        :ets.insert(state.contracts, {contract_id, updated})
        {:reply, {:ok, updated}, state}
      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call(:list_all, _from, state) do
    contracts =
      :ets.tab2list(state.contracts)
      |> Enum.map(fn {_id, contract} -> contract end)
      |> Enum.sort_by(& &1.updated_at, {:desc, DateTime})

    {:reply, contracts, state}
  end

  @impl true
  def handle_call({:counterparties, product_group}, _from, state) do
    cps =
      :ets.tab2list(state.index)
      |> Enum.filter(fn {{_cp, pg}, _ids} -> pg == product_group end)
      |> Enum.map(fn {{cp, _pg}, _ids} -> cp end)
      |> Enum.uniq()
      |> Enum.sort()

    {:reply, cps, state}
  end

  # --- Private helpers ---

  defp next_version(index_table, key) do
    case :ets.lookup(index_table, key) do
      [{^key, ids}] -> length(ids) + 1
      [] -> 1
    end
  end

  defp get_contracts_for_key(state, key) do
    case :ets.lookup(state.index, key) do
      [{^key, ids}] ->
        Enum.map(ids, fn id ->
          case :ets.lookup(state.contracts, id) do
            [{^id, c}] -> c
            [] -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)
      [] -> []
    end
  end

  # Only valid status transitions
  defp validate_transition(:draft, :pending_review), do: :ok
  defp validate_transition(:pending_review, :approved), do: :ok
  defp validate_transition(:pending_review, :rejected), do: :ok
  defp validate_transition(:rejected, :pending_review), do: :ok  # allow resubmission
  defp validate_transition(from, to), do: {:error, {:invalid_transition, from, to}}

  defp normalize_name(name) when is_binary(name) do
    name |> String.trim() |> String.downcase()
  end
end
