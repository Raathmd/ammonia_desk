defmodule TradingDesk.Contracts.LegalReview do
  @moduledoc """
  Legal review workflow for parsed contracts.

  A contract CANNOT be used in optimization until:
    1. All clauses have been reviewed by legal
    2. SAP cross-validation has passed (or discrepancies acknowledged)
    3. Legal explicitly approves the contract

  Workflow:
    draft → submit_for_review → pending_review → approve/reject
    rejected → submit_for_review (after corrections)

  Every transition is logged with reviewer identity and timestamp.
  """

  alias TradingDesk.Contracts.{Store, Contract}

  require Logger

  @doc """
  Submit a draft contract for legal review.
  Validates that the contract has been parsed and has extractable clauses.
  Returns {:ok, contract} or {:error, reason}.
  """
  def submit_for_review(contract_id) do
    with {:ok, contract} <- Store.get(contract_id),
         :ok <- validate_submittable(contract) do
      Store.update_status(contract_id, :pending_review)
    end
  end

  @doc """
  Legal approves a contract. Requires reviewer identity.
  The contract becomes the active version for its counterparty+product_group.
  Any previously active version is automatically superseded.

  Prerequisites:
    - Contract must be in :pending_review status
    - SAP validation must have been run
    - No unresolved :high-severity SAP discrepancies (unless force: true)
  """
  def approve(contract_id, reviewer_id, opts \\ []) do
    with {:ok, contract} <- Store.get(contract_id),
         :ok <- validate_approvable(contract, opts) do
      Store.update_status(contract_id, :approved,
        reviewed_by: reviewer_id,
        notes: Keyword.get(opts, :notes, "Approved")
      )
    end
  end

  @doc """
  Legal rejects a contract. Requires reviewer identity and reason.
  """
  def reject(contract_id, reviewer_id, reason) do
    with {:ok, contract} <- Store.get(contract_id),
         :ok <- validate_rejectable(contract) do
      Store.update_status(contract_id, :rejected,
        reviewed_by: reviewer_id,
        notes: reason
      )
    end
  end

  @doc """
  Returns a review summary for a contract: clause breakdown,
  confidence levels, SAP status, and any warnings.
  """
  def review_summary(contract_id) do
    with {:ok, contract} <- Store.get(contract_id) do
      clauses = contract.clauses || []

      summary = %{
        contract_id: contract.id,
        counterparty: contract.counterparty,
        product_group: contract.product_group,
        version: contract.version,
        status: contract.status,
        total_clauses: length(clauses),
        clause_breakdown: Contract.clause_counts(contract),
        confidence_breakdown: Enum.frequencies_by(clauses, & &1.confidence),
        low_confidence_clauses: Enum.filter(clauses, &(&1.confidence == :low)),
        sap_validated: contract.sap_validated,
        sap_discrepancies: contract.sap_discrepancies || [],
        expired: Contract.expired?(contract),
        has_open_position: not is_nil(contract.open_position),
        open_position: contract.open_position
      }

      {:ok, summary}
    end
  end

  # --- Validation ---

  defp validate_submittable(%Contract{status: :draft, clauses: clauses})
       when is_list(clauses) and length(clauses) > 0 do
    :ok
  end

  defp validate_submittable(%Contract{status: :rejected, clauses: clauses})
       when is_list(clauses) and length(clauses) > 0 do
    :ok
  end

  defp validate_submittable(%Contract{status: status}) when status != :draft and status != :rejected do
    {:error, {:cannot_submit, status}}
  end

  defp validate_submittable(%Contract{clauses: clauses})
       when is_nil(clauses) or clauses == [] do
    {:error, :no_clauses_extracted}
  end

  defp validate_approvable(%Contract{status: :pending_review} = contract, opts) do
    force = Keyword.get(opts, :force, false)

    cond do
      Contract.expired?(contract) ->
        {:error, :contract_expired}

      not contract.sap_validated and not force ->
        {:error, :sap_validation_required}

      has_critical_discrepancies?(contract) and not force ->
        {:error, {:unresolved_sap_discrepancies, contract.sap_discrepancies}}

      true ->
        :ok
    end
  end

  defp validate_approvable(%Contract{status: status}, _opts) do
    {:error, {:cannot_approve, status}}
  end

  defp validate_rejectable(%Contract{status: :pending_review}), do: :ok
  defp validate_rejectable(%Contract{status: status}) do
    {:error, {:cannot_reject, status}}
  end

  defp has_critical_discrepancies?(%Contract{sap_discrepancies: nil}), do: false
  defp has_critical_discrepancies?(%Contract{sap_discrepancies: []}), do: false
  defp has_critical_discrepancies?(%Contract{sap_discrepancies: discrepancies}) do
    Enum.any?(discrepancies, fn d ->
      Map.get(d, :severity, :low) == :high
    end)
  end
end
