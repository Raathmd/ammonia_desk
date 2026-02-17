defmodule TradingDesk.Contracts.TemplateRegistry do
  @moduledoc """
  Registry of canonical contract clauses and family signatures.

  Built from the actual Ammonia Commercial Contract Templates inventory
  (SharePoint: Legal Department / Ammonia Division). Every template in
  the system maps to a family signature, and every family lists the
  canonical clause IDs it expects.

  The 28 canonical clauses are the single source of truth. The parser
  must extract each clause by its anchor patterns. The validator checks
  extraction completeness against the family's expected clause list.

  Families:
    VESSEL_SPOT_PURCHASE     — FOB/CFR purchase contracts (vessel)
    VESSEL_SPOT_SALE         — FOB/CFR/CIF sale contracts (vessel)
    VESSEL_SPOT_DAP          — DAP/DDP sale contracts (vessel)
    DOMESTIC_CPT_TRUCKS      — CPT truck sale contracts
    DOMESTIC_MULTIMODAL_SALE — Barge/rail/truck sale contracts
    LONG_TERM_SALE_CFR       — Long-term CFR sale contracts
    LONG_TERM_PURCHASE_FOB   — Long-term FOB purchase contracts
  """

  # ──────────────────────────────────────────────────────────
  # CANONICAL CLAUSES — the 28 clause types from the inventory
  # ──────────────────────────────────────────────────────────

  @canonical_clauses %{
    "INCOTERMS" => %{
      category: :metadata,
      anchors: ["INCOTERMS 2020", "INCOTERMS"],
      extract_fields: [:incoterm_version, :incoterm_rule],
      lp_mapping: nil,
      level_default: :required
    },
    "PRODUCT_AND_SPECS" => %{
      category: :core_terms,
      anchors: ["Product", "Product Specifications", "Specifications"],
      extract_fields: [:product_name, :temp_requirement, :purity, :water, :oil],
      lp_mapping: nil,
      level_default: :required
    },
    "QUANTITY_TOLERANCE" => %{
      category: :core_terms,
      anchors: ["Quantity", "+/-", "more or less", "shipping tolerance"],
      extract_fields: [:qty, :uom, :tolerance_pct, :option_holder],
      lp_mapping: [:total_volume, :inv_don, :inv_geis, :sell_stl, :sell_mem],
      level_default: :required
    },
    "ORIGIN" => %{
      category: :core_terms,
      anchors: ["Origin", "Any origin", "right but not the obligation"],
      extract_fields: [:origin_text, :alternate_origin_right],
      lp_mapping: nil,
      level_default: :expected
    },
    "PORTS_AND_SAFE_BERTH" => %{
      category: :logistics,
      anchors: ["Port(s) of Discharge", "Port of discharge", "Port(s) of Loading",
                 "One safe port", "One safe berth", "draft"],
      extract_fields: [:load_port, :discharge_port, :safe_port_safe_berth, :draft_guarantee],
      lp_mapping: nil,
      level_default: :required
    },
    "DATES_WINDOWS_NOMINATIONS" => %{
      category: :logistics,
      anchors: ["Loading Dates", "Arrival Dates", "during the period",
                 "Shipments / nominations", "Nominations and Notices"],
      extract_fields: [:loading_dates, :arrival_window, :nomination_timeline],
      lp_mapping: [:delivery_window],
      level_default: :required
    },
    "PRICE" => %{
      category: :commercial,
      anchors: ["Price", "US $", "price will be agreed", "Fertecon", "FMB"],
      extract_fields: [:price_value, :price_uom, :pricing_mechanism, :duty_adjustment_formula],
      lp_mapping: [:nola_buy, :sell_stl, :sell_mem, :contract_price, :nat_gas],
      level_default: :required
    },
    "PAYMENT" => %{
      category: :commercial,
      anchors: ["Payment", "letter of credit", "telegraphic transfer",
                 "standby letter of credit"],
      extract_fields: [:payment_method, :days_from_bl_or_delivery, :docs_required,
                       :lc_terms, :standby_lc_terms],
      lp_mapping: [:working_cap],
      level_default: :required
    },
    "LAYTIME_DEMURRAGE" => %{
      category: :logistics_cost,
      anchors: ["Laytime", "Demurrage", "per day or pro rata",
                 "Discharge Rate and Demurrage", "Discharge and Demurrage Rates",
                 "Conditions of Loading"],
      extract_fields: [:rate_mt_per_hr, :allowed_laytime_formula, :demurrage_rate,
                       :charterparty_alt, :claim_deadline_days],
      lp_mapping: [:demurrage],
      level_default: :required
    },
    "CHARTERPARTY_ASBATANKVOY_INCORP" => %{
      category: :incorporation,
      anchors: ["ASBATANKVOY", "Charter Party", "incorporated by reference"],
      extract_fields: [:charterparty_form, :role_mapping_owner_charterer],
      lp_mapping: nil,
      level_default: :expected
    },
    "NOR_AND_READINESS" => %{
      category: :operational,
      anchors: ["Notice of Readiness", "NOR"],
      extract_fields: [:nor_rules, :earliest_nor_time, :laytime_commencement_rule],
      lp_mapping: nil,
      level_default: :expected
    },
    "PRESENTATION_COOLDOWN_GASSING" => %{
      category: :operational,
      anchors: ["Presentation", "cool down", "purging", "gassing", "cargo tanks"],
      extract_fields: [:tank_condition_required, :who_pays_ammonia_used,
                       :time_counts_or_excluded],
      lp_mapping: nil,
      level_default: :expected
    },
    "VESSEL_ELIGIBILITY" => %{
      category: :compliance,
      anchors: ["Vessel Classification and Eligibility", "IACS", "P&I",
                 "ISPS", "MTSA", "USCG"],
      extract_fields: [:class_requirements, :pandi_requirement,
                       :terminal_acceptance, :rejection_rights],
      lp_mapping: nil,
      level_default: :expected
    },
    "INSPECTION_AND_QTY_DETERMINATION" => %{
      category: :determination,
      anchors: ["Inspection", "independent inspector", "final and binding",
                 "bill of lading quantity", "certified scale weight", "flow meter"],
      extract_fields: [:inspector_appointer, :cost_split, :qty_basis, :quality_basis],
      lp_mapping: nil,
      level_default: :required
    },
    "DOCUMENTS_AND_CERTIFICATES" => %{
      category: :documentation,
      anchors: ["Documents", "certificate of origin", "EUR 1", "Form A",
                 "T2L", "shipping documents"],
      extract_fields: [:required_docs, :origin_cert_types, :where_delivered],
      lp_mapping: nil,
      level_default: :expected
    },
    "INSURANCE" => %{
      category: :risk_allocation,
      anchors: ["Insurance", "cargo insurance", "all risk",
                 "contract price plus ten percent", "war strike riot"],
      extract_fields: [:who_insures, :coverage_minimum, :war_risk_addon],
      lp_mapping: [:insurance],
      level_default: :expected
    },
    "LOI" => %{
      category: :documentation,
      anchors: ["Letter of Indemnity", "LOI",
                 "without presentation of an original Bill of Lading"],
      extract_fields: [:loi_allowed_cases, :bank_guarantee_required],
      lp_mapping: nil,
      level_default: :expected
    },
    "TAXES_FEES_DUES" => %{
      category: :commercial,
      anchors: ["Taxes", "Fees", "Dues", "VAT",
                 "added to the sale price", "deducted from the purchase price"],
      extract_fields: [:payer, :add_to_price_rule, :deduct_from_price_rule,
                       :import_duty_responsibility],
      lp_mapping: [:contract_price],
      level_default: :expected
    },
    "EXPORT_IMPORT_REACH" => %{
      category: :compliance,
      anchors: ["Compliance with Export and Import Laws", "REACH",
                 "Safety Data Sheet", "not prohibited"],
      extract_fields: [:import_permitted_warranty, :reach_obligations,
                       :who_handles_customs],
      lp_mapping: nil,
      level_default: :expected
    },
    "WAR_RISK_AND_ROUTE_CLOSURE" => %{
      category: :risk_costs,
      anchors: ["War Risk", "Joint War Committee", "Main Shipping Routes Closure"],
      extract_fields: [:war_risk_cost_rule, :route_closure_options],
      lp_mapping: [:freight_rate],
      level_default: :expected
    },
    "FORCE_MAJEURE" => %{
      category: :risk_events,
      anchors: ["Force Majeure", "notify", "cancel", "deliver later"],
      extract_fields: [:notice_period, :remedies, :demurrage_interaction],
      lp_mapping: [:force_majeure],
      level_default: :required
    },
    "DEFAULT_AND_REMEDIES" => %{
      category: :credit_legal,
      anchors: ["Default", "event of default", "48 hours", "terminate",
                 "cancel", "interest", "setoff", "net"],
      extract_fields: [:events_of_default, :remedies, :interest_rate, :setoff_netting],
      lp_mapping: nil,
      level_default: :required
    },
    "WARRANTY_DISCLAIMER" => %{
      category: :legal,
      anchors: ["Exclusion of Warranties", "Disclaimer of Warranties",
                 "MAKES NO WARRANTY"],
      extract_fields: [:disclaimer_text_present],
      lp_mapping: nil,
      level_default: :expected
    },
    "CLAIMS_NOTICE_AND_LIMITS" => %{
      category: :legal,
      anchors: ["Claims", "15 days", "one year", "90 calendar days",
                 "absolutely barred"],
      extract_fields: [:notice_deadline, :limitation_period, :caps_on_liability],
      lp_mapping: nil,
      level_default: :required
    },
    "GOVERNING_LAW_AND_ARBITRATION" => %{
      category: :legal,
      anchors: ["Arbitration", "Governing Law", "LMAA", "SMA",
                 "English law", "New York"],
      extract_fields: [:governing_law, :forum, :ruleset],
      lp_mapping: nil,
      level_default: :required
    },
    "NOTICES" => %{
      category: :legal,
      anchors: ["Notices", "deemed to be given", "courier", "fax", "e-mail"],
      extract_fields: [:notice_methods, :deemed_delivery_rules, :copy_recipients],
      lp_mapping: nil,
      level_default: :expected
    },
    "MISCELLANEOUS_BOILERPLATE" => %{
      category: :legal,
      anchors: ["Miscellaneous", "Entire Agreement", "Modifications",
                 "Waiver", "Assignment", "Severability", "Immunity"],
      extract_fields: [:boilerplate_present],
      lp_mapping: nil,
      level_default: :expected
    },
    "HARDSHIP_AND_REPRESENTATIONS" => %{
      category: :legal_long_term,
      anchors: ["Hardship", "Representations and Warranties"],
      extract_fields: [:hardship_present, :reps_present],
      lp_mapping: nil,
      level_default: :expected
    }
  }

  # ──────────────────────────────────────────────────────────
  # FAMILY SIGNATURES — 7 template families with detection anchors
  # ──────────────────────────────────────────────────────────

  @family_signatures %{
    "VESSEL_SPOT_PURCHASE" => %{
      detect_anchors: [
        "PURCHASE CONTRACT",
        "TRAMMO GENERAL TERMS AND CONDITIONS (FOB PURCHASE)",
        "TRAMMO GENERAL TERMS AND CONDITIONS (CFR PURCHASE)"
      ],
      direction: :purchase,
      term_type: :spot,
      transport: :vessel,
      default_incoterms: [:fob, :cfr],
      expected_clause_ids: [
        "INCOTERMS", "PRODUCT_AND_SPECS", "QUANTITY_TOLERANCE",
        "PORTS_AND_SAFE_BERTH", "DATES_WINDOWS_NOMINATIONS", "PRICE", "PAYMENT",
        "LAYTIME_DEMURRAGE", "CHARTERPARTY_ASBATANKVOY_INCORP",
        "NOR_AND_READINESS", "PRESENTATION_COOLDOWN_GASSING",
        "VESSEL_ELIGIBILITY", "INSPECTION_AND_QTY_DETERMINATION",
        "DOCUMENTS_AND_CERTIFICATES", "EXPORT_IMPORT_REACH",
        "WAR_RISK_AND_ROUTE_CLOSURE", "FORCE_MAJEURE",
        "DEFAULT_AND_REMEDIES", "CLAIMS_NOTICE_AND_LIMITS",
        "GOVERNING_LAW_AND_ARBITRATION", "NOTICES", "MISCELLANEOUS_BOILERPLATE"
      ]
    },
    "VESSEL_SPOT_SALE" => %{
      detect_anchors: [
        "SALE CONTRACT",
        "TRAMMO GENERAL TERMS AND CONDITIONS (FOB SALES)",
        "TRAMMO GENERAL TERMS AND CONDITIONS (CFR AND CIF SALES)"
      ],
      direction: :sale,
      term_type: :spot,
      transport: :vessel,
      default_incoterms: [:fob, :cfr, :cif],
      expected_clause_ids: [
        "INCOTERMS", "PRODUCT_AND_SPECS", "QUANTITY_TOLERANCE", "ORIGIN",
        "PORTS_AND_SAFE_BERTH", "PRICE", "PAYMENT", "LAYTIME_DEMURRAGE",
        "CHARTERPARTY_ASBATANKVOY_INCORP", "NOR_AND_READINESS",
        "PRESENTATION_COOLDOWN_GASSING", "VESSEL_ELIGIBILITY",
        "INSPECTION_AND_QTY_DETERMINATION", "INSURANCE", "LOI",
        "TAXES_FEES_DUES", "EXPORT_IMPORT_REACH",
        "WAR_RISK_AND_ROUTE_CLOSURE", "FORCE_MAJEURE",
        "DEFAULT_AND_REMEDIES", "WARRANTY_DISCLAIMER",
        "CLAIMS_NOTICE_AND_LIMITS", "GOVERNING_LAW_AND_ARBITRATION",
        "NOTICES", "MISCELLANEOUS_BOILERPLATE"
      ]
    },
    "VESSEL_SPOT_DAP" => %{
      detect_anchors: [
        "DAP Sale Contract",
        "TRAMMO GENERAL TERMS AND CONDITIONS (DAP SALES)",
        "TRAMMO GENERAL TERMS AND CONDITIONS (DAP/DDP SALES)"
      ],
      direction: :sale,
      term_type: :spot,
      transport: :vessel,
      default_incoterms: [:dap, :ddp],
      expected_clause_ids: [
        "INCOTERMS", "PRODUCT_AND_SPECS", "QUANTITY_TOLERANCE", "ORIGIN",
        "PORTS_AND_SAFE_BERTH", "PRICE", "PAYMENT", "LAYTIME_DEMURRAGE",
        "CHARTERPARTY_ASBATANKVOY_INCORP",
        "INSPECTION_AND_QTY_DETERMINATION", "LOI", "TAXES_FEES_DUES",
        "EXPORT_IMPORT_REACH", "WAR_RISK_AND_ROUTE_CLOSURE",
        "FORCE_MAJEURE", "DEFAULT_AND_REMEDIES", "WARRANTY_DISCLAIMER",
        "CLAIMS_NOTICE_AND_LIMITS", "GOVERNING_LAW_AND_ARBITRATION",
        "NOTICES", "MISCELLANEOUS_BOILERPLATE"
      ]
    },
    "DOMESTIC_CPT_TRUCKS" => %{
      detect_anchors: [
        "CPT SALE CONTRACT",
        "TRAMMO GENERAL TERMS AND CONDITIONS (CPT SALES)"
      ],
      direction: :sale,
      term_type: :spot,
      transport: :truck,
      default_incoterms: [:cpt],
      expected_clause_ids: [
        "INCOTERMS", "PRODUCT_AND_SPECS", "PRICE", "PAYMENT",
        "LAYTIME_DEMURRAGE", "INSPECTION_AND_QTY_DETERMINATION",
        "WARRANTY_DISCLAIMER", "CLAIMS_NOTICE_AND_LIMITS",
        "DEFAULT_AND_REMEDIES", "FORCE_MAJEURE", "TAXES_FEES_DUES",
        "NOTICES", "GOVERNING_LAW_AND_ARBITRATION",
        "MISCELLANEOUS_BOILERPLATE"
      ]
    },
    "DOMESTIC_MULTIMODAL_SALE" => %{
      detect_anchors: [
        "Sale Contract for Barge, Rail and Trucks",
        "TRAMMO GENERAL TERMS AND CONDITIONS (SALES)"
      ],
      direction: :sale,
      term_type: :spot,
      transport: :multimodal,
      default_incoterms: [:fob, :cpt, :dap],
      expected_clause_ids: [
        "INCOTERMS", "PRODUCT_AND_SPECS", "PRICE", "PAYMENT",
        "INSPECTION_AND_QTY_DETERMINATION", "LAYTIME_DEMURRAGE",
        "FORCE_MAJEURE", "DEFAULT_AND_REMEDIES", "WARRANTY_DISCLAIMER",
        "CLAIMS_NOTICE_AND_LIMITS", "GOVERNING_LAW_AND_ARBITRATION",
        "NOTICES", "MISCELLANEOUS_BOILERPLATE"
      ]
    },
    "LONG_TERM_SALE_CFR" => %{
      detect_anchors: [
        "ANHYDROUS AMMONIA SALES CONTRACT",
        "Shipments / nominations",
        "Fertecon", "FMB"
      ],
      direction: :sale,
      term_type: :long_term,
      transport: :vessel,
      default_incoterms: [:cfr],
      expected_clause_ids: [
        "INCOTERMS", "PRODUCT_AND_SPECS", "QUANTITY_TOLERANCE",
        "DATES_WINDOWS_NOMINATIONS", "PRICE", "PAYMENT",
        "LAYTIME_DEMURRAGE", "CHARTERPARTY_ASBATANKVOY_INCORP",
        "LOI", "TAXES_FEES_DUES", "EXPORT_IMPORT_REACH",
        "WAR_RISK_AND_ROUTE_CLOSURE", "FORCE_MAJEURE",
        "DEFAULT_AND_REMEDIES", "WARRANTY_DISCLAIMER",
        "CLAIMS_NOTICE_AND_LIMITS", "GOVERNING_LAW_AND_ARBITRATION",
        "NOTICES", "MISCELLANEOUS_BOILERPLATE",
        "HARDSHIP_AND_REPRESENTATIONS"
      ]
    },
    "LONG_TERM_PURCHASE_FOB" => %{
      detect_anchors: [
        "ANHYDROUS AMMONIA FOB PURCHASE CONTRACT",
        "bill of lading date of the first cargo lifted"
      ],
      direction: :purchase,
      term_type: :long_term,
      transport: :vessel,
      default_incoterms: [:fob],
      expected_clause_ids: [
        "INCOTERMS", "PRODUCT_AND_SPECS", "QUANTITY_TOLERANCE",
        "DATES_WINDOWS_NOMINATIONS", "PRICE", "PAYMENT",
        "DOCUMENTS_AND_CERTIFICATES", "INSPECTION_AND_QTY_DETERMINATION",
        "PRESENTATION_COOLDOWN_GASSING",
        "CHARTERPARTY_ASBATANKVOY_INCORP", "LAYTIME_DEMURRAGE",
        "TAXES_FEES_DUES", "EXPORT_IMPORT_REACH",
        "WAR_RISK_AND_ROUTE_CLOSURE", "FORCE_MAJEURE",
        "DEFAULT_AND_REMEDIES", "GOVERNING_LAW_AND_ARBITRATION",
        "NOTICES", "MISCELLANEOUS_BOILERPLATE"
      ]
    }
  }

  # ──────────────────────────────────────────────────────────
  # COMPANY ENTITIES
  # ──────────────────────────────────────────────────────────

  @companies [:trammo_inc, :trammo_sas, :trammo_dmcc]

  @incoterms [:fob, :cif, :cfr, :dap, :ddp, :cpt, :fca, :exw]

  # ──────────────────────────────────────────────────────────
  # CLAUSE REQUIREMENT LEVELS PER FAMILY
  # Clauses in the family's expected list default to :required
  # for core/commercial/logistics, :expected for legal/compliance
  # ──────────────────────────────────────────────────────────

  @required_categories [:metadata, :core_terms, :commercial, :logistics,
                        :logistics_cost, :determination, :risk_events, :credit_legal]

  @expected_categories [:incorporation, :operational, :compliance, :documentation,
                        :risk_allocation, :risk_costs, :legal, :legal_long_term]

  # ──────────────────────────────────────────────────────────
  # DYNAMIC CLAUSE/FAMILY REGISTRATION
  # ──────────────────────────────────────────────────────────
  #
  # The 28 canonical clauses and 7 families are compile-time defaults.
  # Copilot (or any external source) can register additional clause
  # types and families at runtime via register_clause/2 and
  # register_family/2. Dynamic additions are stored in :persistent_term
  # and merged with the compiled defaults on lookup.
  #
  # This means the app does NOT need to know all clause types up front.
  # Copilot can discover new clause types in real contracts and register
  # them dynamically.

  @dynamic_clauses_key {__MODULE__, :dynamic_clauses}
  @dynamic_families_key {__MODULE__, :dynamic_families}

  @doc """
  Register a new clause type at runtime. Called by CopilotIngestion
  when Copilot discovers clause types not in the canonical inventory.

  `clause_id` — unique string ID (e.g., "SANCTIONS_COMPLIANCE")
  `definition` — map with :category, :anchors, :extract_fields, :lp_mapping, :level_default
  """
  def register_clause(clause_id, definition) when is_binary(clause_id) and is_map(definition) do
    current = dynamic_clauses()
    updated = Map.put(current, clause_id, definition)
    :persistent_term.put(@dynamic_clauses_key, updated)
    :ok
  end

  @doc """
  Register a new family signature at runtime.
  """
  def register_family(family_id, definition) when is_binary(family_id) and is_map(definition) do
    current = dynamic_families()
    updated = Map.put(current, family_id, definition)
    :persistent_term.put(@dynamic_families_key, updated)
    :ok
  end

  defp dynamic_clauses do
    try do
      :persistent_term.get(@dynamic_clauses_key)
    rescue
      ArgumentError -> %{}
    end
  end

  defp dynamic_families do
    try do
      :persistent_term.get(@dynamic_families_key)
    rescue
      ArgumentError -> %{}
    end
  end

  # ──────────────────────────────────────────────────────────
  # PUBLIC API
  # ──────────────────────────────────────────────────────────

  @doc "All clause definitions (compiled + dynamic)"
  def canonical_clauses, do: Map.merge(@canonical_clauses, dynamic_clauses())

  @doc "Get a clause definition by ID (checks compiled then dynamic)"
  def get_clause(clause_id) when is_binary(clause_id) do
    Map.get(@canonical_clauses, clause_id) || Map.get(dynamic_clauses(), clause_id)
  end

  @doc "All family signature definitions (compiled + dynamic)"
  def family_signatures, do: Map.merge(@family_signatures, dynamic_families())

  @doc "Get a family signature by ID (checks compiled then dynamic)"
  def get_family(family_id) when is_binary(family_id) do
    Map.get(@family_signatures, family_id) || Map.get(dynamic_families(), family_id)
  end

  @doc "All family IDs (compiled + dynamic)"
  def family_ids, do: Map.keys(family_signatures())

  @doc "All clause IDs (compiled + dynamic)"
  def clause_ids, do: Map.keys(canonical_clauses())

  @doc "All known Incoterms"
  def incoterms, do: @incoterms

  @doc "All company entities"
  def companies, do: @companies

  @doc "Human-readable company name"
  def company_label(:trammo_inc), do: "Trammo, Inc. — Ammonia Division"
  def company_label(:trammo_sas), do: "Trammo SAS"
  def company_label(:trammo_dmcc), do: "Trammo DMCC"
  def company_label(other), do: to_string(other)

  @doc """
  Detect which family a contract belongs to based on its text content.
  Returns {:ok, family_id, family} or :unknown.
  """
  def detect_family(text) when is_binary(text) do
    upper = String.upcase(text)
    all_families = family_signatures()

    scored =
      all_families
      |> Enum.map(fn {family_id, family} ->
        score =
          Enum.count(family.detect_anchors, fn anchor ->
            String.contains?(upper, String.upcase(anchor))
          end)

        {family_id, family, score}
      end)
      |> Enum.filter(fn {_, _, score} -> score > 0 end)
      |> Enum.sort_by(fn {_, _, score} -> score end, :desc)

    case scored do
      [{family_id, family, _} | _] -> {:ok, family_id, family}
      [] -> :unknown
    end
  end

  @doc """
  Get the clause requirements for a family — what must be extracted.

  Returns a list of:
    %{clause_id: "PRICE", level: :required, category: :commercial, ...}
  """
  def family_requirements(family_id) when is_binary(family_id) do
    case get_family(family_id) do
      nil ->
        []

      family ->
        Enum.map(family.expected_clause_ids, fn clause_id ->
          clause_def = get_clause(clause_id) || %{}
          category = Map.get(clause_def, :category, :unknown)

          level =
            if category in @required_categories,
              do: :required,
              else: :expected

          %{
            clause_id: clause_id,
            level: level,
            category: category,
            anchors: Map.get(clause_def, :anchors, []),
            extract_fields: Map.get(clause_def, :extract_fields, []),
            lp_mapping: Map.get(clause_def, :lp_mapping)
          }
        end)
    end
  end

  @doc """
  Get only the required clause IDs for a family.
  """
  def required_clause_ids(family_id) do
    family_requirements(family_id)
    |> Enum.filter(&(&1.level == :required))
    |> Enum.map(& &1.clause_id)
  end

  @doc """
  Get clause IDs that map to LP solver variables for a family.
  """
  def lp_relevant_clause_ids(family_id) do
    family_requirements(family_id)
    |> Enum.filter(&(not is_nil(&1.lp_mapping)))
    |> Enum.map(&{&1.clause_id, &1.lp_mapping})
  end

  @doc """
  Get all anchor patterns for a given clause ID.
  Used by the parser to detect clause boundaries.
  """
  def anchors_for(clause_id) when is_binary(clause_id) do
    case Map.get(@canonical_clauses, clause_id) do
      nil -> []
      clause -> clause.anchors
    end
  end

  @doc """
  Get the LP variable atoms that a canonical clause maps to.
  """
  def lp_variables_for(clause_id) when is_binary(clause_id) do
    case Map.get(@canonical_clauses, clause_id) do
      nil -> []
      %{lp_mapping: nil} -> []
      %{lp_mapping: vars} -> vars
    end
  end

  @doc """
  Map a parameter_class from old templates to solver variable atoms.
  Kept for backward compatibility with TemplateValidator and ConstraintBridge.
  """
  def parameter_class_members(:volume),
    do: [:inv_don, :inv_geis, :total_volume, :sell_stl, :sell_mem]
  def parameter_class_members(:buy_price),
    do: [:nola_buy, :contract_price]
  def parameter_class_members(:sell_price),
    do: [:sell_stl, :sell_mem, :contract_price]
  def parameter_class_members(:freight),
    do: [:fr_don_stl, :fr_don_mem, :fr_geis_stl, :fr_geis_mem, :freight_rate]
  def parameter_class_members(:delivery_window),
    do: [:delivery_window]
  def parameter_class_members(:force_majeure),
    do: [:force_majeure]
  def parameter_class_members(:volume_shortfall),
    do: [:volume_shortfall]
  def parameter_class_members(:late_delivery),
    do: [:late_delivery]
  def parameter_class_members(:demurrage),
    do: [:demurrage]
  def parameter_class_members(:inventory),
    do: [:inv_don, :inv_geis, :inventory]
  def parameter_class_members(:max_volume),
    do: [:inv_don, :inv_geis, :total_volume, :sell_stl, :sell_mem]
  def parameter_class_members(:working_capital),
    do: [:working_cap]
  def parameter_class_members(:barge_capacity),
    do: [:barge_count]
  def parameter_class_members(:insurance),
    do: [:insurance]
  def parameter_class_members(:pickup_terms),
    do: [:pickup_terms]
  def parameter_class_members(:import_duties),
    do: [:import_duties, :customs]
  def parameter_class_members(_), do: []

  @doc """
  Backward-compatible get_template/2 for TemplateValidator.
  Maps family_id or old contract_type+incoterm to a template struct.
  """
  def get_template(family_id) when is_binary(family_id) do
    case get_family(family_id) do
      nil ->
        {:error, :unknown_template}

      family ->
        reqs = family_requirements(family_id)

        clause_requirements =
          Enum.map(reqs, fn req ->
            %{
              clause_type: clause_id_to_type(req.clause_id),
              parameter_class: clause_id_to_param_class(req.clause_id),
              clause_id: req.clause_id,
              level: req.level,
              description: req.clause_id
            }
          end)

        {:ok, %{
          family_id: family_id,
          contract_type: family.direction,
          incoterm: List.first(family.default_incoterms),
          clause_requirements: clause_requirements,
          notes: "#{family_id}: #{family.direction} / #{family.term_type} / #{family.transport}"
        }}
    end
  end

  def get_template(contract_type, incoterm) do
    family_id = infer_family(contract_type, incoterm)
    get_template(family_id)
  end

  @doc "List all templates as summary maps (for UI display)."
  def list_templates do
    Enum.map(family_signatures(), fn {family_id, family} ->
      reqs = family_requirements(family_id)
      required = Enum.count(reqs, &(&1.level == :required))
      expected = Enum.count(reqs, &(&1.level == :expected))

      %{
        family_id: family_id,
        direction: family.direction,
        term_type: family.term_type,
        transport: family.transport,
        incoterms: family.default_incoterms,
        required_count: required,
        expected_count: expected,
        total_count: length(reqs),
        lp_clauses: length(Enum.filter(reqs, &(not is_nil(&1.lp_mapping))))
      }
    end)
  end

  # --- Private helpers ---

  defp infer_family(contract_type, incoterm) do
    case {contract_type, incoterm} do
      {:purchase, :fob} -> "VESSEL_SPOT_PURCHASE"
      {:purchase, :cfr} -> "VESSEL_SPOT_PURCHASE"
      {:spot_purchase, _} -> "VESSEL_SPOT_PURCHASE"
      {:sale, :fob} -> "VESSEL_SPOT_SALE"
      {:sale, :cfr} -> "VESSEL_SPOT_SALE"
      {:sale, :cif} -> "VESSEL_SPOT_SALE"
      {:spot_sale, :fob} -> "VESSEL_SPOT_SALE"
      {:spot_sale, :cfr} -> "VESSEL_SPOT_SALE"
      {:spot_sale, :cif} -> "VESSEL_SPOT_SALE"
      {:sale, :dap} -> "VESSEL_SPOT_DAP"
      {:sale, :ddp} -> "VESSEL_SPOT_DAP"
      {:spot_sale, :dap} -> "VESSEL_SPOT_DAP"
      {:spot_sale, :ddp} -> "VESSEL_SPOT_DAP"
      {:sale, :cpt} -> "DOMESTIC_CPT_TRUCKS"
      {:spot_sale, :cpt} -> "DOMESTIC_CPT_TRUCKS"
      {:long_term_sale, _} -> "LONG_TERM_SALE_CFR"
      {:long_term_purchase, _} -> "LONG_TERM_PURCHASE_FOB"
      _ -> "VESSEL_SPOT_PURCHASE"
    end
  end

  defp clause_id_to_type("QUANTITY_TOLERANCE"), do: :obligation
  defp clause_id_to_type("PRICE"), do: :price_term
  defp clause_id_to_type("LAYTIME_DEMURRAGE"), do: :penalty
  defp clause_id_to_type("FORCE_MAJEURE"), do: :condition
  defp clause_id_to_type("DEFAULT_AND_REMEDIES"), do: :condition
  defp clause_id_to_type("DATES_WINDOWS_NOMINATIONS"), do: :delivery
  defp clause_id_to_type("PAYMENT"), do: :price_term
  defp clause_id_to_type("INSURANCE"), do: :condition
  defp clause_id_to_type("WAR_RISK_AND_ROUTE_CLOSURE"), do: :condition
  defp clause_id_to_type("TAXES_FEES_DUES"), do: :price_term
  defp clause_id_to_type(_), do: :condition

  defp clause_id_to_param_class("QUANTITY_TOLERANCE"), do: :volume
  defp clause_id_to_param_class("PRICE"), do: :buy_price
  defp clause_id_to_param_class("LAYTIME_DEMURRAGE"), do: :demurrage
  defp clause_id_to_param_class("FORCE_MAJEURE"), do: :force_majeure
  defp clause_id_to_param_class("DATES_WINDOWS_NOMINATIONS"), do: :delivery_window
  defp clause_id_to_param_class("PAYMENT"), do: :working_capital
  defp clause_id_to_param_class("INSURANCE"), do: :insurance
  defp clause_id_to_param_class("WAR_RISK_AND_ROUTE_CLOSURE"), do: :freight
  defp clause_id_to_param_class("TAXES_FEES_DUES"), do: :sell_price
  defp clause_id_to_param_class(_), do: nil
end
