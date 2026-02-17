defmodule TradingDesk.DB.ScenarioRecord do
  @moduledoc """
  Ecto schema for persisted scenarios.

  Links to the solve audit that produced the result, and to the
  contract versions that were active at the time.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "scenarios" do
    field :trader_id, :string
    field :name, :string
    field :variables, :map
    field :result_data, :map

    belongs_to :solve_audit, TradingDesk.DB.SolveAuditRecord, type: :string

    timestamps(type: :utc_datetime)
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [:trader_id, :name, :variables, :result_data, :solve_audit_id])
    |> validate_required([:trader_id, :name])
  end
end
