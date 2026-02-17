defmodule TradingDesk.DB.SolveAuditContract do
  @moduledoc """
  Join table: which contract versions were active during a solve.

  This links solve_audits to contracts by reference — no data duplication.
  Since contract records are immutable (new version = new row), the
  reference is stable: "solve X used contract Y at version 3" is permanent.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "solve_audit_contracts" do
    belongs_to :solve_audit, TradingDesk.DB.SolveAuditRecord, type: :string
    belongs_to :contract, TradingDesk.DB.ContractRecord, type: :string

    # Denormalized for fast queries without joins
    field :counterparty, :string
    field :contract_version, :integer

    timestamps(type: :utc_datetime)
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [:solve_audit_id, :contract_id, :counterparty, :contract_version])
    |> validate_required([:solve_audit_id, :contract_id])
  end
end
