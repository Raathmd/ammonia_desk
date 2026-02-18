defmodule TradingDesk.Contracts.Contract do
  @moduledoc """
  A parsed physical contract with full identity and versioning.

  Identity is unique on {counterparty, product_group, version}.
  Only one contract per counterparty+product_group can be :approved at a time.

  Workflow:  :draft → :pending_review → :approved | :rejected
  """

  alias TradingDesk.Contracts.Clause

  @enforce_keys [:counterparty, :counterparty_type, :product_group]

  defstruct [
    :id,
    :counterparty,       # customer or supplier name (e.g., "Koch Fertilizer")
    :counterparty_type,  # :customer | :supplier
    :product_group,      # :ammonia | :uan | :urea (extensible)
    :template_type,      # :purchase | :sale | :spot_purchase | :spot_sale
    :incoterm,           # :fob | :cif | :cfr | :dap | :ddp | :fca | :exw
    :term_type,          # :spot | :long_term
    :company,            # :trammo_inc | :trammo_sas | :trammo_dmcc
    :version,            # integer, auto-incremented per counterparty+product_group
    :source_file,        # original filename
    :source_format,      # :pdf | :docx | :docm
    :scan_date,          # when the document was parsed
    :contract_date,      # effective date from the contract itself
    :expiry_date,        # contract expiration
    :status,             # :draft | :pending_review | :approved | :rejected
    :clauses,            # list of %Clause{}
    :template_validation, # result from TemplateValidator (completeness check)
    :llm_validation,     # result from LlmValidator (second-pass verification)
    :sap_contract_id,    # SAP reference number for cross-validation
    :sap_validated,      # boolean — has SAP validation passed
    :sap_discrepancies,  # list of {field, contract_value, sap_value} mismatches
    :reviewed_by,        # legal reviewer identifier
    :reviewed_at,        # timestamp of review
    :review_notes,       # legal reviewer comments
    :open_position,      # current open position in tons (from SAP/ERP)
    # --- Document integrity ---
    :contract_number,    # parsed from contract (e.g., "TRAMMO-LTP-2026-0001")
    :family_id,          # detected contract family (e.g., "VESSEL_SPOT_PURCHASE")
    :file_hash,          # SHA-256 hex of original document bytes
    :file_size,          # size in bytes of original document
    :network_path,       # original network location (UNC path, SharePoint URL, etc.)
    :last_verified_at,   # when file hash was last checked against network copy
    :verification_status, # :verified | :mismatch | :file_not_found | :pending | :error
    :previous_hash,      # hash of the previous version (audit chain)
    # --- Graph API identity (for Zig scanner delta checks) ---
    :graph_item_id,      # SharePoint/OneDrive item ID from Graph API
    :graph_drive_id,     # SharePoint document library drive ID
    :created_at,
    :updated_at
  ]

  @type counterparty_type :: :customer | :supplier
  @type product_group :: :ammonia | :uan | :urea
  @type template_type :: :purchase | :sale | :spot_purchase | :spot_sale
  @type incoterm :: :fob | :cif | :cfr | :dap | :ddp | :fca | :exw
  @type term_type :: :spot | :long_term
  @type company :: :trammo_inc | :trammo_sas | :trammo_dmcc
  @type status :: :draft | :pending_review | :approved | :rejected

  @type verification_status :: :verified | :mismatch | :file_not_found | :pending | :error

  @type t :: %__MODULE__{
    id: String.t() | nil,
    counterparty: String.t(),
    counterparty_type: counterparty_type(),
    product_group: product_group(),
    template_type: template_type() | nil,
    incoterm: incoterm() | nil,
    term_type: term_type() | nil,
    company: company() | nil,
    version: pos_integer() | nil,
    source_file: String.t() | nil,
    source_format: :pdf | :docx | :docm | nil,
    scan_date: DateTime.t() | nil,
    contract_date: Date.t() | nil,
    expiry_date: Date.t() | nil,
    status: status(),
    clauses: [Clause.t()],
    template_validation: map() | nil,
    llm_validation: map() | nil,
    sap_contract_id: String.t() | nil,
    sap_validated: boolean(),
    sap_discrepancies: list() | nil,
    reviewed_by: String.t() | nil,
    reviewed_at: DateTime.t() | nil,
    review_notes: String.t() | nil,
    open_position: number() | nil,
    contract_number: String.t() | nil,
    family_id: String.t() | nil,
    file_hash: String.t() | nil,
    file_size: non_neg_integer() | nil,
    network_path: String.t() | nil,
    last_verified_at: DateTime.t() | nil,
    verification_status: verification_status() | nil,
    previous_hash: String.t() | nil,
    graph_item_id: String.t() | nil,
    graph_drive_id: String.t() | nil,
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
