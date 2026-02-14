defmodule AmmoniaDesk.Contracts.Contract do
  @moduledoc """
  A parsed physical contract with full identity and versioning.

  Identity is unique on {counterparty, product_group, version}.
  Only one contract per counterparty+product_group can be :approved at a time.

  Workflow:  :draft → :pending_review → :approved | :rejected
  """

  alias AmmoniaDesk.Contracts.Clause

  @enforce_keys [:counterparty, :counterparty_type, :product_group]

  defstruct [
    :id,
    :counterparty,       # customer or supplier name (e.g., "Koch Fertilizer")
    :counterparty_type,  # :customer | :supplier
    :product_group,      # :ammonia | :uan | :urea (extensible)
    :version,            # integer, auto-incremented per counterparty+product_group
    :source_file,        # original filename
    :source_format,      # :pdf | :docx
    :scan_date,          # when the document was parsed
    :contract_date,      # effective date from the contract itself
    :expiry_date,        # contract expiration
    :status,             # :draft | :pending_review | :approved | :rejected
    :clauses,            # list of %Clause{}
    :sap_contract_id,    # SAP reference number for cross-validation
    :sap_validated,      # boolean — has SAP validation passed
    :sap_discrepancies,  # list of {field, contract_value, sap_value} mismatches
    :reviewed_by,        # legal reviewer identifier
    :reviewed_at,        # timestamp of review
    :review_notes,       # legal reviewer comments
    :open_position,      # current open position in tons (from SAP/ERP)
    :created_at,
    :updated_at
  ]

  @type counterparty_type :: :customer | :supplier
  @type product_group :: :ammonia | :uan | :urea
  @type status :: :draft | :pending_review | :approved | :rejected

  @type t :: %__MODULE__{
    id: String.t() | nil,
    counterparty: String.t(),
    counterparty_type: counterparty_type(),
    product_group: product_group(),
    version: pos_integer() | nil,
    source_file: String.t() | nil,
    source_format: :pdf | :docx | nil,
    scan_date: DateTime.t() | nil,
    contract_date: Date.t() | nil,
    expiry_date: Date.t() | nil,
    status: status(),
    clauses: [Clause.t()],
    sap_contract_id: String.t() | nil,
    sap_validated: boolean(),
    sap_discrepancies: list() | nil,
    reviewed_by: String.t() | nil,
    reviewed_at: DateTime.t() | nil,
    review_notes: String.t() | nil,
    open_position: number() | nil,
    created_at: DateTime.t() | nil,
    updated_at: DateTime.t() | nil
  }

  @doc "Generate a unique contract ID"
  def generate_id do
    :crypto.strong_rand_bytes(12) |> Base.hex_encode32(case: :lower, padding: false)
  end

  @doc "Build a canonical key for uniqueness (counterparty + product_group)"
  def canonical_key(%__MODULE__{counterparty: cp, product_group: pg}) do
    {normalize_name(cp), pg}
  end

  @doc "Check if the contract has expired"
  def expired?(%__MODULE__{expiry_date: nil}), do: false
  def expired?(%__MODULE__{expiry_date: expiry}) do
    Date.compare(Date.utc_today(), expiry) == :gt
  end

  @doc "Count clauses by type"
  def clause_counts(%__MODULE__{clauses: clauses}) when is_list(clauses) do
    Enum.frequencies_by(clauses, & &1.type)
  end
  def clause_counts(_), do: %{}

  defp normalize_name(name) when is_binary(name) do
    name |> String.trim() |> String.downcase()
  end
end
