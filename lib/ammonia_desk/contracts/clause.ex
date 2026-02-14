defmodule AmmoniaDesk.Contracts.Clause do
  @moduledoc """
  A single extracted clause from a physical contract.

  Each clause maps to a solver constraint or commercial term:
    - :obligation  — minimum/maximum volume commitments
    - :penalty     — demurrage, late delivery, shortfall penalties
    - :condition   — trigger conditions (e.g., force majeure, weather)
    - :price_term  — fixed price, index-linked, escalation formulas
    - :limit       — capacity, fleet, or capital constraints
    - :delivery    — delivery windows, scheduling terms
  """

  @enforce_keys [:type, :description]

  defstruct [
    :id,
    :type,              # :obligation | :penalty | :condition | :price_term | :limit | :delivery
    :description,       # original clause text from the contract
    :parameter,         # solver variable key, e.g. :inv_don, :fr_don_stl, :barge_count
    :operator,          # :>= | :<= | :== | :between
    :value,             # numeric bound (or lower bound for :between)
    :value_upper,       # upper bound for :between ranges
    :unit,              # "tons" | "$/ton" | "days" | "barges" | "$"
    :penalty_per_unit,  # $/ton or $/day for violations
    :penalty_cap,       # maximum penalty exposure
    :period,            # :monthly | :quarterly | :annual | :spot
    :reference_section, # section/paragraph reference in original document
    :confidence,        # :high | :medium | :low — parser confidence
    extracted_at: nil
  ]

  @type clause_type :: :obligation | :penalty | :condition | :price_term | :limit | :delivery
  @type operator :: :>= | :<= | :== | :between
  @type confidence :: :high | :medium | :low

  @type t :: %__MODULE__{
    id: String.t() | nil,
    type: clause_type(),
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
    extracted_at: DateTime.t() | nil
  }

  @doc "Generate a unique clause ID"
  def generate_id do
    :crypto.strong_rand_bytes(8) |> Base.hex_encode32(case: :lower, padding: false)
  end
end
