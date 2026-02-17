defmodule TradingDesk.DB.SolveAuditRecord do
  @moduledoc """
  Ecto schema for persisted solve audit records.

  Every pipeline execution writes one row here. The row is immutable.
  Contracts are linked via the `solve_audit_contracts` join table —
  these are references to the actual contract rows, not snapshots.

  JSONB columns store:
    - variables: the full %Variables{} values at solve time
    - variable_sources: %{source => last_fetched_at} from API polling
    - result_data: the full Result or Distribution struct
    - contract_check: hash check outcome and ingestion details
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}

  schema "solve_audits" do
    # Identity
    field :mode, :string
    field :product_group, :string
    field :trader_id, :string
    field :trigger, :string

    # Variables (JSONB — exact values at solve time)
    field :variables, :map
    field :variable_sources, :map

    # Contract check phase
    field :contracts_checked, :boolean, default: false
    field :contracts_stale, :boolean, default: false
    field :contracts_stale_reason, :string
    field :contracts_ingested, :integer, default: 0

    # Result (JSONB — full solve or monte carlo result)
    field :result_data, :map
    field :result_status, :string

    # Timeline
    field :started_at, :utc_datetime
    field :contracts_checked_at, :utc_datetime
    field :ingestion_completed_at, :utc_datetime
    field :solve_started_at, :utc_datetime
    field :completed_at, :utc_datetime

    # Relationships
    has_many :contract_links, TradingDesk.DB.SolveAuditContract, foreign_key: :solve_audit_id
    has_many :contracts, through: [:contract_links, :contract]

    timestamps(type: :utc_datetime)
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [
      :id, :mode, :product_group, :trader_id, :trigger,
      :variables, :variable_sources,
      :contracts_checked, :contracts_stale, :contracts_stale_reason,
      :contracts_ingested,
      :result_data, :result_status,
      :started_at, :contracts_checked_at, :ingestion_completed_at,
      :solve_started_at, :completed_at
    ])
    |> validate_required([:id, :mode, :product_group, :started_at])
  end

  @doc "Convert an in-memory SolveAudit struct to DB attrs."
  def from_solve_audit(%TradingDesk.Solver.SolveAudit{} = a) do
    %{
      id: a.id,
      mode: to_string(a.mode),
      product_group: to_string(a.product_group),
      trader_id: a.trader_id,
      trigger: if(a.trigger, do: to_string(a.trigger)),
      variables: serialize_variables(a.variables),
      variable_sources: serialize_sources(a.variable_sources),
      contracts_checked: a.contracts_checked || false,
      contracts_stale: a.contracts_stale || false,
      contracts_stale_reason: if(a.contracts_stale_reason, do: inspect(a.contracts_stale_reason)),
      contracts_ingested: a.contracts_ingested || 0,
      result_data: serialize_result(a.result),
      result_status: if(a.result_status, do: to_string(a.result_status)),
      started_at: a.started_at,
      contracts_checked_at: a.contracts_checked_at,
      ingestion_completed_at: a.ingestion_completed_at,
      solve_started_at: a.solve_started_at,
      completed_at: a.completed_at
    }
  end

  defp serialize_variables(nil), do: %{}
  defp serialize_variables(%TradingDesk.Variables{} = v), do: Map.from_struct(v)
  defp serialize_variables(v) when is_map(v), do: v

  defp serialize_sources(nil), do: %{}
  defp serialize_sources(sources) when is_map(sources) do
    Map.new(sources, fn {k, v} ->
      {to_string(k), if(v, do: DateTime.to_iso8601(v))}
    end)
  end

  defp serialize_result(nil), do: %{}
  defp serialize_result(result) when is_struct(result), do: Map.from_struct(result)
  defp serialize_result(result) when is_map(result), do: result
end
