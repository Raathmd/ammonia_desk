defmodule TradingDesk.Contracts.SeedLoader do
  @moduledoc """
  Loads seed contract files, parses them, and ingests them into the Store
  with realistic open positions for solver testing.

  Each seed contract represents an open commitment in Trammo's ammonia book.
  The open position is the quantity still outstanding (not yet delivered/lifted)
  as of the current date. The solver needs this to compute:
    - How much product must still flow through each route
    - What penalties are at risk if volumes fall short
    - Where Trammo is long (excess supply) vs short (excess obligations)

  Usage:
    SeedLoader.load_all()           # parse + ingest all seed contracts
    SeedLoader.open_book_summary()  # aggregate open positions
  """

  alias TradingDesk.Contracts.{Parser, Contract, Store, ConstraintBridge}

  require Logger

  @seed_dir "priv/contracts/seed"

  # Open positions per contract as of Feb 2026.
  # These represent the remaining obligation for the current contract year.
  # Format: {filename_prefix, counterparty, counterparty_type, open_position_mt}
  @seed_positions [
    {"01_purchase_lt_fob_trinidad",  "NGC Trinidad",     :supplier, 150_000},
    {"02_purchase_lt_fob_mideast",   "SABIC Agri-Nutrients", :supplier, 112_500},
    {"03_purchase_spot_fob_yuzhnyy", "Ameropa AG",       :supplier,  23_000},
    {"04_purchase_domestic_barge",   "LSB Industries",   :supplier,  24_000},
    {"05_sale_lt_cfr_tampa",         "Mosaic Company",   :customer,  75_000},
    {"06_sale_lt_cfr_india",         "IFFCO",            :customer, 100_000},
    {"07_sale_spot_cfr_morocco",     "OCP Group",        :customer,  20_000},
    {"08_sale_domestic_barge_stl",   "Nutrien StL",      :customer,  15_000},
    {"09_sale_domestic_barge_memphis", "Koch Fertilizer", :customer,  12_000},
    {"10_sale_spot_dap_nwe",         "BASF SE",          :customer,  15_000}
  ]

  @doc """
  Load all seed contracts from priv/contracts/seed/.

  Parses each file, detects family and incoterm, sets open position,
  and ingests into the Store. Returns list of ingested contracts.
  """
  def load_all do
    seed_path = Application.app_dir(:trading_desk, @seed_dir)

    results =
      @seed_positions
      |> Enum.map(fn {prefix, counterparty, cp_type, open_qty} ->
        case find_seed_file(seed_path, prefix) do
          {:ok, file_path} ->
            load_one(file_path, counterparty, cp_type, open_qty)

          :not_found ->
            Logger.warning("Seed file not found for prefix: #{prefix}")
            {:error, {:file_not_found, prefix}}
        end
      end)

    loaded = Enum.filter(results, &match?({:ok, _}, &1)) |> Enum.map(&elem(&1, 1))
    errors = Enum.filter(results, &match?({:error, _}, &1))

    if length(errors) > 0 do
      Logger.warning("#{length(errors)} seed contract(s) failed to load")
    end

    Logger.info(
      "Loaded #{length(loaded)} seed contracts: " <>
      "#{length(Enum.filter(loaded, &(&1.counterparty_type == :supplier)))} purchases, " <>
      "#{length(Enum.filter(loaded, &(&1.counterparty_type == :customer)))} sales"
    )

    loaded
  end

  @doc """
  Load seed contracts from a custom directory (for testing).
  """
  def load_all(seed_path) when is_binary(seed_path) do
    @seed_positions
    |> Enum.map(fn {prefix, counterparty, cp_type, open_qty} ->
      case find_seed_file(seed_path, prefix) do
        {:ok, file_path} -> load_one(file_path, counterparty, cp_type, open_qty)
        :not_found -> {:error, {:file_not_found, prefix}}
      end
    end)
    |> Enum.filter(&match?({:ok, _}, &1))
    |> Enum.map(&elem(&1, 1))
  end

  @doc """
  Get a summary of the open book after seed contracts are loaded.

  Delegates to ConstraintBridge.aggregate_open_book/1.
  """
  def open_book_summary(product_group \\ :ammonia) do
    ConstraintBridge.aggregate_open_book(product_group)
  end

  @doc """
  Get the penalty schedule for all loaded seed contracts.
  """
  def penalty_summary(product_group \\ :ammonia) do
    ConstraintBridge.penalty_schedule(product_group)
  end

  @doc """
  Return the seed position data without loading (for testing/inspection).
  """
  def seed_positions, do: @seed_positions

  # ── Private ──────────────────────────────────────────────

  defp load_one(file_path, counterparty, cp_type, open_qty) do
    text = File.read!(file_path)
    {clauses, _warnings, detected_family} = Parser.parse(text)

    {family_id, family} =
      case detected_family do
        {:ok, fid, fam} -> {fid, fam}
        :unknown -> {nil, nil}
      end

    incoterm =
      case Enum.find(clauses, &(&1.clause_id == "INCOTERMS")) do
        %{extracted_fields: %{incoterm_rule: rule}} when is_binary(rule) ->
          rule |> String.downcase() |> String.to_existing_atom()
        _ ->
          if family, do: List.first(family.default_incoterms), else: nil
      end

    template_type =
      case {family && family.direction, family && family.term_type} do
        {:purchase, :long_term} -> :purchase
        {:purchase, :spot}      -> :spot_purchase
        {:sale, :long_term}     -> :sale
        {:sale, :spot}          -> :spot_sale
        _                       -> if(cp_type == :supplier, do: :purchase, else: :sale)
      end

    term_type = if(family, do: family.term_type, else: :spot)
    transport = if(family, do: family.transport, else: :vessel)

    company =
      cond do
        String.contains?(text, "Trammo SAS") -> :trammo_sas
        String.contains?(text, "Trammo DMCC") -> :trammo_dmcc
        true -> :trammo_inc
      end

    contract_number = extract_contract_number(text)

    contract = %Contract{
      counterparty: counterparty,
      counterparty_type: cp_type,
      product_group: :ammonia,
      template_type: template_type,
      incoterm: incoterm,
      term_type: term_type,
      company: company,
      source_file: Path.basename(file_path),
      source_format: :txt,
      clauses: clauses,
      family_id: family_id,
      contract_number: contract_number,
      open_position: open_qty
    }

    case Store.ingest(contract) do
      {:ok, ingested} ->
        # Auto-approve for seed data (skip legal review workflow)
        Store.update_status(ingested.id, :pending_review)
        Store.update_status(ingested.id, :approved,
          reviewed_by: "seed_loader",
          notes: "Auto-approved seed contract for solver testing"
        )

        Logger.info(
          "Seed: #{counterparty} (#{cp_type}) #{incoterm} | " <>
          "family=#{family_id} | open=#{open_qty} MT | " <>
          "clauses=#{length(clauses)} | penalties=#{count_penalties(clauses)}"
        )

        {:ok, ingested}

      error ->
        Logger.error("Failed to ingest seed contract #{counterparty}: #{inspect(error)}")
        error
    end
  end

  defp find_seed_file(seed_path, prefix) do
    case Path.wildcard(Path.join(seed_path, "#{prefix}*.txt")) do
      [file | _] -> {:ok, file}
      [] -> :not_found
    end
  end

  defp extract_contract_number(text) do
    case Regex.run(~r/Contract\s+No\.?\s*:?\s*(TRAMMO-[A-Z0-9-]+)/i, text) do
      [_, number] -> number
      _ -> nil
    end
  end

  defp count_penalties(clauses) do
    Enum.count(clauses, fn c ->
      c.clause_id in ["PENALTY_VOLUME_SHORTFALL", "PENALTY_LATE_DELIVERY", "LAYTIME_DEMURRAGE"]
    end)
  end
end
