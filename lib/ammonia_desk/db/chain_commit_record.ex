defmodule AmmoniaDesk.DB.ChainCommitRecord do
  @moduledoc """
  Ecto schema for chain commits — every auto-solve and trader commit on BSV.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  schema "chain_commits" do
    field :commit_type, :integer
    field :product_group, :string

    field :signer_type, :string
    field :signer_id, :string
    field :pubkey_hex, :string

    field :txid, :string
    field :raw_tx, :binary
    field :broadcast_at, :utc_datetime
    field :confirmed_at, :utc_datetime
    field :block_height, :integer

    field :payload_hash, :string
    field :signature_hex, :string
    field :encrypted_payload, :binary

    field :variables, :map, default: %{}
    field :variable_sources, :map, default: %{}

    field :result_data, :map, default: %{}
    field :result_status, :string

    field :triggered_mask, :integer, default: 0
    field :trigger_details, {:array, :map}, default: []

    field :solve_audit_id, :string

    timestamps(type: :utc_datetime)
  end

  @required [:id, :commit_type, :product_group, :signer_type]
  @optional [:signer_id, :pubkey_hex, :txid, :raw_tx, :broadcast_at, :confirmed_at,
             :block_height, :payload_hash, :signature_hex, :encrypted_payload,
             :variables, :variable_sources, :result_data, :result_status,
             :triggered_mask, :trigger_details, :solve_audit_id]

  def changeset(record, attrs) do
    record
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:commit_type, [1, 2, 3, 4, 5])
    |> validate_inclusion(:signer_type, ["trader", "server"])
  end

  @doc "Commit type constants."
  def type_solve_commit, do: 1
  def type_mc_commit, do: 2
  def type_auto_solve, do: 3
  def type_auto_mc, do: 4
  def type_config_change, do: 5
end
