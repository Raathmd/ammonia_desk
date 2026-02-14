defmodule AmmoniaDesk.Contracts.Parser do
  @moduledoc """
  Deterministic, local-only contract clause extraction using Elixir pattern matching.

  No external API calls. No LLM. Every extracted value has a confidence score
  and a reference back to the original text.

  Extracts all 28 canonical clause types from the template inventory.
  Each clause is identified by its canonical clause_id and matched using
  the anchor patterns defined in TemplateRegistry.

  Extraction pipeline:
    1. Normalize text (whitespace, line breaks, encoding)
    2. Split into sections/paragraphs
    3. Run each paragraph through canonical clause matchers
    4. Extract structured fields per clause type
    5. Score confidence based on pattern match quality
    6. Deduplicate and resolve conflicts
    7. Auto-detect contract family from matched anchors
  """

  alias AmmoniaDesk.Contracts.{Clause, TemplateRegistry}

  require Logger

  # --- Number patterns ---
  @number_pattern ~r/[\$]?\s*([\d,_]+(?:\.\d+)?)/
  @dollar_pattern ~r/\$\s*([\d,_]+(?:\.\d+)?)/
  @percentage_pattern ~r/([\d]+(?:\.\d+)?)\s*%/

  # --- Unit patterns ---
  @unit_patterns %{
    "tons" => ~r/\b(tons?|mt|metric\s+tons?|tonnes?)\b/i,
    "$/ton" => ~r/\b(\$\s*\/\s*(?:ton|mt|tonne)|(?:dollars?|usd)\s+per\s+(?:ton|mt))\b/i,
    "mt/hr" => ~r/\b(mt\s*\/\s*h(?:ou)?r|metric\s+tons?\s+per\s+hour)\b/i,
    "days" => ~r/\b(days?|business\s+days?|calendar\s+days?)\b/i,
    "barges" => ~r/\b(barges?|vessels?)\b/i,
    "$" => ~r/\b(dollars?|usd|\$)\b/i,
    "$/day" => ~r/\b(\$\s*\/\s*day|(?:dollars?|usd)\s+per\s+day)\b/i,
    "$/MMBtu" => ~r/\b(\$\s*\/\s*mmbtu)\b/i
  }

  # --- Period patterns ---
  @period_patterns [
    {:monthly, ~r/\b(monthly|per\s+month|each\s+month|calendar\s+month)\b/i},
    {:quarterly, ~r/\b(quarterly|per\s+quarter|each\s+quarter)\b/i},
    {:annual, ~r/\b(annual(?:ly)?|per\s+(?:year|annum)|each\s+year|yearly)\b/i},
    {:spot, ~r/\b(spot|per\s+shipment|per\s+load|per\s+barge|per\s+vessel)\b/i}
  ]

  # ──────────────────────────────────────────────────────────
  # CANONICAL CLAUSE MATCHERS — ordered by specificity
  # Each returns the canonical clause_id on match
  # ──────────────────────────────────────────────────────────

  @clause_matchers [
    # Core terms — most specific first
    {"INCOTERMS",
     [~r/\bINCOTERMS\s+2020\b/i, ~r/\bINCOTERMS\b/i]},
    {"PRODUCT_AND_SPECS",
     [~r/\bProduct\s+Specifications?\b/i, ~r/\bSpecifications?\b.*\b(?:purity|water|oil|ammonia)\b/i]},
    {"QUANTITY_TOLERANCE",
     [~r/\bQuantity\b.*\b(?:\+\/-|more\s+or\s+less|tolerance)\b/i,
      ~r/\bshipping\s+tolerance\b/i,
      ~r/\bQuantity\b.*\b(?:metric\s+tons?|mt|tonnes?)\b/i]},
    {"ORIGIN",
     [~r/\b(?:Any\s+)?[Oo]rigin\b.*\b(?:right|obligation|alternate)\b/i,
      ~r/\bOrigin\b/i]},

    # Logistics
    {"PORTS_AND_SAFE_BERTH",
     [~r/\bPort\(?s?\)?\s+of\s+(?:Discharge|Loading)\b/i,
      ~r/\bOne\s+safe\s+(?:port|berth)\b/i,
      ~r/\bdraft\b.*\b(?:guarantee|feet|meters)\b/i]},
    {"DATES_WINDOWS_NOMINATIONS",
     [~r/\b(?:Loading|Arrival)\s+Dates?\b/i,
      ~r/\bShipments?\s*\/?\s*nominations?\b/i,
      ~r/\bNominations?\s+and\s+Notices?\b/i,
      ~r/\bduring\s+the\s+period\b/i]},

    # Commercial
    {"PRICE",
     [~r/\bPrice\b.*\bUS\s*\$\b/i,
      ~r/\bPrice\b.*\bper\s+(?:metric\s+)?ton\b/i,
      ~r/\bprice\s+will\s+be\s+agreed\b/i,
      ~r/\b(?:Fertecon|FMB)\b/i,
      ~r/\bPrice\b.*\$\s*[\d,]+/i]},
    {"PAYMENT",
     [~r/\bPayment\b.*\b(?:letter\s+of\s+credit|telegraphic\s+transfer)\b/i,
      ~r/\bPayment\b.*\b(?:days?\s+(?:from|after|of)\s+(?:B\/L|bill\s+of\s+lading|delivery))\b/i,
      ~r/\bstandby\s+letter\s+of\s+credit\b/i,
      ~r/\bPayment\b/i]},

    # Logistics cost
    {"LAYTIME_DEMURRAGE",
     [~r/\bLaytime\b/i,
      ~r/\bDemurrage\b.*\bper\s+day\b/i,
      ~r/\b(?:Discharge|Loading)\s+(?:Rate|Rates?)\s+and\s+Demurrage\b/i,
      ~r/\bConditions?\s+of\s+Loading\b/i,
      ~r/\bDemurrage\b.*\bpro\s+rata\b/i]},

    # Incorporation
    {"CHARTERPARTY_ASBATANKVOY_INCORP",
     [~r/\bASBATANKVOY\b/i,
      ~r/\bCharter\s+Party\b.*\bincorporated\b/i]},

    # Operational
    {"NOR_AND_READINESS",
     [~r/\bNotice\s+of\s+Readiness\b/i, ~r/\bNOR\b/]},
    {"PRESENTATION_COOLDOWN_GASSING",
     [~r/\b(?:cool\s*down|purging|gassing)\b.*\b(?:cargo\s+)?tanks?\b/i,
      ~r/\bPresentation\b.*\b(?:ammonia|cargo\s+tanks?)\b/i]},

    # Compliance
    {"VESSEL_ELIGIBILITY",
     [~r/\bVessel\s+Classification\b/i,
      ~r/\b(?:IACS|P&I|ISPS|MTSA|USCG)\b/]},

    # Determination
    {"INSPECTION_AND_QTY_DETERMINATION",
     [~r/\bInspection\b.*\b(?:independent\s+inspector|final\s+and\s+binding)\b/i,
      ~r/\bbill\s+of\s+lading\s+quantity\b/i,
      ~r/\bcertified\s+scale\s+weight\b/i,
      ~r/\bflow\s+meter\b/i,
      ~r/\bInspection\b/i]},

    # Documentation
    {"DOCUMENTS_AND_CERTIFICATES",
     [~r/\b(?:certificate\s+of\s+origin|EUR\s*1|Form\s+A|T2L)\b/i,
      ~r/\bDocuments?\b.*\b(?:shipping|presented|required)\b/i]},
    {"LOI",
     [~r/\bLetter\s+of\s+Indemnity\b/i,
      ~r/\bLOI\b/,
      ~r/\bwithout\s+presentation\s+of\s+an?\s+original\s+Bill\s+of\s+Lading\b/i]},

    # Risk
    {"INSURANCE",
     [~r/\b(?:cargo\s+)?[Ii]nsurance\b.*\b(?:all\s+risk|cover|war\s+strike)\b/i,
      ~r/\bcontract\s+price\s+plus\s+ten\s+percent\b/i,
      ~r/\bInsurance\b/i]},
    {"TAXES_FEES_DUES",
     [~r/\b(?:Taxes|Fees|Dues)\b.*\b(?:VAT|added|deducted)\b/i,
      ~r/\badded\s+to\s+the\s+sale\s+price\b/i,
      ~r/\bdeducted\s+from\s+the\s+purchase\s+price\b/i]},
    {"EXPORT_IMPORT_REACH",
     [~r/\bCompliance\s+with\s+(?:Export|Import)\b/i,
      ~r/\bREACH\b/,
      ~r/\bSafety\s+Data\s+Sheet\b/i]},
    {"WAR_RISK_AND_ROUTE_CLOSURE",
     [~r/\bWar\s+Risk\b/i,
      ~r/\bJoint\s+War\s+Committee\b/i,
      ~r/\bMain\s+Shipping\s+Routes?\s+Closure\b/i]},

    # Risk events
    {"FORCE_MAJEURE",
     [~r/\bForce\s+Majeure\b/i]},

    # Credit/legal
    {"DEFAULT_AND_REMEDIES",
     [~r/\b[Ee]vent\s+of\s+[Dd]efault\b/i,
      ~r/\bDefault\b.*\b(?:terminate|cancel|remedies?)\b/i,
      ~r/\bsetoff\b.*\bnetting\b/i]},
    {"WARRANTY_DISCLAIMER",
     [~r/\b(?:Exclusion|Disclaimer)\s+of\s+Warranties\b/i,
      ~r/\bMAKES?\s+NO\s+WARRANTY\b/i]},
    {"CLAIMS_NOTICE_AND_LIMITS",
     [~r/\bClaims?\b.*\b(?:15\s+days?|one\s+year|90\s+calendar\s+days?|absolutely\s+barred)\b/i,
      ~r/\bClaims?\b.*\b(?:notice|limitation|barred)\b/i]},
    {"GOVERNING_LAW_AND_ARBITRATION",
     [~r/\bArbitration\b/i,
      ~r/\bGoverning\s+Law\b/i,
      ~r/\bLMAA\b/,
      ~r/\bSMA\b/,
      ~r/\b(?:English|New\s+York)\s+law\b/i]},
    {"HARDSHIP_AND_REPRESENTATIONS",
     [~r/\bHardship\b/i,
      ~r/\bRepresentations?\s+and\s+Warranties\b/i]},

    # Admin
    {"NOTICES",
     [~r/\bNotices?\b.*\b(?:deemed|courier|fax|e-?mail)\b/i]},
    {"MISCELLANEOUS_BOILERPLATE",
     [~r/\b(?:Entire\s+Agreement|Miscellaneous)\b/i,
      ~r/\b(?:Waiver|Assignment|Severability)\b.*\b(?:Waiver|Assignment|Severability)\b/i]}
  ]

  # ──────────────────────────────────────────────────────────
  # PUBLIC API
  # ──────────────────────────────────────────────────────────

  @doc """
  Parse contract text into a list of extracted clauses.

  Returns {clauses, warnings, detected_family} where:
    - clauses: list of %Clause{} with canonical clause_ids
    - warnings: list of unparseable paragraphs
    - detected_family: {:ok, family_id, family} | :unknown
  """
  @spec parse(String.t()) :: {[Clause.t()], [String.t()], term()}
  def parse(text) when is_binary(text) do
    now = DateTime.utc_now()

    paragraphs =
      text
      |> normalize_text()
      |> split_into_sections()

    {clauses, warnings} =
      paragraphs
      |> Enum.reduce({[], []}, fn {section_ref, para}, {clauses_acc, warn_acc} ->
        case match_canonical_clause(para, section_ref) do
          {:ok, clause} ->
            clause = %{clause | id: Clause.generate_id(), extracted_at: now}
            {[clause | clauses_acc], warn_acc}

          :skip ->
            {clauses_acc, warn_acc}

          {:warn, reason} ->
            {clauses_acc, ["[#{section_ref}] #{reason}: #{String.slice(para, 0, 120)}" | warn_acc]}
        end
      end)

    clauses = Enum.reverse(clauses) |> deduplicate()
    warnings = Enum.reverse(warnings)
    detected_family = TemplateRegistry.detect_family(text)

    {clauses, warnings, detected_family}
  end

  @doc """
  Parse and return just clauses + warnings (backward compatible).
  """
  @spec parse_clauses(String.t()) :: {[Clause.t()], [String.t()]}
  def parse_clauses(text) do
    {clauses, warnings, _family} = parse(text)
    {clauses, warnings}
  end

  @doc """
  Get a summary of which canonical clause IDs were extracted.
  """
  @spec extraction_coverage(String.t()) :: %{String.t() => boolean()}
  def extraction_coverage(text) do
    {clauses, _, _} = parse(text)
    found_ids = clauses |> Enum.map(& &1.clause_id) |> Enum.reject(&is_nil/1) |> MapSet.new()

    TemplateRegistry.clause_ids()
    |> Enum.into(%{}, fn id -> {id, MapSet.member?(found_ids, id)} end)
  end

  # ──────────────────────────────────────────────────────────
  # TEXT NORMALIZATION
  # ──────────────────────────────────────────────────────────

  defp normalize_text(text) do
    text
    |> String.replace(~r/\r\n/, "\n")
    |> String.replace(~r/["""]/, "\"")
    |> String.replace(~r/[''']/, "'")
    |> String.replace(~r/\t/, " ")
    |> String.replace(~r/[ ]{2,}/, " ")
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
  end

  # ──────────────────────────────────────────────────────────
  # SECTION SPLITTING
  # ──────────────────────────────────────────────────────────
  #
  # Real contracts (especially from DOCX/DOCM) have section headings
  # on separate lines from their body text. For example:
  #
  #   "5. PRICE"              ← heading paragraph
  #   ""                      ← blank line
  #   "Purchase Price: US $340.00 per metric ton FOB..."  ← body
  #
  # The old approach split on double newlines and matched each paragraph
  # independently. This failed because the heading ("5. PRICE") matched
  # the PRICE clause but didn't contain the actual price value.
  #
  # New approach: After splitting into raw paragraphs, merge section
  # headings with their following body paragraph(s) into unified sections.
  # The parser then matches against the full section text, getting both
  # the heading anchors AND the body content with extractable values.

  defp split_into_sections(text) do
    raw_paragraphs =
      text
      |> String.split(~r/\n{2,}/)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    raw_paragraphs
    |> merge_heading_with_body()
    |> Enum.with_index(1)
    |> Enum.map(fn {para, idx} ->
      section_ref = detect_section_ref(para, idx)
      {section_ref, para}
    end)
    |> Enum.reject(fn {_, para} -> String.length(para) < 10 end)
  end

  # A heading is a short paragraph that starts with a section number
  # (e.g., "5. PRICE", "12. TAXES, FEES AND DUES") or is mostly uppercase.
  # When we detect one, we merge it with the next paragraph(s) until we
  # hit another heading or end of input.

  @heading_pattern ~r/^(?:\d+[\.\)]\s+[A-Z]|(?:Section|Article|Clause)\s+\d)/

  defp merge_heading_with_body([]), do: []

  defp merge_heading_with_body([first | rest]) do
    if is_section_heading?(first) do
      # Collect body paragraphs until next heading
      {body_paras, remaining} = collect_body(rest, [])
      merged = Enum.join([first | body_paras], "\n")
      [merged | merge_heading_with_body(remaining)]
    else
      [first | merge_heading_with_body(rest)]
    end
  end

  defp is_section_heading?(para) do
    # A heading: starts with "N. SOMETHING" and is relatively short (under 120 chars),
    # OR starts with Section/Article/Clause + number
    short_enough = String.length(para) < 120
    numbered = Regex.match?(@heading_pattern, para)

    # Also catch standalone uppercase labels like "BETWEEN:" or "PRODUCT AND SPECIFICATIONS"
    mostly_upper =
      short_enough and
        String.length(para) > 3 and
        para == String.upcase(para)

    (numbered and short_enough) or mostly_upper
  end

  defp collect_body([], acc), do: {Enum.reverse(acc), []}

  defp collect_body([next | rest] = all, acc) do
    if is_section_heading?(next) do
      # Next heading starts — stop collecting
      {Enum.reverse(acc), all}
    else
      collect_body(rest, [next | acc])
    end
  end

  defp detect_section_ref(para, fallback_idx) do
    cond do
      match = Regex.run(~r/^(?:Section|Article|Clause|Para(?:graph)?)\s+([\d\.]+)/i, para) ->
        "Section #{Enum.at(match, 1)}"
      match = Regex.run(~r/^([\d]+\.[\d\.]*)\s+/, para) ->
        "Section #{Enum.at(match, 1)}"
      match = Regex.run(~r/^\(([a-z]+|[ivxlc]+)\)/, para) ->
        "Clause (#{Enum.at(match, 1)})"
      true ->
        "Para #{fallback_idx}"
    end
  end

  # ──────────────────────────────────────────────────────────
  # CANONICAL CLAUSE MATCHING
  # ──────────────────────────────────────────────────────────

  defp match_canonical_clause(para, section_ref) do
    result =
      Enum.find_value(@clause_matchers, :skip, fn {clause_id, patterns} ->
        matched_anchors =
          Enum.filter(patterns, fn pattern ->
            Regex.match?(pattern, para)
          end)

        if length(matched_anchors) > 0 do
          extract_clause_fields(clause_id, para, section_ref, matched_anchors)
        else
          nil
        end
      end)

    result
  end

  # ──────────────────────────────────────────────────────────
  # PER-CLAUSE FIELD EXTRACTION
  # ──────────────────────────────────────────────────────────

  defp extract_clause_fields("INCOTERMS", para, section_ref, anchors) do
    lower = String.downcase(para)

    incoterm =
      cond do
        String.contains?(lower, "fob") -> "FOB"
        String.contains?(lower, "cfr") -> "CFR"
        String.contains?(lower, "cif") -> "CIF"
        String.contains?(lower, "dap") -> "DAP"
        String.contains?(lower, "ddp") -> "DDP"
        String.contains?(lower, "cpt") -> "CPT"
        String.contains?(lower, "fca") -> "FCA"
        String.contains?(lower, "exw") -> "EXW"
        true -> nil
      end

    {:ok, %Clause{
      clause_id: "INCOTERMS",
      type: :metadata,
      category: :metadata,
      description: para,
      reference_section: section_ref,
      confidence: :high,
      anchors_matched: anchor_strings(anchors),
      extracted_fields: %{incoterm_rule: incoterm, incoterm_version: "2020"}
    }}
  end

  defp extract_clause_fields("PRODUCT_AND_SPECS", para, section_ref, anchors) do
    fields = %{
      product_name: extract_product_name(para),
      purity: extract_field_value(para, ~r/(?:purity|min(?:imum)?)\s*:?\s*([\d.]+)\s*%/i),
      water: extract_field_value(para, ~r/(?:water|moisture)\s*:?\s*(?:max(?:imum)?\s*)?:?\s*([\d.]+)\s*%/i),
      oil: extract_field_value(para, ~r/(?:oil)\s*:?\s*(?:max(?:imum)?\s*)?:?\s*([\d.]+)\s*(?:ppm|%)/i)
    }

    {:ok, %Clause{
      clause_id: "PRODUCT_AND_SPECS",
      type: :metadata,
      category: :core_terms,
      description: para,
      reference_section: section_ref,
      confidence: :high,
      anchors_matched: anchor_strings(anchors),
      extracted_fields: fields
    }}
  end

  defp extract_clause_fields("QUANTITY_TOLERANCE", para, section_ref, anchors) do
    lower = String.downcase(para)
    qty = extract_number(para)
    tolerance = extract_percentage(para)

    option_holder =
      cond do
        Regex.match?(~r/\bseller'?s?\s+option\b/i, para) -> :seller_option
        Regex.match?(~r/\bbuyer'?s?\s+option\b/i, para) -> :buyer_option
        Regex.match?(~r/\bvessel'?s?\s+option\b/i, para) -> :vessel_option
        true -> nil
      end

    param = detect_volume_parameter(lower)

    case qty do
      {:ok, value} ->
        {:ok, %Clause{
          clause_id: "QUANTITY_TOLERANCE",
          type: :obligation,
          category: :core_terms,
          description: para,
          parameter: param,
          operator: :>=,
          value: value,
          unit: detect_unit(para) || "tons",
          period: detect_period(lower),
          reference_section: section_ref,
          confidence: if(value > 0, do: :high, else: :low),
          anchors_matched: anchor_strings(anchors),
          extracted_fields: %{
            qty: value,
            uom: detect_unit(para) || "tons",
            tolerance_pct: elem_or_nil(tolerance),
            option_holder: option_holder
          }
        }}

      :none ->
        {:warn, "QUANTITY_TOLERANCE anchor matched but no quantity extracted"}
    end
  end

  defp extract_clause_fields("ORIGIN", para, section_ref, anchors) do
    fields = %{
      origin_text: para,
      alternate_origin_right: Regex.match?(~r/\bright\s+but\s+not\s+the\s+obligation\b/i, para)
    }

    {:ok, %Clause{
      clause_id: "ORIGIN",
      type: :metadata,
      category: :core_terms,
      description: para,
      reference_section: section_ref,
      confidence: :high,
      anchors_matched: anchor_strings(anchors),
      extracted_fields: fields
    }}
  end

  defp extract_clause_fields("PORTS_AND_SAFE_BERTH", para, section_ref, anchors) do
    fields = %{
      load_port: extract_named_value(para, ~r/(?:Port\(?s?\)?\s+of\s+Loading|loading\s+port)\s*:?\s*([^\n,;]+)/i),
      discharge_port: extract_named_value(para, ~r/(?:Port\(?s?\)?\s+of\s+Discharge|discharge\s+port)\s*:?\s*([^\n,;]+)/i),
      safe_port_safe_berth: Regex.match?(~r/\bone\s+safe\s+(?:port|berth)\b/i, para),
      draft_guarantee: extract_field_value(para, ~r/(?:draft|draught)\s*(?:of\s+)?(?:at\s+least\s+)?([\d.]+)\s*(?:feet|ft|meters?|m)\b/i)
    }

    {:ok, %Clause{
      clause_id: "PORTS_AND_SAFE_BERTH",
      type: :delivery,
      category: :logistics,
      description: para,
      reference_section: section_ref,
      confidence: :high,
      anchors_matched: anchor_strings(anchors),
      extracted_fields: fields
    }}
  end

  defp extract_clause_fields("DATES_WINDOWS_NOMINATIONS", para, section_ref, anchors) do
    lower = String.downcase(para)

    fields = %{
      loading_dates: extract_date_range(para),
      arrival_window: extract_date_range(para),
      nomination_timeline: extract_field_value(para, ~r/(\d+)\s*(?:days?|business\s+days?)\s*(?:prior|before|notice)/i)
    }

    delivery_days = extract_number(para)

    {:ok, %Clause{
      clause_id: "DATES_WINDOWS_NOMINATIONS",
      type: :delivery,
      category: :logistics,
      description: para,
      parameter: :delivery_window,
      operator: :<=,
      value: elem_or_nil(delivery_days),
      unit: "days",
      period: detect_period(lower),
      reference_section: section_ref,
      confidence: :medium,
      anchors_matched: anchor_strings(anchors),
      extracted_fields: fields
    }}
  end

  defp extract_clause_fields("PRICE", para, section_ref, anchors) do
    lower = String.downcase(para)
    price = extract_dollar_amount(para)
    param = detect_price_parameter(lower)

    pricing_mechanism =
      cond do
        Regex.match?(~r/\b(?:Fertecon|FMB)\b/i, para) -> :index_reference
        Regex.match?(~r/\bprice\s+will\s+be\s+agreed\b/i, para) -> :to_be_agreed
        Regex.match?(~r/\b(?:fixed|firm)\s+price\b/i, para) -> :fixed
        true -> :fixed
      end

    duty_formula = extract_named_value(para, ~r/(?:duty|import)\s+(?:adjustment|divisor|formula)\s*:?\s*([^\n;]+)/i)

    case price do
      {:ok, value} ->
        {:ok, %Clause{
          clause_id: "PRICE",
          type: :price_term,
          category: :commercial,
          description: para,
          parameter: param,
          operator: :==,
          value: value,
          unit: "$/ton",
          period: detect_period(lower),
          reference_section: section_ref,
          confidence: :high,
          anchors_matched: anchor_strings(anchors),
          extracted_fields: %{
            price_value: value,
            price_uom: "$/ton",
            pricing_mechanism: pricing_mechanism,
            duty_adjustment_formula: duty_formula
          }
        }}

      :none ->
        # Price clause found but maybe index-linked with no fixed value
        {:ok, %Clause{
          clause_id: "PRICE",
          type: :price_term,
          category: :commercial,
          description: para,
          parameter: param,
          reference_section: section_ref,
          confidence: if(pricing_mechanism == :to_be_agreed, do: :medium, else: :low),
          anchors_matched: anchor_strings(anchors),
          extracted_fields: %{
            price_value: nil,
            pricing_mechanism: pricing_mechanism,
            duty_adjustment_formula: duty_formula
          }
        }}
    end
  end

  defp extract_clause_fields("PAYMENT", para, section_ref, anchors) do
    payment_method =
      cond do
        Regex.match?(~r/\bletter\s+of\s+credit\b/i, para) -> :lc
        Regex.match?(~r/\btelegraphic\s+transfer\b/i, para) -> :tt
        Regex.match?(~r/\bwire\s+transfer\b/i, para) -> :tt
        true -> nil
      end

    days = extract_field_value(para, ~r/(\d+)\s*(?:calendar\s+)?days?\s*(?:from|after|of)/i)
    standby = Regex.match?(~r/\bstandby\s+letter\s+of\s+credit\b/i, para)

    {:ok, %Clause{
      clause_id: "PAYMENT",
      type: :price_term,
      category: :commercial,
      description: para,
      parameter: :working_cap,
      reference_section: section_ref,
      confidence: if(payment_method, do: :high, else: :medium),
      anchors_matched: anchor_strings(anchors),
      extracted_fields: %{
        payment_method: payment_method,
        days_from_bl_or_delivery: days,
        standby_lc_terms: standby
      }
    }}
  end

  defp extract_clause_fields("LAYTIME_DEMURRAGE", para, section_ref, anchors) do
    lower = String.downcase(para)

    demurrage_rate = extract_dollar_amount(para)
    discharge_rate = extract_field_value(para, ~r/([\d,]+(?:\.\d+)?)\s*(?:mt|metric\s+tons?)\s*\/?\s*(?:per\s+)?(?:hour|hr)/i)
    claim_days = extract_field_value(para, ~r/(\d+)\s*(?:calendar\s+)?days?\s*(?:from|after|to\s+claim)/i)
    charterparty_alt = Regex.match?(~r/\bcharter\s*party\b/i, para)

    case demurrage_rate do
      {:ok, rate} ->
        {:ok, %Clause{
          clause_id: "LAYTIME_DEMURRAGE",
          type: :penalty,
          category: :logistics_cost,
          description: para,
          parameter: :demurrage,
          operator: :>=,
          value: 0,
          unit: "$/day",
          penalty_per_unit: rate,
          penalty_cap: extract_penalty_cap(para),
          reference_section: section_ref,
          confidence: :high,
          anchors_matched: anchor_strings(anchors),
          extracted_fields: %{
            demurrage_rate: rate,
            rate_mt_per_hr: discharge_rate,
            claim_deadline_days: claim_days,
            charterparty_alt: charterparty_alt,
            allowed_laytime_formula: detect_laytime_formula(lower)
          }
        }}

      :none ->
        {:ok, %Clause{
          clause_id: "LAYTIME_DEMURRAGE",
          type: :penalty,
          category: :logistics_cost,
          description: para,
          parameter: :demurrage,
          reference_section: section_ref,
          confidence: :low,
          anchors_matched: anchor_strings(anchors),
          extracted_fields: %{
            rate_mt_per_hr: discharge_rate,
            claim_deadline_days: claim_days,
            charterparty_alt: charterparty_alt,
            allowed_laytime_formula: detect_laytime_formula(lower)
          }
        }}
    end
  end

  defp extract_clause_fields("CHARTERPARTY_ASBATANKVOY_INCORP", para, section_ref, anchors) do
    form =
      cond do
        Regex.match?(~r/\bASBATANKVOY\b/i, para) -> "ASBATANKVOY"
        Regex.match?(~r/\bGencon\b/i, para) -> "GENCON"
        true -> nil
      end

    role_mapping = Regex.match?(~r/\b(?:owner|charterer)\b/i, para)

    {:ok, %Clause{
      clause_id: "CHARTERPARTY_ASBATANKVOY_INCORP",
      type: :legal,
      category: :incorporation,
      description: para,
      reference_section: section_ref,
      confidence: if(form, do: :high, else: :medium),
      anchors_matched: anchor_strings(anchors),
      extracted_fields: %{charterparty_form: form, role_mapping_owner_charterer: role_mapping}
    }}
  end

  defp extract_clause_fields("NOR_AND_READINESS", para, section_ref, anchors) do
    earliest = extract_field_value(para, ~r/(?:earliest|no\s+earlier\s+than)\s*:?\s*(\d{1,2}:\d{2})/i)
    commencement = extract_named_value(para, ~r/laytime\s+(?:shall\s+)?commence\s*([^\n;.]+)/i)

    {:ok, %Clause{
      clause_id: "NOR_AND_READINESS",
      type: :operational,
      category: :operational,
      description: para,
      reference_section: section_ref,
      confidence: :high,
      anchors_matched: anchor_strings(anchors),
      extracted_fields: %{
        earliest_nor_time: earliest,
        laytime_commencement_rule: commencement
      }
    }}
  end

  defp extract_clause_fields("PRESENTATION_COOLDOWN_GASSING", para, section_ref, anchors) do
    who_pays =
      cond do
        Regex.match?(~r/\bseller'?s?\s+(?:account|cost|expense)\b/i, para) -> :seller
        Regex.match?(~r/\bbuyer'?s?\s+(?:account|cost|expense)\b/i, para) -> :buyer
        true -> nil
      end

    time_counts = Regex.match?(~r/\btime\s+(?:shall\s+)?(?:count|not\s+count)\b/i, para)

    {:ok, %Clause{
      clause_id: "PRESENTATION_COOLDOWN_GASSING",
      type: :operational,
      category: :operational,
      description: para,
      reference_section: section_ref,
      confidence: :high,
      anchors_matched: anchor_strings(anchors),
      extracted_fields: %{
        who_pays_ammonia_used: who_pays,
        time_counts_or_excluded: time_counts
      }
    }}
  end

  defp extract_clause_fields("VESSEL_ELIGIBILITY", para, section_ref, anchors) do
    flags = %{
      iacs: Regex.match?(~r/\bIACS\b/, para),
      pandi: Regex.match?(~r/\bP&I\b/, para),
      isps: Regex.match?(~r/\bISPS\b/, para),
      mtsa: Regex.match?(~r/\bMTSA\b/, para),
      uscg: Regex.match?(~r/\bUSCG\b/, para)
    }

    {:ok, %Clause{
      clause_id: "VESSEL_ELIGIBILITY",
      type: :compliance,
      category: :compliance,
      description: para,
      reference_section: section_ref,
      confidence: :high,
      anchors_matched: anchor_strings(anchors),
      extracted_fields: %{class_requirements: flags}
    }}
  end

  defp extract_clause_fields("INSPECTION_AND_QTY_DETERMINATION", para, section_ref, anchors) do
    inspector =
      cond do
        Regex.match?(~r/\bseller\b.*\bappoint\b/i, para) -> :seller_appoints
        Regex.match?(~r/\bbuyer\b.*\bappoint\b/i, para) -> :buyer_appoints
        Regex.match?(~r/\bjointly\s+appoint\b/i, para) -> :joint
        Regex.match?(~r/\bindependent\s+inspector\b/i, para) -> :independent
        true -> nil
      end

    qty_basis =
      cond do
        Regex.match?(~r/\bbill\s+of\s+lading\s+quantity\b/i, para) -> :bl_quantity
        Regex.match?(~r/\bcertified\s+scale\b/i, para) -> :scale_weight
        Regex.match?(~r/\bflow\s+meter\b/i, para) -> :flow_meter
        true -> nil
      end

    {:ok, %Clause{
      clause_id: "INSPECTION_AND_QTY_DETERMINATION",
      type: :condition,
      category: :determination,
      description: para,
      reference_section: section_ref,
      confidence: :high,
      anchors_matched: anchor_strings(anchors),
      extracted_fields: %{
        inspector_appointer: inspector,
        qty_basis: qty_basis,
        final_and_binding: Regex.match?(~r/\bfinal\s+and\s+binding\b/i, para)
      }
    }}
  end

  defp extract_clause_fields("DOCUMENTS_AND_CERTIFICATES", para, section_ref, anchors) do
    docs = []
    docs = if Regex.match?(~r/\bcertificate\s+of\s+origin\b/i, para), do: [:certificate_of_origin | docs], else: docs
    docs = if Regex.match?(~r/\bEUR\s*1\b/i, para), do: [:eur1 | docs], else: docs
    docs = if Regex.match?(~r/\bForm\s+A\b/i, para), do: [:form_a | docs], else: docs
    docs = if Regex.match?(~r/\bT2L\b/i, para), do: [:t2l | docs], else: docs
    docs = if Regex.match?(~r/\bbill\s+of\s+lading\b/i, para), do: [:bill_of_lading | docs], else: docs
    docs = if Regex.match?(~r/\bcommercial\s+invoice\b/i, para), do: [:commercial_invoice | docs], else: docs

    {:ok, %Clause{
      clause_id: "DOCUMENTS_AND_CERTIFICATES",
      type: :condition,
      category: :documentation,
      description: para,
      reference_section: section_ref,
      confidence: if(length(docs) > 0, do: :high, else: :medium),
      anchors_matched: anchor_strings(anchors),
      extracted_fields: %{required_docs: Enum.reverse(docs)}
    }}
  end

  defp extract_clause_fields("INSURANCE", para, section_ref, anchors) do
    who =
      cond do
        Regex.match?(~r/\bseller\b.*\b(?:insure|insurance|arrange)\b/i, para) -> :seller
        Regex.match?(~r/\bbuyer\b.*\b(?:insure|insurance|arrange)\b/i, para) -> :buyer
        true -> nil
      end

    coverage = extract_field_value(para, ~r/(?:coverage|insured)\s+(?:for\s+)?(?:at\s+least\s+)?([\d.]+)\s*%/i)
    war_risk = Regex.match?(~r/\bwar\s+(?:strike\s+)?riot\b/i, para)

    {:ok, %Clause{
      clause_id: "INSURANCE",
      type: :condition,
      category: :risk_allocation,
      description: para,
      parameter: :insurance,
      reference_section: section_ref,
      confidence: :high,
      anchors_matched: anchor_strings(anchors),
      extracted_fields: %{who_insures: who, coverage_minimum: coverage, war_risk_addon: war_risk}
    }}
  end

  defp extract_clause_fields("LOI", para, section_ref, anchors) do
    bank_guarantee = Regex.match?(~r/\bbank\s+guarantee\b/i, para)

    {:ok, %Clause{
      clause_id: "LOI",
      type: :condition,
      category: :documentation,
      description: para,
      reference_section: section_ref,
      confidence: :high,
      anchors_matched: anchor_strings(anchors),
      extracted_fields: %{bank_guarantee_required: bank_guarantee}
    }}
  end

  defp extract_clause_fields("TAXES_FEES_DUES", para, section_ref, anchors) do
    add_to_sale = Regex.match?(~r/\badded\s+to\s+the\s+sale\s+price\b/i, para)
    deduct_from_purchase = Regex.match?(~r/\bdeducted\s+from\s+the\s+purchase\s+price\b/i, para)
    vat = Regex.match?(~r/\bVAT\b/, para)

    {:ok, %Clause{
      clause_id: "TAXES_FEES_DUES",
      type: :price_term,
      category: :commercial,
      description: para,
      parameter: :contract_price,
      reference_section: section_ref,
      confidence: :high,
      anchors_matched: anchor_strings(anchors),
      extracted_fields: %{
        add_to_price_rule: add_to_sale,
        deduct_from_price_rule: deduct_from_purchase,
        vat_applicable: vat
      }
    }}
  end

  defp extract_clause_fields("EXPORT_IMPORT_REACH", para, section_ref, anchors) do
    reach = Regex.match?(~r/\bREACH\b/, para)
    sds = Regex.match?(~r/\bSafety\s+Data\s+Sheet\b/i, para)

    {:ok, %Clause{
      clause_id: "EXPORT_IMPORT_REACH",
      type: :compliance,
      category: :compliance,
      description: para,
      reference_section: section_ref,
      confidence: :high,
      anchors_matched: anchor_strings(anchors),
      extracted_fields: %{reach_obligations: reach, safety_data_sheet: sds}
    }}
  end

  defp extract_clause_fields("WAR_RISK_AND_ROUTE_CLOSURE", para, section_ref, anchors) do
    jwc = Regex.match?(~r/\bJoint\s+War\s+Committee\b/i, para)
    route_closure = Regex.match?(~r/\bMain\s+Shipping\s+Routes?\s+Closure\b/i, para)

    {:ok, %Clause{
      clause_id: "WAR_RISK_AND_ROUTE_CLOSURE",
      type: :condition,
      category: :risk_costs,
      description: para,
      parameter: :freight_rate,
      reference_section: section_ref,
      confidence: :high,
      anchors_matched: anchor_strings(anchors),
      extracted_fields: %{
        joint_war_committee: jwc,
        route_closure_clause: route_closure
      }
    }}
  end

  defp extract_clause_fields("FORCE_MAJEURE", para, section_ref, anchors) do
    notice_days = extract_field_value(para, ~r/(\d+)\s*(?:business\s+|calendar\s+)?days?\s*(?:notice|notify)/i)
    demurrage_interaction = Regex.match?(~r/\bdemurrage\b/i, para)

    {:ok, %Clause{
      clause_id: "FORCE_MAJEURE",
      type: :condition,
      category: :risk_events,
      description: para,
      parameter: :force_majeure,
      reference_section: section_ref,
      confidence: :high,
      anchors_matched: anchor_strings(anchors),
      extracted_fields: %{
        notice_period: notice_days,
        demurrage_interaction: demurrage_interaction
      }
    }}
  end

  defp extract_clause_fields("DEFAULT_AND_REMEDIES", para, section_ref, anchors) do
    cure_hours = extract_field_value(para, ~r/(\d+)\s*hours?\s*/i)
    interest_rate = extract_field_value(para, ~r/([\d.]+)\s*%\s*(?:per\s+annum|interest)/i)
    setoff = Regex.match?(~r/\bsetoff\b|\bset-off\b|\bnetting\b/i, para)

    {:ok, %Clause{
      clause_id: "DEFAULT_AND_REMEDIES",
      type: :condition,
      category: :credit_legal,
      description: para,
      reference_section: section_ref,
      confidence: :high,
      anchors_matched: anchor_strings(anchors),
      extracted_fields: %{
        cure_period_hours: cure_hours,
        interest_rate: interest_rate,
        setoff_netting: setoff
      }
    }}
  end

  defp extract_clause_fields("WARRANTY_DISCLAIMER", para, section_ref, anchors) do
    {:ok, %Clause{
      clause_id: "WARRANTY_DISCLAIMER",
      type: :legal,
      category: :legal,
      description: para,
      reference_section: section_ref,
      confidence: :high,
      anchors_matched: anchor_strings(anchors),
      extracted_fields: %{disclaimer_text_present: true}
    }}
  end

  defp extract_clause_fields("CLAIMS_NOTICE_AND_LIMITS", para, section_ref, anchors) do
    notice_deadline = extract_field_value(para, ~r/(\d+)\s*(?:calendar\s+)?days?\s*/i)

    limitation =
      cond do
        Regex.match?(~r/\bone\s+year\b/i, para) -> "1 year"
        Regex.match?(~r/\btwo\s+years?\b/i, para) -> "2 years"
        match = Regex.run(~r/(\d+)\s*(?:months?|years?)/i, para) -> Enum.at(match, 0)
        true -> nil
      end

    {:ok, %Clause{
      clause_id: "CLAIMS_NOTICE_AND_LIMITS",
      type: :legal,
      category: :legal,
      description: para,
      reference_section: section_ref,
      confidence: :high,
      anchors_matched: anchor_strings(anchors),
      extracted_fields: %{
        notice_deadline: notice_deadline,
        limitation_period: limitation,
        absolutely_barred: Regex.match?(~r/\babsolutely\s+barred\b/i, para)
      }
    }}
  end

  defp extract_clause_fields("GOVERNING_LAW_AND_ARBITRATION", para, section_ref, anchors) do
    law =
      cond do
        Regex.match?(~r/\bEnglish\s+law\b/i, para) -> :english
        Regex.match?(~r/\bNew\s+York\b/i, para) -> :new_york
        Regex.match?(~r/\blaw\s+of\s+England\b/i, para) -> :english
        true -> nil
      end

    forum =
      cond do
        Regex.match?(~r/\bLMAA\b/, para) -> :lmaa
        Regex.match?(~r/\bSMA\b/, para) -> :sma
        Regex.match?(~r/\bICC\b/, para) -> :icc
        true -> nil
      end

    {:ok, %Clause{
      clause_id: "GOVERNING_LAW_AND_ARBITRATION",
      type: :legal,
      category: :legal,
      description: para,
      reference_section: section_ref,
      confidence: :high,
      anchors_matched: anchor_strings(anchors),
      extracted_fields: %{governing_law: law, forum: forum}
    }}
  end

  defp extract_clause_fields("HARDSHIP_AND_REPRESENTATIONS", para, section_ref, anchors) do
    {:ok, %Clause{
      clause_id: "HARDSHIP_AND_REPRESENTATIONS",
      type: :legal,
      category: :legal_long_term,
      description: para,
      reference_section: section_ref,
      confidence: :high,
      anchors_matched: anchor_strings(anchors),
      extracted_fields: %{
        hardship_present: Regex.match?(~r/\bHardship\b/i, para),
        reps_present: Regex.match?(~r/\bRepresentations?\b/i, para)
      }
    }}
  end

  defp extract_clause_fields("NOTICES", para, section_ref, anchors) do
    methods = []
    methods = if Regex.match?(~r/\bcourier\b/i, para), do: [:courier | methods], else: methods
    methods = if Regex.match?(~r/\bfax\b/i, para), do: [:fax | methods], else: methods
    methods = if Regex.match?(~r/\be-?mail\b/i, para), do: [:email | methods], else: methods

    {:ok, %Clause{
      clause_id: "NOTICES",
      type: :legal,
      category: :legal,
      description: para,
      reference_section: section_ref,
      confidence: :high,
      anchors_matched: anchor_strings(anchors),
      extracted_fields: %{notice_methods: Enum.reverse(methods)}
    }}
  end

  defp extract_clause_fields("MISCELLANEOUS_BOILERPLATE", para, section_ref, anchors) do
    {:ok, %Clause{
      clause_id: "MISCELLANEOUS_BOILERPLATE",
      type: :legal,
      category: :legal,
      description: para,
      reference_section: section_ref,
      confidence: :high,
      anchors_matched: anchor_strings(anchors),
      extracted_fields: %{boilerplate_present: true}
    }}
  end

  # Fallback for any unhandled clause_id
  defp extract_clause_fields(clause_id, para, section_ref, anchors) do
    {:ok, %Clause{
      clause_id: clause_id,
      type: :condition,
      description: para,
      reference_section: section_ref,
      confidence: :low,
      anchors_matched: anchor_strings(anchors),
      extracted_fields: %{}
    }}
  end

  # ──────────────────────────────────────────────────────────
  # NUMBER / FIELD EXTRACTION HELPERS
  # ──────────────────────────────────────────────────────────

  defp extract_number(text) do
    case Regex.run(@number_pattern, text) do
      [_, raw] ->
        cleaned = raw |> String.replace(~r/[,_]/, "")
        case Float.parse(cleaned) do
          {val, _} -> {:ok, val}
          :error -> :none
        end
      nil -> :none
    end
  end

  defp extract_dollar_amount(text) do
    case Regex.run(@dollar_pattern, text) do
      [_, raw] ->
        cleaned = raw |> String.replace(~r/[,_]/, "")
        case Float.parse(cleaned) do
          {val, _} -> {:ok, val}
          :error -> :none
        end
      nil ->
        case Regex.run(~r/([\d,]+(?:\.\d+)?)\s+(?:dollars?|usd)/i, text) do
          [_, raw] ->
            cleaned = raw |> String.replace(",", "")
            case Float.parse(cleaned) do
              {val, _} -> {:ok, val}
              :error -> :none
            end
          nil -> :none
        end
    end
  end

  defp extract_percentage(text) do
    case Regex.run(@percentage_pattern, text) do
      [_, raw] ->
        case Float.parse(raw) do
          {val, _} -> {:ok, val}
          :error -> :none
        end
      nil -> :none
    end
  end

  defp extract_field_value(text, pattern) do
    case Regex.run(pattern, text) do
      [_, captured] -> captured
      _ -> nil
    end
  end

  defp extract_named_value(text, pattern) do
    case Regex.run(pattern, text) do
      [_, captured] -> String.trim(captured)
      _ -> nil
    end
  end

  defp extract_product_name(text) do
    cond do
      Regex.match?(~r/\b[Aa]nhydrous\s+[Aa]mmonia\b/, text) -> "Anhydrous Ammonia"
      Regex.match?(~r/\bNH3\b/, text) -> "Anhydrous Ammonia (NH3)"
      Regex.match?(~r/\b[Aa]mmonia\b/, text) -> "Ammonia"
      true -> nil
    end
  end

  defp extract_date_range(text) do
    case Regex.run(~r/(\w+\s+\d{1,2})\s*(?:-|to|through)\s*(\w+\s+\d{1,2}(?:,?\s*\d{4})?)/i, text) do
      [_, from, to] -> "#{from} - #{to}"
      _ -> nil
    end
  end

  defp extract_penalty_cap(text) do
    lower = String.downcase(text)
    if String.contains?(lower, "cap") or String.contains?(lower, "maximum") or
         String.contains?(lower, "not to exceed") do
      case Regex.run(~r/(?:cap|maximum|not\s+to\s+exceed)[^\$]*\$\s*([\d,]+(?:\.\d+)?)/i, text) do
        [_, raw] ->
          cleaned = raw |> String.replace(",", "")
          case Float.parse(cleaned) do
            {val, _} -> val
            :error -> nil
          end
        nil -> nil
      end
    else
      nil
    end
  end

  defp detect_laytime_formula(lower) do
    cond do
      String.contains?(lower, "b/l") and String.contains?(lower, "rate") ->
        "BL_qty_div_rate"
      String.contains?(lower, "free hours") ->
        "free_hours_then_hourly"
      String.contains?(lower, "charter party") or String.contains?(lower, "charterparty") ->
        "charterparty_controls"
      true -> nil
    end
  end

  # ──────────────────────────────────────────────────────────
  # PARAMETER DETECTION (maps to LP solver variables)
  # ──────────────────────────────────────────────────────────

  defp detect_volume_parameter(lower) do
    cond do
      String.contains?(lower, "donaldsonville") or String.contains?(lower, "don ") -> :inv_don
      String.contains?(lower, "geismar") or String.contains?(lower, "geis") -> :inv_geis
      String.contains?(lower, "st. louis") or String.contains?(lower, "stl") -> :sell_stl
      String.contains?(lower, "memphis") or String.contains?(lower, "mem") -> :sell_mem
      true -> :total_volume
    end
  end

  defp detect_price_parameter(lower) do
    cond do
      String.contains?(lower, "buy") or String.contains?(lower, "purchase") -> :nola_buy
      String.contains?(lower, "st. louis") or String.contains?(lower, "stl") -> :sell_stl
      String.contains?(lower, "memphis") or String.contains?(lower, "mem") -> :sell_mem
      String.contains?(lower, "natural gas") or String.contains?(lower, "henry hub") -> :nat_gas
      String.contains?(lower, "sell") or String.contains?(lower, "sale") -> :contract_price
      true -> :contract_price
    end
  end

  defp detect_unit(text) do
    Enum.find_value(@unit_patterns, fn {unit_name, pattern} ->
      if Regex.match?(pattern, text), do: unit_name
    end)
  end

  defp detect_period(lower) do
    Enum.find_value(@period_patterns, fn {period, pattern} ->
      if Regex.match?(pattern, lower), do: period
    end)
  end

  defp anchor_strings(anchors) do
    Enum.map(anchors, fn
      %Regex{source: src} -> src
      other -> to_string(other)
    end)
  end

  defp elem_or_nil({:ok, val}), do: val
  defp elem_or_nil(_), do: nil

  # ──────────────────────────────────────────────────────────
  # DEDUPLICATION
  # ──────────────────────────────────────────────────────────

  defp deduplicate(clauses) do
    clauses
    |> Enum.group_by(fn c -> c.clause_id end)
    |> Enum.map(fn {_key, group} ->
      Enum.max_by(group, fn c ->
        {confidence_rank(c.confidence), if(c.value, do: 1, else: 0)}
      end)
    end)
    |> Enum.sort_by(& &1.reference_section)
  end

  defp confidence_rank(:high), do: 3
  defp confidence_rank(:medium), do: 2
  defp confidence_rank(:low), do: 1
  defp confidence_rank(_), do: 0
end
