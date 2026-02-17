defmodule AmmoniaDesk.Repo.Migrations.CreateDeltaConfigsAndChainCommits do
  use Ecto.Migration

  def change do
    # ──────────────────────────────────────────────────────────
    # DELTA CONFIGS
    #
    # Admin-configurable per-product-group settings:
    #   - Poll intervals per API source
    #   - Delta thresholds per variable
    #   - Cooldown and Monte Carlo settings
    # ──────────────────────────────────────────────────────────

    create table(:delta_configs, primary_key: false) do
      add :product_group, :string, primary_key: true

      add :enabled, :boolean, default: false, null: false
      add :poll_intervals, :map, default: %{}, null: false
      add :thresholds, :map, default: %{}, null: false
      add :min_solve_interval_ms, :integer, default: 300_000, null: false
      add :n_scenarios, :integer, default: 1000, null: false

      timestamps(type: :utc_datetime)
    end

    # ──────────────────────────────────────────────────────────
    # CHAIN COMMITS
    #
    # Every auto-solve and trader commit stored on BSV chain.
    # Full payload data — BSV tx costs are negligible.
    # ──────────────────────────────────────────────────────────

    create table(:chain_commits, primary_key: false) do
      add :id, :string, primary_key: true  # txid or internal ID

      # Type: 0x01=SOLVE_COMMIT, 0x02=MC_COMMIT, 0x03=AUTO_SOLVE,
      #        0x04=AUTO_MC, 0x05=CONFIG_CHANGE
      add :commit_type, :integer, null: false
      add :product_group, :string, null: false

      # Signer
      add :signer_type, :string, null: false  # "trader" or "server"
      add :signer_id, :string                 # trader email or "system"
      add :pubkey_hex, :string                # signer's BSV public key

      # BSV transaction
      add :txid, :string                      # BSV transaction ID
      add :raw_tx, :binary                    # full raw transaction bytes
      add :broadcast_at, :utc_datetime
      add :confirmed_at, :utc_datetime
      add :block_height, :integer

      # Payload
      add :payload_hash, :string              # SHA-256 of canonical payload
      add :signature_hex, :string             # ECDSA signature
      add :encrypted_payload, :binary         # AES-256-GCM encrypted payload

      # Variables snapshot (JSONB — full solver inputs)
      add :variables, :map, default: %{}
      add :variable_sources, :map, default: %{}

      # Result snapshot (JSONB)
      add :result_data, :map, default: %{}
      add :result_status, :string

      # Trigger info (for auto-solve types)
      add :triggered_mask, :integer, default: 0     # u32 bitmask
      add :trigger_details, {:array, :map}, default: []  # per-variable deltas

      # Link to solve audit
      add :solve_audit_id, references(:solve_audits, type: :string, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create index(:chain_commits, [:product_group, :inserted_at])
    create index(:chain_commits, [:commit_type, :inserted_at])
    create index(:chain_commits, [:signer_id, :inserted_at])
    create index(:chain_commits, [:txid])
    create index(:chain_commits, [:solve_audit_id])
    create index(:chain_commits, [:block_height])

    # ──────────────────────────────────────────────────────────
    # CONFIG CHANGE AUDIT
    #
    # Every admin config change recorded for audit trail.
    # ──────────────────────────────────────────────────────────

    create table(:config_change_log) do
      add :product_group, :string, null: false
      add :admin_id, :string
      add :field, :string, null: false
      add :old_value, :map
      add :new_value, :map

      # Optional chain commit link
      add :chain_commit_id, references(:chain_commits, type: :string, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create index(:config_change_log, [:product_group, :inserted_at])
  end
end
