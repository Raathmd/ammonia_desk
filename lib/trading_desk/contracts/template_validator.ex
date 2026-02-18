defmodule TradingDesk.Contracts.TemplateValidator do
  @moduledoc """
  Validates extracted contract clauses against canonical template requirements.

  After the parser extracts clauses from a document, this module checks
  whether the extraction is COMPLETE relative to the contract's family template.

  Four levels of findings:
    :missing_required  — blocks progression past draft. Cannot submit for review.
    :missing_expected  — generates warnings. Legal must acknowledge before approval.
    :low_confidence    — clause was found but extraction confidence is low.
    :value_suspicious  — extracted value is outside normal ranges.

  This module now works with canonical clause IDs and family signatures
  from the TemplateRegistry, rather than the old contract_type + incoterm system.
  """

  alias TradingDesk.Contracts.{Contract, TemplateRegistry}
  alias TradingDesk.ProductGroup

  require Logger

  @type finding :: %{
    level: :missing_required | :missing_expected | :low_confidence | :value_suspicious,
    clause_id: String.t() | nil,
    clause_type: atom(),
    parameter_class: atom() | nil,
    message: String.t()
  }

  @type validation_result :: %{
    contract_id: String.t(),
    family_id: String.t() | nil,
    findings: [finding()],
    required_met: non_neg_integer(),
    required_total: non_neg_integer(),
    expected_met: non_neg_integer(),
    expected_total: non_neg_integer(),
    completeness_pct: float(),
    coverage: %{String.t() => boolean()},
    blocks_submission: boolean(),
    validated_at: DateTime.t()
  }

  # Fallback value ranges for sanity checks when no frame is available
  @fallback_value_ranges %{
    total_volume: {100.0, 500_000.0},
    contract_price: {50.0, 2000.0},
    working_cap: {10_000.0, 50_000_000.0}
  }

  # Build value ranges dynamically from a product group's frame
  defp value_ranges_for(product_group) do
    frame_vars = ProductGroup.variables(product_group)

    if frame_vars == [] do
      @fallback_value_ranges
    else
      frame_ranges =
        Map.new(frame_vars, fn v ->
          {v[:key], {v[:min] * 1.0, v[:max] * 1.0}}
        end)

      Map.merge(@fallback_value_ranges, frame_ranges)
    end
  end

  @doc """
  Validate a contract against its family template.

  The contract should have a family_id set (from auto-detection or manual selection).
  Falls back to inferring family from template_type + incoterm if no family_id.
  """
  @spec validate(Contract.t()) :: {:ok, validation_result()} | {:error, term()}
  def validate(%Contract{} = contract) do
    family_id = resolve_family_id(contract)

    if is_nil(family_id) do
      {:error, :no_template_type}
    else
      reqs = TemplateRegistry.family_requirements(family_id)

      if length(reqs) == 0 do
        {:error, :unknown_template}
      else
        clauses = contract.clauses || []
        extracted_ids = clauses |> Enum.map(& &1.clause_id) |> Enum.reject(&is_nil/1) |> MapSet.new()
        pg = contract.product_group || :ammonia_domestic

        findings =
          []
          |> check_coverage(reqs, extracted_ids)
          |> check_low_confidence(clauses)
          |> check_value_ranges(clauses, pg)
          |> check_duplicate_conflicts(clauses)

        required_reqs = Enum.filter(reqs, &(&1.level == :required))
        expected_reqs = Enum.filter(reqs, &(&1.level == :expected))

        missing_required = Enum.count(findings, &(&1.level == :missing_required))
        missing_expected = Enum.count(findings, &(&1.level == :missing_expected))

        required_met = length(required_reqs) - missing_required
        expected_met = length(expected_reqs) - missing_expected

        total = length(reqs)
        met = total - missing_required - missing_expected
        completeness = if total > 0, do: Float.round(met / total * 100, 1), else: 100.0

        coverage =
          Enum.into(reqs, %{}, fn req ->
            {req.clause_id, MapSet.member?(extracted_ids, req.clause_id)}
          end)

        result = %{
          contract_id: contract.id,
          family_id: family_id,
          findings: findings,
          required_met: required_met,
          required_total: length(required_reqs),
          expected_met: expected_met,
          expected_total: length(expected_reqs),
          completeness_pct: completeness,
          coverage: coverage,
          blocks_submission: missing_required > 0,
          validated_at: DateTime.utc_now()
        }

        {:ok, result}
      end
    end
  end

  @doc """
  Quick check: can this contract be submitted for review?
  """
  @spec submission_ready?(Contract.t()) :: boolean()
  def submission_ready?(%Contract{} = contract) do
    case validate(contract) do
      {:ok, result} -> not result.blocks_submission
      _ -> false
    end
  end

  @doc """
  Get a human-readable completeness summary for display.
  """
  @spec summary(Contract.t()) :: {:ok, map()} | {:error, term()}
  def summary(%Contract{} = contract) do
    case validate(contract) do
      {:ok, result} ->
        {:ok, %{
          family_id: result.family_id,
          completeness_pct: result.completeness_pct,
          required: "#{result.required_met}/#{result.required_total}",
          expected: "#{result.expected_met}/#{result.expected_total}",
          blocks: result.blocks_submission,
          coverage: result.coverage,
          missing_required: Enum.filter(result.findings, &(&1.level == :missing_required)),
          missing_expected: Enum.filter(result.findings, &(&1.level == :missing_expected)),
          low_confidence: Enum.filter(result.findings, &(&1.level == :low_confidence)),
          suspicious_values: Enum.filter(result.findings, &(&1.level == :value_suspicious))
        }}
      error -> error
    end
  end

  # --- Checks ---

  defp check_coverage(findings, reqs, extracted_ids) do
    Enum.reduce(reqs, findings, fn req, acc ->
      if MapSet.member?(extracted_ids, req.clause_id) do
        acc
      else
        level = if req.level == :required, do: :missing_required, else: :missing_expected
        label = if req.level == :required, do: "REQUIRED", else: "EXPECTED"

        [%{
          level: level,
          clause_id: req.clause_id,
          clause_type: nil,
          parameter_class: nil,
          message: "#{label}: #{req.clause_id} — not found in extraction"
        } | acc]
      end
    end)
  end

  defp check_low_confidence(findings, clauses) do
    low_conf = Enum.filter(clauses, &(&1.confidence == :low))

    Enum.reduce(low_conf, findings, fn clause, acc ->
      [%{
        level: :low_confidence,
        clause_id: clause.clause_id,
        clause_type: clause.type,
        parameter_class: clause.parameter,
        message: "Low confidence extraction: #{clause.clause_id} (section #{clause.reference_section})"
      } | acc]
    end)
  end

  defp check_value_ranges(findings, clauses, product_group) do
    ranges = value_ranges_for(product_group)

    Enum.reduce(clauses, findings, fn clause, acc ->
      case Map.get(ranges, clause.parameter) do
        {min, max} when is_number(clause.value) ->
          cond do
            clause.value < min * 0.1 ->
              [%{
                level: :value_suspicious,
                clause_id: clause.clause_id,
                clause_type: clause.type,
                parameter_class: clause.parameter,
                message: "Value #{clause.value} for #{clause.parameter} is far below " <>
                         "normal range (#{min}-#{max})"
              } | acc]

            clause.value > max * 10 ->
              [%{
                level: :value_suspicious,
                clause_id: clause.clause_id,
                clause_type: clause.type,
                parameter_class: clause.parameter,
                message: "Value #{clause.value} for #{clause.parameter} is far above " <>
                         "normal range (#{min}-#{max})"
              } | acc]

            true -> acc
          end

        _ -> acc
      end
    end)
  end

  defp check_duplicate_conflicts(findings, clauses) do
    by_param = clauses |> Enum.filter(& &1.parameter) |> Enum.group_by(& &1.parameter)

    Enum.reduce(by_param, findings, fn {param, group}, acc ->
      if length(group) < 2 do
        acc
      else
        mins = Enum.filter(group, &(&1.operator == :>=)) |> Enum.map(& &1.value) |> Enum.reject(&is_nil/1)
        maxs = Enum.filter(group, &(&1.operator == :<=)) |> Enum.map(& &1.value) |> Enum.reject(&is_nil/1)

        if length(mins) > 0 and length(maxs) > 0 and Enum.max(mins) > Enum.min(maxs) do
          [%{
            level: :value_suspicious,
            clause_id: nil,
            clause_type: :conflict,
            parameter_class: param,
            message: "Conflicting bounds for #{param}: min #{Enum.max(mins)} > max #{Enum.min(maxs)}"
          } | acc]
        else
          acc
        end
      end
    end)
  end

  defp resolve_family_id(%Contract{} = contract) do
    cond do
      is_binary(Map.get(contract, :family_id)) ->
        contract.family_id

      not is_nil(contract.template_type) ->
        case {contract.template_type, contract.incoterm} do
          {:purchase, ic} when ic in [:fob, :cfr] -> "VESSEL_SPOT_PURCHASE"
          {:spot_purchase, _} -> "VESSEL_SPOT_PURCHASE"
          {:sale, ic} when ic in [:fob, :cfr, :cif] -> "VESSEL_SPOT_SALE"
          {:spot_sale, ic} when ic in [:fob, :cfr, :cif] -> "VESSEL_SPOT_SALE"
          {:sale, ic} when ic in [:dap, :ddp] -> "VESSEL_SPOT_DAP"
          {:spot_sale, ic} when ic in [:dap, :ddp] -> "VESSEL_SPOT_DAP"
          {:sale, :cpt} -> "DOMESTIC_CPT_TRUCKS"
          {:spot_sale, :cpt} -> "DOMESTIC_CPT_TRUCKS"
          _ -> "VESSEL_SPOT_PURCHASE"
        end

      true ->
        nil
    end
  end
end
