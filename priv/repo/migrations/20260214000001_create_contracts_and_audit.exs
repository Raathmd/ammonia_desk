defmodule AmmoniaDesk.Repo.Migrations.CreateContractsAndAudit do
  use Ecto.Migration

  def change do
    # ──────────────────────────────────────────────────────────
    # CONTRACTS
    #
    # Immutable contract versions. New version = new row.
    # Identity: {counterparty, product_group, version}
    # ──────────────────────────────────────────────────────────

    create table(:contracts, primary_key: false) do
      add :id, :string, primary_key: true

      # Identity
      add :counterparty, :string, null: false
      add :counterparty_type, :string, null: false
      add :product_group, :string, null: false
      add :version, :integer, null: false
      add :status, :string, null: false, default: "draft"

      # Document
      add :source_file, :string
      add :source_format, :string
      add :file_hash, :string
      add :file_size, :bigint
      add :network_path, :string
      add :contract_number, :string
      add :family_id, :string

      # Graph API
      add :graph_item_id, :string
      add :graph_drive_id, :string

      # Commercial
      add :template_type, :string
      add :incoterm, :string
      add :term_type, :string
      add :company, :string
      add :contract_date, :date
      add :expiry_date, :date

      # SAP
      add :sap_contract_id, :string
      add :sap_validated, :boolean, default: false

      # Review
      add :reviewed_by, :string
      add :reviewed_at, :utc_datetime
      add :review_notes, :text

      # Clauses — full extracted clause data as JSONB
      add :clauses_data, :map, default: %{}

      # Validation results as JSONB
      add :template_validation, :map
      add :llm_validation, :map
      add :sap_discrepancies, {:array, :map}

      # Verification
      add :verification_status, :string
      add :last_verified_at, :utc_datetime
      add :previous_hash, :string

      # Position
      add :open_position, :float

      timestamps(type: :utc_datetime)
    end

    # Fast lookup by counterparty + product group
    create index(:contracts, [:counterparty, :product_group])
    create unique_index(:contracts, [:counterparty, :product_group, :version],
      name: :contracts_identity_idx)

    # Hash lookup for delta checks
    create index(:contracts, [:file_hash])

    # Graph API identity
    create index(:contracts, [:graph_item_id])

    # Status filtering
    create index(:contracts, [:product_group, :status])

    # ──────────────────────────────────────────────────────────
    # SOLVE AUDITS
    #
    # Immutable record of every solve execution.
    # Variables and results stored as JSONB.
    # Contracts linked via join table (references, not copies).
    # ──────────────────────────────────────────────────────────

    create table(:solve_audits, primary_key: false) do
      add :id, :string, primary_key: true

      # Identity
      add :mode, :string, null: false
      add :product_group, :string, null: false
      add :trader_id, :string
      add :trigger, :string

      # Variables snapshot (JSONB — exact values at solve time)
      add :variables, :map, null: false, default: %{}
      # API source timestamps (JSONB — when each source was last polled)
      add :variable_sources, :map, default: %{}

      # Contract check phase
      add :contracts_checked, :boolean, default: false
      add :contracts_stale, :boolean, default: false
      add :contracts_stale_reason, :string
      add :contracts_ingested, :integer, default: 0

      # Result (JSONB — full solve or monte carlo result)
      add :result_data, :map, default: %{}
      add :result_status, :string

      # Timeline
      add :started_at, :utc_datetime, null: false
      add :contracts_checked_at, :utc_datetime
      add :ingestion_completed_at, :utc_datetime
      add :solve_started_at, :utc_datetime
      add :completed_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    # Trader decision history (ordered by time)
    create index(:solve_audits, [:trader_id, :started_at])

    # Product group timeline (management view)
    create index(:solve_audits, [:product_group, :started_at])

    # Auto-runner vs trader comparison
    create index(:solve_audits, [:product_group, :trigger, :started_at])

    # Time range queries
    create index(:solve_audits, [:completed_at])

    # ──────────────────────────────────────────────────────────
    # SOLVE ↔ CONTRACT JOIN TABLE
    #
    # Which contract versions were active during each solve.
    # References — not copies. The contract row IS the data.
    # ──────────────────────────────────────────────────────────

    create table(:solve_audit_contracts) do
      add :solve_audit_id, references(:solve_audits, type: :string, on_delete: :delete_all),
        null: false
      add :contract_id, references(:contracts, type: :string, on_delete: :restrict),
        null: false

      # Denormalized for fast queries without joins
      add :counterparty, :string
      add :contract_version, :integer

      timestamps(type: :utc_datetime)
    end

    create index(:solve_audit_contracts, [:solve_audit_id])
    create index(:solve_audit_contracts, [:contract_id])
    create unique_index(:solve_audit_contracts, [:solve_audit_id, :contract_id])

    # ──────────────────────────────────────────────────────────
    # SCENARIOS
    #
    # Saved scenarios linked to their audit trail.
    # ──────────────────────────────────────────────────────────

    create table(:scenarios) do
      add :trader_id, :string, null: false
      add :name, :string, null: false
      add :variables, :map, default: %{}
      add :result_data, :map, default: %{}

      add :solve_audit_id, references(:solve_audits, type: :string, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create index(:scenarios, [:trader_id])
    create index(:scenarios, [:solve_audit_id])
  end
end
