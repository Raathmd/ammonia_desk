defmodule AmmoniaDesk.Contracts.TemplateRegistry do
  @moduledoc """
  Registry of contract templates by type, incoterm, and company.

  Every physical contract in the ammonia trading business follows a template.
  This registry defines:
    - What contract types exist (purchase, sale, spot_purchase, spot_sale)
    - What Incoterms apply (FOB, CIF, CFR, DAP, FCA, EXW)
    - Which company entity is the contracting party
    - What clauses are REQUIRED vs EXPECTED vs OPTIONAL per template
    - What parameters each clause type must extract

  When a contract is parsed, its extraction is validated against its template.
  Missing REQUIRED clauses block legal review. Missing EXPECTED clauses
  generate warnings. This ensures completeness across all product groups.

  Templates are deterministic — no LLM involvement. They define the
  structural expectations that the parser must satisfy.
  """

  # --- Contract Types ---

  @contract_types [:purchase, :sale, :spot_purchase, :spot_sale]

  # --- Term Types ---

  @term_types [:spot, :long_term]

  # --- Incoterms relevant to ammonia trading ---

  @incoterms [:fob, :cif, :cfr, :dap, :ddp, :fca, :exw]

  # --- Company entities (Trammo divisions) ---

  @companies [
    :trammo_inc,     # Trammo, Inc. – Ammonia Division
    :trammo_sas,     # Trammo SAS (European operations)
    :trammo_dmcc     # Trammo DMCC (Middle East / APAC operations)
  ]

  # --- Clause requirement levels ---
  # :required  — extraction MUST find this or contract cannot proceed past draft
  # :expected  — extraction SHOULD find this; missing generates a warning
  # :optional  — nice to have, no penalty if missing

  @type clause_requirement :: %{
    clause_type: atom(),
    parameter_class: atom() | nil,
    level: :required | :expected | :optional,
    description: String.t()
  }

  @type template :: %{
    contract_type: atom(),
    incoterm: atom() | nil,
    clause_requirements: [clause_requirement()],
    notes: String.t()
  }

  # ──────────────────────────────────────────────────────────
  # PURCHASE CONTRACT TEMPLATES
  # ──────────────────────────────────────────────────────────

  @purchase_base [
    %{clause_type: :obligation, parameter_class: :volume, level: :required,
      description: "Minimum volume commitment from supplier"},
    %{clause_type: :price_term, parameter_class: :buy_price, level: :required,
      description: "Purchase price per ton (fixed or index-linked)"},
    %{clause_type: :delivery, parameter_class: :delivery_window, level: :required,
      description: "Delivery schedule / window"},
    %{clause_type: :condition, parameter_class: :force_majeure, level: :required,
      description: "Force majeure clause"},
    %{clause_type: :penalty, parameter_class: :volume_shortfall, level: :expected,
      description: "Shortfall penalty if supplier underdelivers"},
    %{clause_type: :penalty, parameter_class: :late_delivery, level: :expected,
      description: "Late delivery penalty"},
    %{clause_type: :limit, parameter_class: :max_volume, level: :expected,
      description: "Maximum volume cap per period"},
    %{clause_type: :obligation, parameter_class: :inventory, level: :optional,
      description: "Inventory buffer requirement at terminal"},
    %{clause_type: :limit, parameter_class: :working_capital, level: :optional,
      description: "Credit / working capital limit"}
  ]

  @purchase_fob @purchase_base

  @purchase_cif @purchase_base ++ [
    %{clause_type: :price_term, parameter_class: :freight, level: :required,
      description: "Freight cost included in CIF price"},
    %{clause_type: :condition, parameter_class: :insurance, level: :required,
      description: "Insurance terms (CIF requires seller insurance)"}
  ]

  @purchase_cfr @purchase_base ++ [
    %{clause_type: :price_term, parameter_class: :freight, level: :required,
      description: "Freight cost included in CFR price"}
  ]

  @purchase_dap @purchase_base ++ [
    %{clause_type: :price_term, parameter_class: :freight, level: :required,
      description: "Delivered price includes all transport to named place"},
    %{clause_type: :penalty, parameter_class: :demurrage, level: :expected,
      description: "Demurrage at destination if buyer delays unloading"}
  ]

  @purchase_fca @purchase_base ++ [
    %{clause_type: :delivery, parameter_class: :pickup_terms, level: :expected,
      description: "Pickup / carrier handoff terms"}
  ]

  @purchase_exw @purchase_base

  @purchase_ddp @purchase_base ++ [
    %{clause_type: :price_term, parameter_class: :freight, level: :required,
      description: "Full delivered price includes transport + duties to destination"},
    %{clause_type: :condition, parameter_class: :import_duties, level: :required,
      description: "Import duties / customs clearance (DDP seller responsibility)"},
    %{clause_type: :penalty, parameter_class: :demurrage, level: :expected,
      description: "Demurrage at destination"}
  ]

  # ──────────────────────────────────────────────────────────
  # SALE CONTRACT TEMPLATES
  # ──────────────────────────────────────────────────────────

  @sale_base [
    %{clause_type: :obligation, parameter_class: :volume, level: :required,
      description: "Minimum volume commitment to customer"},
    %{clause_type: :price_term, parameter_class: :sell_price, level: :required,
      description: "Sale price per ton"},
    %{clause_type: :delivery, parameter_class: :delivery_window, level: :required,
      description: "Delivery schedule / window"},
    %{clause_type: :condition, parameter_class: :force_majeure, level: :required,
      description: "Force majeure clause"},
    %{clause_type: :penalty, parameter_class: :volume_shortfall, level: :required,
      description: "Shortfall penalty if we underdeliver"},
    %{clause_type: :penalty, parameter_class: :late_delivery, level: :expected,
      description: "Late delivery penalty"},
    %{clause_type: :penalty, parameter_class: :demurrage, level: :expected,
      description: "Demurrage charges for barge waiting"},
    %{clause_type: :limit, parameter_class: :max_volume, level: :expected,
      description: "Maximum volume cap per period"},
    %{clause_type: :obligation, parameter_class: :inventory, level: :optional,
      description: "Inventory maintenance at customer terminal"},
    %{clause_type: :limit, parameter_class: :barge_capacity, level: :optional,
      description: "Barge fleet / capacity constraint"}
  ]

  @sale_fob @sale_base

  @sale_cif @sale_base ++ [
    %{clause_type: :price_term, parameter_class: :freight, level: :required,
      description: "Freight component of CIF sale price"},
    %{clause_type: :condition, parameter_class: :insurance, level: :required,
      description: "Seller-arranged insurance (CIF)"}
  ]

  @sale_cfr @sale_base ++ [
    %{clause_type: :price_term, parameter_class: :freight, level: :required,
      description: "Freight component of CFR sale price"}
  ]

  @sale_dap @sale_base ++ [
    %{clause_type: :price_term, parameter_class: :freight, level: :required,
      description: "Full delivered price to named place"},
    %{clause_type: :penalty, parameter_class: :demurrage, level: :required,
      description: "Demurrage — elevated to required for DAP"}
  ]

  @sale_fca @sale_base ++ [
    %{clause_type: :delivery, parameter_class: :pickup_terms, level: :expected,
      description: "FCA carrier handoff terms"}
  ]

  @sale_exw @sale_base

  @sale_ddp @sale_base ++ [
    %{clause_type: :price_term, parameter_class: :freight, level: :required,
      description: "Full delivered price includes transport + duties"},
    %{clause_type: :condition, parameter_class: :import_duties, level: :required,
      description: "Import duties / customs (DDP seller responsibility)"},
    %{clause_type: :penalty, parameter_class: :demurrage, level: :required,
      description: "Demurrage — elevated to required for DDP"}
  ]

  # ──────────────────────────────────────────────────────────
  # SPOT CONTRACT TEMPLATES (simplified, but still strict)
  # ──────────────────────────────────────────────────────────

  @spot_purchase_base [
    %{clause_type: :price_term, parameter_class: :buy_price, level: :required,
      description: "Spot purchase price per ton"},
    %{clause_type: :obligation, parameter_class: :volume, level: :required,
      description: "Spot volume (single shipment)"},
    %{clause_type: :delivery, parameter_class: :delivery_window, level: :required,
      description: "Delivery date / window for spot shipment"},
    %{clause_type: :penalty, parameter_class: :demurrage, level: :expected,
      description: "Demurrage for spot barge"},
    %{clause_type: :condition, parameter_class: :force_majeure, level: :expected,
      description: "Force majeure (even spot contracts need this)"}
  ]

  @spot_sale_base [
    %{clause_type: :price_term, parameter_class: :sell_price, level: :required,
      description: "Spot sale price per ton"},
    %{clause_type: :obligation, parameter_class: :volume, level: :required,
      description: "Spot volume (single shipment)"},
    %{clause_type: :delivery, parameter_class: :delivery_window, level: :required,
      description: "Delivery date / window for spot shipment"},
    %{clause_type: :penalty, parameter_class: :demurrage, level: :expected,
      description: "Demurrage for spot barge"},
    %{clause_type: :penalty, parameter_class: :volume_shortfall, level: :expected,
      description: "Shortfall penalty for spot sale"},
    %{clause_type: :condition, parameter_class: :force_majeure, level: :expected,
      description: "Force majeure"}
  ]

  # ──────────────────────────────────────────────────────────
  # PUBLIC API
  # ──────────────────────────────────────────────────────────

  @doc "All known contract types"
  def contract_types, do: @contract_types

  @doc "All known term types"
  def term_types, do: @term_types

  @doc "All known Incoterms"
  def incoterms, do: @incoterms

  @doc "All known company entities (Trammo divisions)"
  def companies, do: @companies

  @doc "Human-readable company name"
  def company_label(:trammo_inc), do: "Trammo, Inc. — Ammonia Division"
  def company_label(:trammo_sas), do: "Trammo SAS"
  def company_label(:trammo_dmcc), do: "Trammo DMCC"
  def company_label(other), do: to_string(other)

  @doc """
  Get the template for a given contract_type and incoterm.

  Returns {:ok, template} or {:error, :unknown_template}.
  """
  @spec get_template(atom(), atom() | nil) :: {:ok, template()} | {:error, :unknown_template}
  def get_template(contract_type, incoterm \\ nil)

  # Purchase templates
  def get_template(:purchase, :fob), do: {:ok, build(:purchase, :fob, @purchase_fob)}
  def get_template(:purchase, :cif), do: {:ok, build(:purchase, :cif, @purchase_cif)}
  def get_template(:purchase, :cfr), do: {:ok, build(:purchase, :cfr, @purchase_cfr)}
  def get_template(:purchase, :dap), do: {:ok, build(:purchase, :dap, @purchase_dap)}
  def get_template(:purchase, :fca), do: {:ok, build(:purchase, :fca, @purchase_fca)}
  def get_template(:purchase, :exw), do: {:ok, build(:purchase, :exw, @purchase_exw)}
  def get_template(:purchase, :ddp), do: {:ok, build(:purchase, :ddp, @purchase_ddp)}
  def get_template(:purchase, nil), do: {:ok, build(:purchase, nil, @purchase_base)}

  # Sale templates
  def get_template(:sale, :fob), do: {:ok, build(:sale, :fob, @sale_fob)}
  def get_template(:sale, :cif), do: {:ok, build(:sale, :cif, @sale_cif)}
  def get_template(:sale, :cfr), do: {:ok, build(:sale, :cfr, @sale_cfr)}
  def get_template(:sale, :dap), do: {:ok, build(:sale, :dap, @sale_dap)}
  def get_template(:sale, :fca), do: {:ok, build(:sale, :fca, @sale_fca)}
  def get_template(:sale, :exw), do: {:ok, build(:sale, :exw, @sale_exw)}
  def get_template(:sale, :ddp), do: {:ok, build(:sale, :ddp, @sale_ddp)}
  def get_template(:sale, nil), do: {:ok, build(:sale, nil, @sale_base)}

  # Spot templates (incoterm not typically relevant but accepted)
  def get_template(:spot_purchase, _), do: {:ok, build(:spot_purchase, nil, @spot_purchase_base)}
  def get_template(:spot_sale, _), do: {:ok, build(:spot_sale, nil, @spot_sale_base)}

  def get_template(_, _), do: {:error, :unknown_template}

  @doc """
  Get required clause types for a template.
  Returns a flat list of {clause_type, parameter_class} pairs that MUST be present.
  """
  def required_clauses(contract_type, incoterm \\ nil) do
    case get_template(contract_type, incoterm) do
      {:ok, template} ->
        template.clause_requirements
        |> Enum.filter(&(&1.level == :required))
        |> Enum.map(&{&1.clause_type, &1.parameter_class})

      {:error, _} -> []
    end
  end

  @doc """
  Get expected clause types (required + expected, not optional).
  """
  def expected_clauses(contract_type, incoterm \\ nil) do
    case get_template(contract_type, incoterm) do
      {:ok, template} ->
        template.clause_requirements
        |> Enum.filter(&(&1.level in [:required, :expected]))
        |> Enum.map(&{&1.clause_type, &1.parameter_class})

      {:error, _} -> []
    end
  end

  @doc """
  List all templates as summary maps (for UI display).
  """
  def list_templates do
    for ct <- @contract_types, ic <- [nil | @incoterms] do
      case get_template(ct, ic) do
        {:ok, t} ->
          required = Enum.count(t.clause_requirements, &(&1.level == :required))
          expected = Enum.count(t.clause_requirements, &(&1.level == :expected))
          %{
            contract_type: ct,
            incoterm: ic,
            required_count: required,
            expected_count: expected,
            total_count: length(t.clause_requirements)
          }
        _ -> nil
      end
    end
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(&{&1.contract_type, &1.incoterm})
  end

  @doc """
  Map a parameter_class from the template to the actual solver parameter atoms
  that the parser might extract. Used for matching extracted clauses against
  template requirements.
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

  # --- Private ---

  defp build(contract_type, incoterm, requirements) do
    %{
      contract_type: contract_type,
      incoterm: incoterm,
      clause_requirements: requirements,
      notes: template_notes(contract_type, incoterm)
    }
  end

  defp template_notes(:purchase, :cif), do: "CIF purchase: seller bears freight + insurance to destination"
  defp template_notes(:purchase, :cfr), do: "CFR purchase: seller bears freight, buyer bears insurance"
  defp template_notes(:purchase, :dap), do: "DAP purchase: delivered at place, seller bears all costs to destination"
  defp template_notes(:purchase, :fob), do: "FOB purchase: risk transfers at loading port, buyer arranges freight"
  defp template_notes(:purchase, :fca), do: "FCA purchase: seller delivers to carrier at named place"
  defp template_notes(:purchase, :exw), do: "EXW purchase: buyer collects at seller's premises"
  defp template_notes(:purchase, :ddp), do: "DDP purchase: seller bears all costs + duties to destination"
  defp template_notes(:sale, :cif), do: "CIF sale: we bear freight + insurance to customer"
  defp template_notes(:sale, :cfr), do: "CFR sale: we bear freight, customer bears insurance"
  defp template_notes(:sale, :dap), do: "DAP sale: we deliver to customer's named place"
  defp template_notes(:sale, :fob), do: "FOB sale: customer arranges freight from loading port"
  defp template_notes(:sale, :fca), do: "FCA sale: we deliver to carrier at named place"
  defp template_notes(:sale, :exw), do: "EXW sale: customer collects from our terminal"
  defp template_notes(:sale, :ddp), do: "DDP sale: we bear all costs + duties to customer destination"
  defp template_notes(:spot_purchase, _), do: "Spot purchase: single-shipment buy, simplified terms"
  defp template_notes(:spot_sale, _), do: "Spot sale: single-shipment sell, simplified terms"
  defp template_notes(_, _), do: ""
end
