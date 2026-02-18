defmodule TradingDesk.DB.ContractRecord do
  @moduledoc """
  Ecto schema for persisted contracts.

  This is the durable record of a contract version. Once written, a contract
  record is immutable — new versions create new rows. The `version` field
  is auto-incremented per counterparty+product_group pair.

  Contracts flow:  ETS (working state) → DB (durable audit trail).
  The ETS Store remains the fast-path for solves; the DB is the audit record.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}

  schema "contracts" do
    # Identity
    field :counterparty, :string
    field :counterparty_type, :string
    field :product_group, :string
    field :version, :integer
    field :status, :string

    # Document
    field :source_file, :string
    field :source_format, :string
    field :file_hash, :string
    field :file_size, :integer
    field :network_path, :string
    field :contract_number, :string
    field :family_id, :string

    # Graph API
    field :graph_item_id, :string
    field :graph_drive_id, :string

    # Commercial
    field :template_type, :string
    field :incoterm, :string
    field :term_type, :string
    field :company, :string
    field :contract_date, :date
    field :expiry_date, :date

    # SAP
    field :sap_contract_id, :string
    field :sap_validated, :boolean, default: false

    # Review
    field :reviewed_by, :string
    field :reviewed_at, :utc_datetime
    field :review_notes, :string

    # Clauses stored as JSONB — the full extracted clause data
    field :clauses_data, :map

    # Validation results as JSONB
    field :template_validation, :map
    field :llm_validation, :map
    field :sap_discrepancies, {:array, :map}

    # Verification
    field :verification_status, :string
    field :last_verified_at, :utc_datetime
    field :previous_hash, :string

    # Position
    field :open_position, :float

    # Relationship
    has_many :solve_links, TradingDesk.DB.SolveAuditContract, foreign_key: :contract_id

    timestamps(type: :utc_datetime)
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [
      :id, :counterparty, :counterparty_type, :product_group, :version,
      :status, :source_file, :source_format, :file_hash, :file_size,
      :network_path, :contract_number, :family_id, :graph_item_id,
      :graph_drive_id, :template_type, :incoterm, :term_type, :company,
      :contract_date, :expiry_date, :sap_contract_id, :sap_validated,
      :reviewed_by, :reviewed_at, :review_notes, :clauses_data,
      :template_validation, :llm_validation, :sap_discrepancies,
      :verification_status, :last_verified_at, :previous_hash, :open_position
    ])
    |> validate_required([:id, :counterparty, :counterparty_type, :product_group, :version])
  end

  @doc "Convert an in-memory Contract struct to DB attrs."
  def from_contract(%TradingDesk.Contracts.Contract{} = c) do
    %{
      id: c.id,
      counterparty: c.counterparty,
      counterparty_type: to_string(c.counterparty_type),
      product_group: to_string(c.product_group),
      version: c.version,
      status: to_string(c.status),
      source_file: c.source_file,
      source_format: if(c.source_format, do: to_string(c.source_format)),
      file_hash: c.file_hash,
      file_size: c.file_size,
      network_path: c.network_path,
      contract_number: c.contract_number,
      family_id: c.family_id,
      graph_item_id: c.graph_item_id,
      graph_drive_id: c.graph_drive_id,
      template_type: if(c.template_type, do: to_string(c.template_type)),
      incoterm: if(c.incoterm, do: to_string(c.incoterm)),
      term_type: if(c.term_type, do: to_string(c.term_type)),
      company: if(c.company, do: to_string(c.company)),
      contract_date: c.contract_date,
      expiry_date: c.expiry_date,
      sap_contract_id: c.sap_contract_id,
      sap_validated: c.sap_validated || false,
      reviewed_by: c.reviewed_by,
      reviewed_at: c.reviewed_at,
      review_notes: c.review_notes,
      clauses_data: serialize_clauses(c.clauses),
      template_validation: c.template_validation,
      llm_validation: c.llm_validation,
      sap_discrepancies: serialize_discrepancies(c.sap_discrepancies),
      verification_status: if(c.verification_status, do: to_string(c.verification_status)),
      last_verified_at: c.last_verified_at,
      previous_hash: c.previous_hash,
      open_position: c.open_position
    }
  end

  defp serialize_clauses(nil), do: %{"clauses" => []}
  defp serialize_clauses(clauses) when is_list(clauses) do
    %{"clauses" => Enum.map(clauses, &Map.from_struct/1)}
  end

  defp serialize_discrepancies(nil), do: nil
  defp serialize_discrepancies(discs) when is_list(discs), do: discs
end
