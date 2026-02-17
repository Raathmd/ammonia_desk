defmodule AmmoniaDesk.DB.DeltaConfigRecord do
  @moduledoc """
  Ecto schema for persisting DeltaConfig per product group.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:product_group, :string, autogenerate: false}
  schema "delta_configs" do
    field :enabled, :boolean, default: false
    field :poll_intervals, :map, default: %{}
    field :thresholds, :map, default: %{}
    field :min_solve_interval_ms, :integer, default: 300_000
    field :n_scenarios, :integer, default: 1000

    timestamps(type: :utc_datetime)
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [:product_group, :enabled, :poll_intervals, :thresholds,
                     :min_solve_interval_ms, :n_scenarios])
    |> validate_required([:product_group])
    |> validate_number(:min_solve_interval_ms, greater_than: 0)
    |> validate_number(:n_scenarios, greater_than: 0)
  end
end
