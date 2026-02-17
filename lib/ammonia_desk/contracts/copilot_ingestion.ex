defmodule AmmoniaDesk.Contracts.CopilotIngestion do
  @moduledoc """
  Accepts pre-extracted clause data from Copilot (or any external extraction
  service) and ingests it into the contract system.

  This is the primary extraction path. Copilot reads the actual contract
  document, extracts clauses, maps them to the canonical inventory (or
  introduces new clause types), and returns structured JSON. This module
  accepts that output and creates a fully tracked contract in the Store.

  The app's deterministic parser runs as a cross-check verification layer
  after Copilot extraction, NOT as the primary extraction engine.

  ## Copilot extraction payload format

  Copilot returns a map (or JSON) with this structure:

      %{
        "contract_number" => "TRAMMO-LTP-2026-0001",
        "counterparty" => "Ma'aden Wa'ad Al Shamal Phosphate Company",
        "counterparty_type" => "supplier",
        "direction" => "purchase",
        "incoterm" => "FOB",
        "term_type" => "long_term",
        "company" => "trammo_inc",
        "effective_date" => "2026-01-01",
        "expiry_date" => "2028-12-31",
        "family_id" => "LONG_TERM_PURCHASE_FOB",
        "clauses" => [
          %{
            "clause_id" => "PRICE",
            "category" => "commercial",
            "extracted_fields" => %{
              "price_value" => 340.00,
              "price_uom" => "$/ton",
              "pricing_mechanism" => "fixed"
            },
            "source_text" => "Purchase Price: US $340.00 per metric ton...",
            "section_ref" => "Section 5",
            "confidence" => "high"
          },
          ...
        ],
        "new_clause_definitions" => [
          %{
            "clause_id" => "SANCTIONS_COMPLIANCE",
            "category" => "compliance",
            "anchors" => ["Sanctions", "OFAC", "restricted party"],
            "extract_fields" => ["sanctioned_parties_check", "ofac_screening"],
            "lp_mapping" => nil,
            "level_default" => "expected"
          }
        ]
      }

  New clause definitions (if any) are automatically registered in the
  TemplateRegistry so the deterministic parser can verify them on
  subsequent passes.
  """

  alias AmmoniaDesk.Contracts.{
    Clause,
    Contract,
    Store,
    HashVerifier,
    CurrencyTracker,
    TemplateRegistry,
    Parser
  }

  alias AmmoniaDesk.ProductGroup

  require Logger

  @pubsub AmmoniaDesk.PubSub
  @topic "contracts"

  # ──────────────────────────────────────────────────────────
  # PRIMARY INGESTION — Copilot provides extraction
  # ──────────────────────────────────────────────────────────

  @doc """
  Ingest a contract from Copilot's extraction output.

  `file_path` is the path to the original document (for hashing).
  `extraction` is the structured map from Copilot (see moduledoc).
  `opts` are overrides for product_group, network_path, sap_contract_id.

  Returns {:ok, contract} with:
    - All clauses from Copilot stored as %Clause{} structs
    - Document hash computed and stored
    - New clause types registered in TemplateRegistry
    - Deterministic parser cross-check results attached
  """
  @spec ingest(String.t(), map(), keyword()) :: {:ok, Contract.t()} | {:error, term()}
  def ingest(file_path, extraction, opts \\ []) do
    product_group = Keyword.get(opts, :product_group, :ammonia_domestic)

    with {:hash, {:ok, file_hash, file_size}} <- {:hash, HashVerifier.compute_file_hash(file_path)},
         {:extract, {:ok, clauses}} <- {:extract, build_clauses(extraction, product_group)} do

      # Register any new clause types Copilot discovered
      register_new_clauses(extraction)

      # Build the contract
      contract = build_contract(extraction, clauses, file_path, file_hash, file_size, opts)

      case Store.ingest(contract) do
        {:ok, stored} ->
          CurrencyTracker.stamp(stored.id, :parsed_at)

          # Run deterministic parser as cross-check (async, non-blocking)
          cross_check = run_parser_cross_check(file_path, clauses)

          broadcast(:copilot_ingestion_complete, %{
            contract_id: stored.id,
            contract_number: stored.contract_number,
            counterparty: stored.counterparty,
            copilot_clauses: length(clauses),
            cross_check: cross_check_summary(cross_check)
          })

          Logger.info(
            "Copilot ingestion: #{stored.counterparty} #{stored.contract_number || "?"} " <>
            "(#{length(clauses)} clauses, hash=#{String.slice(file_hash, 0, 12)}...)"
          )

          {:ok, stored}

        {:error, reason} ->
          {:error, {:store_failed, reason}}
      end
    else
      {:hash, {:error, reason}} -> {:error, {:hash_failed, reason}}
      {:extract, {:error, reason}} -> {:error, {:extraction_failed, reason}}
    end
  end

  @doc """
  Ingest from Copilot output when we already have the file hash
  (e.g., Copilot computed it). Skips re-reading the file for hashing.
  """
  @spec ingest_with_hash(map(), keyword()) :: {:ok, Contract.t()} | {:error, term()}
  def ingest_with_hash(extraction, opts \\ []) do
    product_group = Keyword.get(opts, :product_group, :ammonia_domestic)

    with {:extract, {:ok, clauses}} <- {:extract, build_clauses(extraction, product_group)} do
      register_new_clauses(extraction)

      file_hash = get_string(extraction, "file_hash")
      file_size = get_number(extraction, "file_size")

      contract = build_contract(
        extraction, clauses, nil, file_hash, file_size, opts
      )

      case Store.ingest(contract) do
        {:ok, stored} ->
          CurrencyTracker.stamp(stored.id, :parsed_at)

          broadcast(:copilot_ingestion_complete, %{
            contract_id: stored.id,
            contract_number: stored.contract_number,
            counterparty: stored.counterparty,
            copilot_clauses: length(clauses)
          })

          {:ok, stored}

        {:error, reason} ->
          {:error, {:store_failed, reason}}
      end
    else
      {:extract, {:error, reason}} -> {:error, {:extraction_failed, reason}}
    end
  end

  # ──────────────────────────────────────────────────────────
  # BATCH INGESTION — multiple contracts from Copilot
  # ──────────────────────────────────────────────────────────

  @doc """
  Ingest multiple contracts from a batch Copilot extraction.

  `batch` is a list of {file_path, extraction_map} tuples.
  Returns a summary of results.
  """
  @spec ingest_batch([{String.t(), map()}], keyword()) :: {:ok, map()}
  def ingest_batch(batch, opts \\ []) do
    results =
      Enum.map(batch, fn {file_path, extraction} ->
        result = ingest(file_path, extraction, opts)
        {file_path, result}
      end)

    succeeded = Enum.count(results, fn {_, r} -> match?({:ok, _}, r) end)
    failed = Enum.count(results, fn {_, r} -> not match?({:ok, _}, r) end)

    {:ok, %{
      total: length(batch),
      succeeded: succeeded,
      failed: failed,
      details: results,
      ingested_at: DateTime.utc_now()
    }}
  end

  # ──────────────────────────────────────────────────────────
  # CLAUSE BUILDING — convert Copilot JSON to %Clause{} structs
  # ──────────────────────────────────────────────────────────

  defp build_clauses(%{"clauses" => clauses}, product_group) when is_list(clauses) do
    now = DateTime.utc_now()
    term_map = ProductGroup.contract_term_map(product_group)

    built =
      Enum.map(clauses, fn clause_data ->
        %Clause{
          id: Clause.generate_id(),
          clause_id: get_string(clause_data, "clause_id"),
          type: map_clause_type(clause_data),
          category: safe_atom(get_string(clause_data, "category")),
          description: get_string(clause_data, "source_text") || "",
          reference_section: get_string(clause_data, "section_ref"),
          confidence: safe_atom(get_string(clause_data, "confidence") || "high"),
          anchors_matched: get_list(clause_data, "anchors_matched") || [],
          extracted_fields: get_map(clause_data, "extracted_fields") || %{},
          extracted_at: now,
          # Map LP-relevant fields using product group's term map
          parameter: map_lp_parameter(clause_data, term_map),
          operator: map_operator(clause_data),
          value: get_number(clause_data, "value") || get_nested_number(clause_data, "extracted_fields", "price_value"),
          unit: get_string(clause_data, "unit") || get_nested_string(clause_data, "extracted_fields", "price_uom"),
          penalty_per_unit: get_nested_number(clause_data, "extracted_fields", "demurrage_rate"),
          period: safe_atom(get_string(clause_data, "period"))
        }
      end)

    {:ok, built}
  end

  defp build_clauses(_, _product_group), do: {:error, :no_clauses_in_extraction}

  # ──────────────────────────────────────────────────────────
  # CONTRACT BUILDING
  # ──────────────────────────────────────────────────────────

  defp build_contract(extraction, clauses, file_path, file_hash, file_size, opts) do
    counterparty = get_string(extraction, "counterparty") || "Unknown"
    product_group = Keyword.get(opts, :product_group, :ammonia_domestic)

    %Contract{
      counterparty: counterparty,
      counterparty_type: safe_atom(get_string(extraction, "counterparty_type")) || :customer,
      product_group: product_group,
      template_type: safe_atom(get_string(extraction, "direction")),
      incoterm: safe_atom(String.downcase(get_string(extraction, "incoterm") || "")),
      term_type: safe_atom(get_string(extraction, "term_type")),
      company: safe_atom(get_string(extraction, "company")),
      source_file: if(file_path, do: Path.basename(file_path), else: get_string(extraction, "source_file")),
      source_format: if(file_path, do: detect_format(file_path), else: safe_atom(get_string(extraction, "source_format"))),
      clauses: clauses,
      contract_date: parse_date(get_string(extraction, "effective_date")),
      expiry_date: parse_date(get_string(extraction, "expiry_date")),
      sap_contract_id: Keyword.get(opts, :sap_contract_id) || get_string(extraction, "sap_contract_id"),
      # Copilot-provided metadata
      contract_number: get_string(extraction, "contract_number"),
      family_id: get_string(extraction, "family_id"),
      file_hash: file_hash,
      file_size: file_size,
      network_path: Keyword.get(opts, :network_path) || get_string(extraction, "network_path") || file_path,
      verification_status: :pending,
      previous_hash: get_previous_hash(counterparty, product_group)
    }
  end

  # ──────────────────────────────────────────────────────────
  # DYNAMIC CLAUSE REGISTRATION
  # ──────────────────────────────────────────────────────────

  defp register_new_clauses(%{"new_clause_definitions" => defs}) when is_list(defs) do
    Enum.each(defs, fn def_data ->
      clause_id = get_string(def_data, "clause_id")

      if clause_id && !TemplateRegistry.get_clause(clause_id) do
        definition = %{
          category: safe_atom(get_string(def_data, "category") || "unknown"),
          anchors: get_list(def_data, "anchors") || [],
          extract_fields: Enum.map(get_list(def_data, "extract_fields") || [], &safe_atom/1),
          lp_mapping: parse_lp_mapping(get_list(def_data, "lp_mapping")),
          level_default: safe_atom(get_string(def_data, "level_default") || "expected")
        }

        TemplateRegistry.register_clause(clause_id, definition)

        Logger.info("Registered new clause type from Copilot: #{clause_id}")
      end
    end)
  end

  defp register_new_clauses(_), do: :ok

  # ──────────────────────────────────────────────────────────
  # PARSER CROSS-CHECK
  # ──────────────────────────────────────────────────────────

  @doc """
  Run the deterministic parser on the same document and compare results
  against Copilot's extraction. Returns discrepancies.
  """
  def cross_check(contract_id) do
    with {:ok, contract} <- Store.get(contract_id),
         {:ok, path} <- resolve_path(contract),
         {:ok, text} <- AmmoniaDesk.Contracts.DocumentReader.read(path) do
      {parser_clauses, _warnings, _family} = Parser.parse(text)

      copilot_ids = contract.clauses |> Enum.map(& &1.clause_id) |> MapSet.new()
      parser_ids = parser_clauses |> Enum.map(& &1.clause_id) |> Enum.reject(&is_nil/1) |> MapSet.new()

      # Clauses Copilot found but parser missed (expected — Copilot is smarter)
      copilot_only = MapSet.difference(copilot_ids, parser_ids) |> MapSet.to_list()

      # Clauses parser found but Copilot missed (suspicious — investigate)
      parser_only = MapSet.difference(parser_ids, copilot_ids) |> MapSet.to_list()

      # Value discrepancies on shared clauses
      shared = MapSet.intersection(copilot_ids, parser_ids)
      value_diffs = compare_shared_values(contract.clauses, parser_clauses, shared)

      {:ok, %{
        contract_id: contract_id,
        copilot_clause_count: MapSet.size(copilot_ids),
        parser_clause_count: MapSet.size(parser_ids),
        copilot_only: copilot_only,
        parser_only: parser_only,
        value_discrepancies: value_diffs,
        agreement_pct: if(MapSet.size(copilot_ids) > 0,
          do: Float.round(MapSet.size(shared) / MapSet.size(copilot_ids) * 100, 1),
          else: 0.0
        )
      }}
    end
  end

  # ──────────────────────────────────────────────────────────
  # PRIVATE HELPERS
  # ──────────────────────────────────────────────────────────

  defp run_parser_cross_check(nil, _clauses), do: :no_file_path
  defp run_parser_cross_check(file_path, copilot_clauses) do
    case AmmoniaDesk.Contracts.DocumentReader.read(file_path) do
      {:ok, text} ->
        {parser_clauses, _warnings, _family} = Parser.parse(text)

        copilot_ids = copilot_clauses |> Enum.map(& &1.clause_id) |> MapSet.new()
        parser_ids = parser_clauses |> Enum.map(& &1.clause_id) |> Enum.reject(&is_nil/1) |> MapSet.new()
        shared = MapSet.intersection(copilot_ids, parser_ids)

        %{
          copilot_count: MapSet.size(copilot_ids),
          parser_count: MapSet.size(parser_ids),
          agreement: MapSet.size(shared),
          copilot_only: MapSet.size(MapSet.difference(copilot_ids, parser_ids)),
          parser_only: MapSet.size(MapSet.difference(parser_ids, copilot_ids))
        }

      {:error, _} ->
        :cross_check_failed
    end
  end

  defp cross_check_summary(:no_file_path), do: %{status: :skipped}
  defp cross_check_summary(:cross_check_failed), do: %{status: :failed}
  defp cross_check_summary(%{} = result) do
    Map.put(result, :status, :completed)
  end

  defp compare_shared_values(copilot_clauses, parser_clauses, shared_ids) do
    Enum.flat_map(shared_ids, fn clause_id ->
      cop = Enum.find(copilot_clauses, &(&1.clause_id == clause_id))
      par = Enum.find(parser_clauses, &(&1.clause_id == clause_id))

      cond do
        is_nil(cop) or is_nil(par) -> []
        cop.value != nil and par.value != nil and cop.value != par.value ->
          [%{clause_id: clause_id, copilot_value: cop.value, parser_value: par.value, field: :value}]
        true -> []
      end
    end)
  end

  defp map_clause_type(%{"category" => cat}) do
    case cat do
      "commercial" -> :price_term
      "core_terms" -> :obligation
      "logistics" -> :delivery
      "logistics_cost" -> :penalty
      "risk_events" -> :condition
      "credit_legal" -> :condition
      "legal" -> :legal
      "compliance" -> :compliance
      "operational" -> :operational
      "metadata" -> :metadata
      _ -> :condition
    end
  end
  defp map_clause_type(_), do: :condition

  # Use the product group's contract_term_map to resolve LP parameters
  defp map_lp_parameter(%{"clause_id" => clause_id}, term_map) when is_binary(clause_id) do
    Map.get(term_map, clause_id)
  end
  defp map_lp_parameter(_, _term_map), do: nil

  defp map_operator(%{"clause_id" => "PRICE"}), do: :==
  defp map_operator(%{"clause_id" => "QUANTITY_TOLERANCE"}), do: :>=
  defp map_operator(%{"clause_id" => "LAYTIME_DEMURRAGE"}), do: :>=
  defp map_operator(_), do: nil

  defp parse_lp_mapping(nil), do: nil
  defp parse_lp_mapping([]), do: nil
  defp parse_lp_mapping(list) when is_list(list) do
    Enum.map(list, &safe_atom/1)
  end

  # --- Data access helpers (handle string keys from JSON) ---

  defp get_string(map, key) when is_map(map) do
    case Map.get(map, key) || Map.get(map, String.to_atom(key)) do
      nil -> nil
      val when is_binary(val) -> val
      val -> to_string(val)
    end
  end
  defp get_string(_, _), do: nil

  defp get_number(map, key) when is_map(map) do
    case Map.get(map, key) || Map.get(map, String.to_atom(key)) do
      nil -> nil
      val when is_number(val) -> val
      val when is_binary(val) ->
        case Float.parse(val) do
          {n, _} -> n
          :error -> nil
        end
      _ -> nil
    end
  end
  defp get_number(_, _), do: nil

  defp get_nested_number(map, outer_key, inner_key) do
    case get_map(map, outer_key) do
      nil -> nil
      inner -> get_number(inner, inner_key)
    end
  end

  defp get_nested_string(map, outer_key, inner_key) do
    case get_map(map, outer_key) do
      nil -> nil
      inner -> get_string(inner, inner_key)
    end
  end

  defp get_map(map, key) when is_map(map) do
    case Map.get(map, key) || Map.get(map, String.to_atom(key)) do
      val when is_map(val) -> val
      _ -> nil
    end
  end
  defp get_map(_, _), do: nil

  defp get_list(map, key) when is_map(map) do
    case Map.get(map, key) || Map.get(map, String.to_atom(key)) do
      val when is_list(val) -> val
      _ -> nil
    end
  end
  defp get_list(_, _), do: nil

  defp safe_atom(nil), do: nil
  defp safe_atom(""), do: nil
  defp safe_atom(str) when is_binary(str) do
    str
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_]/, "_")
    |> String.to_atom()
  end
  defp safe_atom(atom) when is_atom(atom), do: atom

  defp parse_date(nil), do: nil
  defp parse_date(str) when is_binary(str) do
    case Date.from_iso8601(str) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp detect_format(path) do
    AmmoniaDesk.Contracts.DocumentReader.detect_format(path)
  end

  defp get_previous_hash(counterparty, product_group) do
    case Store.list_versions(counterparty, product_group) do
      [latest | _] -> latest.file_hash
      [] -> nil
    end
  end

  defp resolve_path(%Contract{network_path: nil}), do: {:error, :no_path}
  defp resolve_path(%Contract{network_path: ""}), do: {:error, :no_path}
  defp resolve_path(%Contract{network_path: p}), do: if(File.exists?(p), do: {:ok, p}, else: {:error, :not_found})

  defp broadcast(event, payload) do
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:contract_event, event, payload})
  end
end
