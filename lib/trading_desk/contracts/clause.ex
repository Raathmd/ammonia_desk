defmodule TradingDesk.Contracts.Clause do
  @moduledoc """
  A single extracted clause from a physical contract.

  Each clause is identified by its canonical clause_id from the template
  inventory (e.g., "PRICE", "QUANTITY_TOLERANCE", "FORCE_MAJEURE").

  Clauses carry both:
    - Structural data (clause_id, category, anchors matched)
    - Extracted fields (numeric values, text, LP-mappable parameters)

  Clause types for LP-relevant clauses:
    :obligation  — volume commitments (QUANTITY_TOLERANCE)
    :penalty     — demurrage, late delivery (LAYTIME_DEMURRAGE)
    :condition   — trigger conditions (FORCE_MAJEURE, DEFAULT_AND_REMEDIES)
    :price_term  — pricing terms (PRICE, PAYMENT, TAXES_FEES_DUES)
    :limit       — capacity constraints
    :delivery    — scheduling terms (DATES_WINDOWS_NOMINATIONS)
    :metadata    — identification (INCOTERMS, PRODUCT_AND_SPECS)
    :legal       — legal provisions (GOVERNING_LAW, CLAIMS, etc.)
    :compliance  — regulatory (VESSEL_ELIGIBILITY, EXPORT_IMPORT_REACH)
    :operational — vessel ops (NOR_AND_READINESS, PRESENTATION_COOLDOWN)
  """

  @enforce_keys [:type, :description]

  defstruct [
    :id,
    :clause_id,          # canonical clause ID: "PRICE", "QUANTITY_TOLERANCE", etc.
    :type,               # :obligation | :penalty | :condition | :price_term | :limit |
                         # :delivery | :metadata | :legal | :compliance | :operational
    :category,           # from canonical: :core_terms | :commercial | :logistics | etc.
    :description,        # original clause text from the contract
    :parameter,          # solver variable key, e.g. :nola_buy, :total_volume
    :operator,           # :>= | :<= | :== | :between
    :value,              # numeric bound (or lower bound for :between)
    :value_upper,        # upper bound for :between ranges
    :unit,               # "tons" | "$/ton" | "days" | "mt/hr" | "$" etc.
    :penalty_per_unit,   # $/ton or $/day for violations
    :penalty_cap,        # maximum penalty exposure
    :period,             # :monthly | :quarterly | :annual | :spot
    :reference_section,  # section/paragraph reference in original document
    :confidence,         # :high | :medium | :low — parser confidence
    :anchors_matched,    # which anchor strings from the canonical matched
    :extracted_fields,   # map of extracted field values from this clause
    extracted_at: nil
  ]

  @type clause_type :: :obligation | :penalty | :condition | :price_term | :limit |
                       :delivery | :metadata | :legal | :compliance | :operational

  @type operator :: :>= | :<= | :== | :between
  @type confidence :: :high | :medium | :low

  @type t :: %__MODULE__{
    id: String.t() | nil,
    clause_id: String.t() | nil,
    type: clause_type(),
    category: atom() | nil,
    description: String.t(),
    parameter: atom() | nil,
    operator: operator() | nil,
    value: number() | nil,
    value_upper: number() | nil,
    unit: String.t() | nil,
    penalty_per_unit: number() | nil,
    penalty_cap: number() | nil,
    period: atom() | nil,
    reference_section: String.t() | nil,
    confidence: confidence() | nil,
    anchors_matched: [String.t()] | nil,
    extracted_fields: map() | nil,
    extracted_at: DateTime.t() | nil
  }

  @doc "Generate a unique clause ID"
  def generate_id do
    :crypto.strong_rand_bytes(8) |> Base.hex_encode32(case: :lower, padding: false)
  end
end
