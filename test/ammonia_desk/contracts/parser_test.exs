defmodule AmmoniaDesk.Contracts.ParserTest do
  use ExUnit.Case, async: true

  alias AmmoniaDesk.Contracts.{Parser, TemplateRegistry}

  @fixtures_dir Path.expand("../../fixtures/contracts", __DIR__)

  defp read_fixture(name) do
    Path.join(@fixtures_dir, name) |> File.read!()
  end

  # ──────────────────────────────────────────────────────────
  # FAMILY DETECTION
  # ──────────────────────────────────────────────────────────

  describe "family detection" do
    test "detects VESSEL_SPOT_PURCHASE from FOB purchase contract" do
      text = read_fixture("vessel_spot_purchase_fob.txt")
      {_clauses, _warnings, family} = Parser.parse(text)
      assert {:ok, "VESSEL_SPOT_PURCHASE", _} = family
    end

    test "detects VESSEL_SPOT_SALE from CFR sale contract" do
      text = read_fixture("vessel_spot_sale_cfr.txt")
      {_clauses, _warnings, family} = Parser.parse(text)
      assert {:ok, "VESSEL_SPOT_SALE", _} = family
    end

    test "detects VESSEL_SPOT_DAP from DAP sale contract" do
      text = read_fixture("vessel_spot_dap.txt")
      {_clauses, _warnings, family} = Parser.parse(text)
      assert {:ok, "VESSEL_SPOT_DAP", _} = family
    end

    test "detects DOMESTIC_CPT_TRUCKS from CPT contract" do
      text = read_fixture("domestic_cpt_trucks.txt")
      {_clauses, _warnings, family} = Parser.parse(text)
      assert {:ok, "DOMESTIC_CPT_TRUCKS", _} = family
    end

    test "detects DOMESTIC_MULTIMODAL_SALE from multimodal contract" do
      text = read_fixture("domestic_multimodal_sale.txt")
      {_clauses, _warnings, family} = Parser.parse(text)
      assert {:ok, "DOMESTIC_MULTIMODAL_SALE", _} = family
    end

    test "detects LONG_TERM_SALE_CFR from long-term sale" do
      text = read_fixture("long_term_sale_cfr.txt")
      {_clauses, _warnings, family} = Parser.parse(text)
      assert {:ok, "LONG_TERM_SALE_CFR", _} = family
    end

    test "detects LONG_TERM_PURCHASE_FOB from long-term purchase" do
      text = read_fixture("long_term_purchase_fob.txt")
      {_clauses, _warnings, family} = Parser.parse(text)
      assert {:ok, "LONG_TERM_PURCHASE_FOB", _} = family
    end
  end

  # ──────────────────────────────────────────────────────────
  # VESSEL SPOT PURCHASE — 22 expected clauses
  # ──────────────────────────────────────────────────────────

  describe "vessel spot purchase FOB" do
    setup do
      text = read_fixture("vessel_spot_purchase_fob.txt")
      {clauses, warnings, _family} = Parser.parse(text)
      %{clauses: clauses, warnings: warnings, text: text}
    end

    test "extracts INCOTERMS", %{clauses: clauses} do
      c = find_clause(clauses, "INCOTERMS")
      assert c != nil
      assert c.extracted_fields.incoterm_rule == "FOB"
    end

    test "extracts PRODUCT_AND_SPECS", %{clauses: clauses} do
      c = find_clause(clauses, "PRODUCT_AND_SPECS")
      assert c != nil
      assert c.extracted_fields.product_name == "Anhydrous Ammonia (NH3)"
    end

    test "extracts QUANTITY_TOLERANCE with value", %{clauses: clauses} do
      c = find_clause(clauses, "QUANTITY_TOLERANCE")
      assert c != nil
      assert c.value == 25_000.0
      assert c.extracted_fields.tolerance_pct == 5.0
      assert c.extracted_fields.option_holder == :seller_option
    end

    test "extracts PRICE with dollar amount", %{clauses: clauses} do
      c = find_clause(clauses, "PRICE")
      assert c != nil
      assert c.value == 385.0
      assert c.parameter == :nola_buy
    end

    test "extracts PORTS_AND_SAFE_BERTH", %{clauses: clauses} do
      c = find_clause(clauses, "PORTS_AND_SAFE_BERTH")
      assert c != nil
      assert c.extracted_fields.safe_port_safe_berth == true
    end

    test "extracts DATES_WINDOWS_NOMINATIONS", %{clauses: clauses} do
      c = find_clause(clauses, "DATES_WINDOWS_NOMINATIONS")
      assert c != nil
    end

    test "extracts PAYMENT", %{clauses: clauses} do
      c = find_clause(clauses, "PAYMENT")
      assert c != nil
      assert c.extracted_fields.payment_method == :lc
    end

    test "extracts LAYTIME_DEMURRAGE with rate", %{clauses: clauses} do
      c = find_clause(clauses, "LAYTIME_DEMURRAGE")
      assert c != nil
      assert c.penalty_per_unit == 35_000.0
      assert c.extracted_fields.allowed_laytime_formula == "BL_qty_div_rate"
    end

    test "extracts CHARTERPARTY_ASBATANKVOY_INCORP", %{clauses: clauses} do
      c = find_clause(clauses, "CHARTERPARTY_ASBATANKVOY_INCORP")
      assert c != nil
      assert c.extracted_fields.charterparty_form == "ASBATANKVOY"
    end

    test "extracts NOR_AND_READINESS", %{clauses: clauses} do
      c = find_clause(clauses, "NOR_AND_READINESS")
      assert c != nil
    end

    test "extracts PRESENTATION_COOLDOWN_GASSING", %{clauses: clauses} do
      c = find_clause(clauses, "PRESENTATION_COOLDOWN_GASSING")
      assert c != nil
      assert c.extracted_fields.who_pays_ammonia_used == :buyer
    end

    test "extracts VESSEL_ELIGIBILITY", %{clauses: clauses} do
      c = find_clause(clauses, "VESSEL_ELIGIBILITY")
      assert c != nil
      flags = c.extracted_fields.class_requirements
      assert flags.iacs == true
      assert flags.pandi == true
      assert flags.isps == true
    end

    test "extracts INSPECTION_AND_QTY_DETERMINATION", %{clauses: clauses} do
      c = find_clause(clauses, "INSPECTION_AND_QTY_DETERMINATION")
      assert c != nil
      assert c.extracted_fields.qty_basis == :bl_quantity
      assert c.extracted_fields.final_and_binding == true
    end

    test "extracts DOCUMENTS_AND_CERTIFICATES", %{clauses: clauses} do
      c = find_clause(clauses, "DOCUMENTS_AND_CERTIFICATES")
      assert c != nil
      assert :certificate_of_origin in c.extracted_fields.required_docs
      assert :eur1 in c.extracted_fields.required_docs
    end

    test "extracts FORCE_MAJEURE", %{clauses: clauses} do
      c = find_clause(clauses, "FORCE_MAJEURE")
      assert c != nil
      assert c.parameter == :force_majeure
      assert c.confidence == :high
    end

    test "extracts DEFAULT_AND_REMEDIES", %{clauses: clauses} do
      c = find_clause(clauses, "DEFAULT_AND_REMEDIES")
      assert c != nil
      assert c.extracted_fields.setoff_netting == true
    end

    test "extracts CLAIMS_NOTICE_AND_LIMITS", %{clauses: clauses} do
      c = find_clause(clauses, "CLAIMS_NOTICE_AND_LIMITS")
      assert c != nil
      assert c.extracted_fields.absolutely_barred == true
      assert c.extracted_fields.limitation_period == "1 year"
    end

    test "extracts GOVERNING_LAW_AND_ARBITRATION", %{clauses: clauses} do
      c = find_clause(clauses, "GOVERNING_LAW_AND_ARBITRATION")
      assert c != nil
      assert c.extracted_fields.governing_law == :english
      assert c.extracted_fields.forum == :lmaa
    end

    test "extracts MISCELLANEOUS_BOILERPLATE", %{clauses: clauses} do
      c = find_clause(clauses, "MISCELLANEOUS_BOILERPLATE")
      assert c != nil
    end

    test "coverage: all required clauses present", %{text: text} do
      coverage = Parser.extraction_coverage(text)
      family_reqs = TemplateRegistry.required_clause_ids("VESSEL_SPOT_PURCHASE")

      missing = Enum.filter(family_reqs, fn id -> coverage[id] != true end)
      assert missing == [], "Missing required clauses: #{inspect(missing)}"
    end
  end

  # ──────────────────────────────────────────────────────────
  # VESSEL SPOT SALE CFR — 25 expected clauses
  # ──────────────────────────────────────────────────────────

  describe "vessel spot sale CFR" do
    setup do
      text = read_fixture("vessel_spot_sale_cfr.txt")
      {clauses, warnings, _family} = Parser.parse(text)
      %{clauses: clauses, warnings: warnings, text: text}
    end

    test "extracts PRICE as sale", %{clauses: clauses} do
      c = find_clause(clauses, "PRICE")
      assert c != nil
      assert c.value == 420.0
    end

    test "extracts INSURANCE", %{clauses: clauses} do
      c = find_clause(clauses, "INSURANCE")
      assert c != nil
      assert c.extracted_fields.who_insures == :seller
      assert c.extracted_fields.war_risk_addon == true
    end

    test "extracts LOI", %{clauses: clauses} do
      c = find_clause(clauses, "LOI")
      assert c != nil
    end

    test "extracts TAXES_FEES_DUES", %{clauses: clauses} do
      c = find_clause(clauses, "TAXES_FEES_DUES")
      assert c != nil
      assert c.extracted_fields.add_to_price_rule == true
    end

    test "extracts WARRANTY_DISCLAIMER", %{clauses: clauses} do
      c = find_clause(clauses, "WARRANTY_DISCLAIMER")
      assert c != nil
    end

    test "coverage: all required clauses present", %{text: text} do
      coverage = Parser.extraction_coverage(text)
      family_reqs = TemplateRegistry.required_clause_ids("VESSEL_SPOT_SALE")

      missing = Enum.filter(family_reqs, fn id -> coverage[id] != true end)
      assert missing == [], "Missing required clauses: #{inspect(missing)}"
    end
  end

  # ──────────────────────────────────────────────────────────
  # VESSEL SPOT DAP — 21 expected clauses
  # ──────────────────────────────────────────────────────────

  describe "vessel spot DAP" do
    setup do
      text = read_fixture("vessel_spot_dap.txt")
      {clauses, warnings, _family} = Parser.parse(text)
      %{clauses: clauses, warnings: warnings, text: text}
    end

    test "extracts PRICE with DAP value", %{clauses: clauses} do
      c = find_clause(clauses, "PRICE")
      assert c != nil
      assert c.value == 465.0
    end

    test "extracts INCOTERMS as DAP", %{clauses: clauses} do
      c = find_clause(clauses, "INCOTERMS")
      assert c != nil
      assert c.extracted_fields.incoterm_rule == "DAP"
    end

    test "coverage: all required clauses present", %{text: text} do
      coverage = Parser.extraction_coverage(text)
      family_reqs = TemplateRegistry.required_clause_ids("VESSEL_SPOT_DAP")

      missing = Enum.filter(family_reqs, fn id -> coverage[id] != true end)
      assert missing == [], "Missing required clauses: #{inspect(missing)}"
    end
  end

  # ──────────────────────────────────────────────────────────
  # DOMESTIC CPT TRUCKS — 14 expected clauses
  # ──────────────────────────────────────────────────────────

  describe "domestic CPT trucks" do
    setup do
      text = read_fixture("domestic_cpt_trucks.txt")
      {clauses, warnings, _family} = Parser.parse(text)
      %{clauses: clauses, warnings: warnings, text: text}
    end

    test "extracts PRICE as CPT", %{clauses: clauses} do
      c = find_clause(clauses, "PRICE")
      assert c != nil
      assert c.value == 395.0
    end

    test "extracts INCOTERMS as CPT", %{clauses: clauses} do
      c = find_clause(clauses, "INCOTERMS")
      assert c != nil
      assert c.extracted_fields.incoterm_rule == "CPT"
    end

    test "extracts INSPECTION with scale/flow meter", %{clauses: clauses} do
      c = find_clause(clauses, "INSPECTION_AND_QTY_DETERMINATION")
      assert c != nil
    end

    test "extracts GOVERNING_LAW as New York / SMA", %{clauses: clauses} do
      c = find_clause(clauses, "GOVERNING_LAW_AND_ARBITRATION")
      assert c != nil
      assert c.extracted_fields.governing_law == :new_york
      assert c.extracted_fields.forum == :sma
    end

    test "coverage: all required clauses present", %{text: text} do
      coverage = Parser.extraction_coverage(text)
      family_reqs = TemplateRegistry.required_clause_ids("DOMESTIC_CPT_TRUCKS")

      missing = Enum.filter(family_reqs, fn id -> coverage[id] != true end)
      assert missing == [], "Missing required clauses: #{inspect(missing)}"
    end
  end

  # ──────────────────────────────────────────────────────────
  # DOMESTIC MULTIMODAL — 13 expected clauses
  # ──────────────────────────────────────────────────────────

  describe "domestic multimodal sale" do
    setup do
      text = read_fixture("domestic_multimodal_sale.txt")
      {clauses, warnings, _family} = Parser.parse(text)
      %{clauses: clauses, warnings: warnings, text: text}
    end

    test "extracts PRICE with barge rate", %{clauses: clauses} do
      c = find_clause(clauses, "PRICE")
      assert c != nil
      assert c.value == 405.0
    end

    test "coverage: all required clauses present", %{text: text} do
      coverage = Parser.extraction_coverage(text)
      family_reqs = TemplateRegistry.required_clause_ids("DOMESTIC_MULTIMODAL_SALE")

      missing = Enum.filter(family_reqs, fn id -> coverage[id] != true end)
      assert missing == [], "Missing required clauses: #{inspect(missing)}"
    end
  end

  # ──────────────────────────────────────────────────────────
  # LONG TERM SALE CFR — 20 expected clauses
  # ──────────────────────────────────────────────────────────

  describe "long-term sale CFR" do
    setup do
      text = read_fixture("long_term_sale_cfr.txt")
      {clauses, warnings, _family} = Parser.parse(text)
      %{clauses: clauses, warnings: warnings, text: text}
    end

    test "extracts PRICE with index mechanism (Fertecon/FMB)", %{clauses: clauses} do
      c = find_clause(clauses, "PRICE")
      assert c != nil
      assert c.extracted_fields.pricing_mechanism == :index_reference
    end

    test "extracts QUANTITY_TOLERANCE with annual volume", %{clauses: clauses} do
      c = find_clause(clauses, "QUANTITY_TOLERANCE")
      assert c != nil
      assert c.value == 120_000.0
      assert c.extracted_fields.tolerance_pct == 10.0
    end

    test "extracts DATES_WINDOWS_NOMINATIONS with quarterly structure", %{clauses: clauses} do
      c = find_clause(clauses, "DATES_WINDOWS_NOMINATIONS")
      assert c != nil
    end

    test "extracts HARDSHIP_AND_REPRESENTATIONS", %{clauses: clauses} do
      c = find_clause(clauses, "HARDSHIP_AND_REPRESENTATIONS")
      assert c != nil
      assert c.extracted_fields.hardship_present == true
    end

    test "coverage: all required clauses present", %{text: text} do
      coverage = Parser.extraction_coverage(text)
      family_reqs = TemplateRegistry.required_clause_ids("LONG_TERM_SALE_CFR")

      missing = Enum.filter(family_reqs, fn id -> coverage[id] != true end)
      assert missing == [], "Missing required clauses: #{inspect(missing)}"
    end
  end

  # ──────────────────────────────────────────────────────────
  # LONG TERM PURCHASE FOB — 19 expected clauses
  # ──────────────────────────────────────────────────────────

  describe "long-term purchase FOB" do
    setup do
      text = read_fixture("long_term_purchase_fob.txt")
      {clauses, warnings, _family} = Parser.parse(text)
      %{clauses: clauses, warnings: warnings, text: text}
    end

    test "extracts PRICE as purchase", %{clauses: clauses} do
      c = find_clause(clauses, "PRICE")
      assert c != nil
      assert c.value == 340.0
      assert c.parameter == :nola_buy
    end

    test "extracts QUANTITY_TOLERANCE with annual volume", %{clauses: clauses} do
      c = find_clause(clauses, "QUANTITY_TOLERANCE")
      assert c != nil
      assert c.value == 200_000.0
    end

    test "extracts DOCUMENTS_AND_CERTIFICATES", %{clauses: clauses} do
      c = find_clause(clauses, "DOCUMENTS_AND_CERTIFICATES")
      assert c != nil
      assert :certificate_of_origin in c.extracted_fields.required_docs
      assert :form_a in c.extracted_fields.required_docs
    end

    test "extracts PRESENTATION_COOLDOWN_GASSING", %{clauses: clauses} do
      c = find_clause(clauses, "PRESENTATION_COOLDOWN_GASSING")
      assert c != nil
      assert c.extracted_fields.who_pays_ammonia_used == :buyer
    end

    test "coverage: all required clauses present", %{text: text} do
      coverage = Parser.extraction_coverage(text)
      family_reqs = TemplateRegistry.required_clause_ids("LONG_TERM_PURCHASE_FOB")

      missing = Enum.filter(family_reqs, fn id -> coverage[id] != true end)
      assert missing == [], "Missing required clauses: #{inspect(missing)}"
    end
  end

  # ──────────────────────────────────────────────────────────
  # LP VARIABLE MAPPING
  # ──────────────────────────────────────────────────────────

  describe "LP variable mapping" do
    test "purchase price maps to :nola_buy" do
      text = read_fixture("vessel_spot_purchase_fob.txt")
      {clauses, _, _} = Parser.parse(text)
      price = find_clause(clauses, "PRICE")
      assert price.parameter == :nola_buy
      assert price.value == 385.0
    end

    test "volume maps to :total_volume" do
      text = read_fixture("vessel_spot_purchase_fob.txt")
      {clauses, _, _} = Parser.parse(text)
      qty = find_clause(clauses, "QUANTITY_TOLERANCE")
      assert qty.parameter == :total_volume
      assert qty.value == 25_000.0
    end

    test "demurrage maps to :demurrage" do
      text = read_fixture("vessel_spot_purchase_fob.txt")
      {clauses, _, _} = Parser.parse(text)
      dem = find_clause(clauses, "LAYTIME_DEMURRAGE")
      assert dem.parameter == :demurrage
      assert dem.penalty_per_unit == 35_000.0
    end

    test "force majeure maps to :force_majeure" do
      text = read_fixture("vessel_spot_purchase_fob.txt")
      {clauses, _, _} = Parser.parse(text)
      fm = find_clause(clauses, "FORCE_MAJEURE")
      assert fm.parameter == :force_majeure
    end

    test "payment maps to :working_cap" do
      text = read_fixture("vessel_spot_purchase_fob.txt")
      {clauses, _, _} = Parser.parse(text)
      pay = find_clause(clauses, "PAYMENT")
      assert pay.parameter == :working_cap
    end
  end

  # ──────────────────────────────────────────────────────────
  # HELPERS
  # ──────────────────────────────────────────────────────────

  defp find_clause(clauses, clause_id) do
    Enum.find(clauses, fn c -> c.clause_id == clause_id end)
  end
end
