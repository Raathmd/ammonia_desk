defmodule AmmoniaDesk.Contracts.TemplateValidator do
  @moduledoc """
  Validates extracted contract clauses against template requirements.

  After the parser extracts clauses from a document, this module checks
  whether the extraction is COMPLETE relative to the contract's template.

  Three levels of findings:
    :missing_required  — blocks progression past draft. Cannot submit for review.
    :missing_expected  — generates warnings. Legal must acknowledge before approval.
    :low_confidence    — clause was found but extraction confidence is low.
    :value_suspicious  — extracted value is outside normal ranges.

  This is the first quality gate. It runs synchronously after parsing
  and its results are stored on the contract for display in all role views.
  """

  alias AmmoniaDesk.Contracts.{Contract, TemplateRegistry}

  require Logger

  @type finding :: %{
    level: :missing_required | :missing_expected | :low_confidence | :value_suspicious,
    clause_type: atom(),
    parameter_class: atom() | nil,
    message: String.t()
  }

  @type validation_result :: %{
    contract_id: String.t(),
    template_type: atom(),
    incoterm: atom() | nil,
    findings: [finding()],
    required_met: non_neg_integer(),
    required_total: non_neg_integer(),
    expected_met: non_neg_integer(),
    expected_total: non_neg_integer(),
    completeness_pct: float(),
    blocks_submission: boolean(),
    validated_at: DateTime.t()
  }

  # Normal value ranges for sanity checks
  @value_ranges %{
    nola_buy: {100.0, 1200.0},
    sell_stl: {100.0, 1500.0},
    sell_mem: {100.0, 1500.0},
    fr_don_stl: {5.0, 200.0},
    fr_don_mem: {5.0, 200.0},
    fr_geis_stl: {5.0, 200.0},
    fr_geis_mem: {5.0, 200.0},
    inv_don: {100.0, 100_000.0},
    inv_geis: {100.0, 100_000.0},
    barge_count: {1.0, 50.0},
    working_cap: {10_000.0, 50_000_000.0},
    nat_gas: {1.0, 20.0}
  }

  @doc """
  Validate a contract against its template.

  The contract must have template_type set. If incoterm is nil,
  uses the base template for that contract type.

  Returns a validation_result with findings and completeness metrics.
  """
  @spec validate(Contract.t()) :: {:ok, validation_result()} | {:error, term()}
  def validate(%Contract{} = contract) do
    ct = contract.template_type
    ic = contract.incoterm

    if is_nil(ct) do
      {:error, :no_template_type}
    else
      case TemplateRegistry.get_template(ct, ic) do
        {:ok, template} ->
          findings = run_checks(contract, template)

          required_reqs = Enum.filter(template.clause_requirements, &(&1.level == :required))
          expected_reqs = Enum.filter(template.clause_requirements, &(&1.level in [:required, :expected]))

          missing_required = Enum.count(findings, &(&1.level == :missing_required))
          missing_expected = Enum.count(findings, &(&1.level == :missing_expected))

          required_met = length(required_reqs) - missing_required
          expected_met = length(expected_reqs) - missing_required - missing_expected

          total = length(template.clause_requirements)
          met = total - missing_required - missing_expected
          completeness = if total > 0, do: Float.round(met / total * 100, 1), else: 100.0

          result = %{
            contract_id: contract.id,
            template_type: ct,
            incoterm: ic,
            findings: findings,
            required_met: required_met,
            required_total: length(required_reqs),
            expected_met: expected_met,
            expected_total: length(expected_reqs),
            completeness_pct: completeness,
            blocks_submission: missing_required > 0,
            validated_at: DateTime.utc_now()
          }

          {:ok, result}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Quick check: can this contract be submitted for review?
  Returns true only if all required clauses are present.
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
          completeness_pct: result.completeness_pct,
          required: "#{result.required_met}/#{result.required_total}",
          expected: "#{result.expected_met}/#{result.expected_total}",
          blocks: result.blocks_submission,
          missing_required: Enum.filter(result.findings, &(&1.level == :missing_required)),
          missing_expected: Enum.filter(result.findings, &(&1.level == :missing_expected)),
          low_confidence: Enum.filter(result.findings, &(&1.level == :low_confidence)),
          suspicious_values: Enum.filter(result.findings, &(&1.level == :value_suspicious))
        }}
      error -> error
    end
  end

  # --- Checks ---

  defp run_checks(contract, template) do
    clauses = contract.clauses || []

    []
    |> check_required(clauses, template)
    |> check_expected(clauses, template)
    |> check_low_confidence(clauses)
    |> check_value_ranges(clauses)
    |> check_duplicate_conflicts(clauses)
  end

  # Check that every required clause type+parameter_class is present
  defp check_required(findings, clauses, template) do
    required = Enum.filter(template.clause_requirements, &(&1.level == :required))

    Enum.reduce(required, findings, fn req, acc ->
      if clause_matches_requirement?(clauses, req) do
        acc
      else
        [%{
          level: :missing_required,
          clause_type: req.clause_type,
          parameter_class: req.parameter_class,
          message: "REQUIRED: #{req.description} — not found in extraction"
        } | acc]
      end
    end)
  end

  # Check expected (non-required) clauses
  defp check_expected(findings, clauses, template) do
    expected = Enum.filter(template.clause_requirements, &(&1.level == :expected))

    Enum.reduce(expected, findings, fn req, acc ->
      if clause_matches_requirement?(clauses, req) do
        acc
      else
        [%{
          level: :missing_expected,
          clause_type: req.clause_type,
          parameter_class: req.parameter_class,
          message: "EXPECTED: #{req.description} — not found in extraction"
        } | acc]
      end
    end)
  end

  # Flag any clause with :low confidence
  defp check_low_confidence(findings, clauses) do
    low_conf = Enum.filter(clauses, &(&1.confidence == :low))

    Enum.reduce(low_conf, findings, fn clause, acc ->
      [%{
        level: :low_confidence,
        clause_type: clause.type,
        parameter_class: clause.parameter,
        message: "Low confidence extraction: #{clause.type} / #{clause.parameter} " <>
                 "(section #{clause.reference_section})"
      } | acc]
    end)
  end

  # Check extracted values against normal ranges
  defp check_value_ranges(findings, clauses) do
    Enum.reduce(clauses, findings, fn clause, acc ->
      case Map.get(@value_ranges, clause.parameter) do
        {min, max} when is_number(clause.value) ->
          cond do
            clause.value < min * 0.1 ->
              [%{
                level: :value_suspicious,
                clause_type: clause.type,
                parameter_class: clause.parameter,
                message: "Value #{clause.value} for #{clause.parameter} is far below " <>
                         "normal range (#{min}-#{max})"
              } | acc]

            clause.value > max * 10 ->
              [%{
                level: :value_suspicious,
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

  # Check for conflicting clauses (same parameter, contradictory operators)
  defp check_duplicate_conflicts(findings, clauses) do
    by_param = Enum.group_by(clauses, & &1.parameter)

    Enum.reduce(by_param, findings, fn {param, group}, acc ->
      if is_nil(param) or length(group) < 2 do
        acc
      else
        mins = Enum.filter(group, &(&1.operator == :>=)) |> Enum.map(& &1.value) |> Enum.reject(&is_nil/1)
        maxs = Enum.filter(group, &(&1.operator == :<=)) |> Enum.map(& &1.value) |> Enum.reject(&is_nil/1)

        if length(mins) > 0 and length(maxs) > 0 do
          if Enum.max(mins) > Enum.min(maxs) do
            [%{
              level: :value_suspicious,
              clause_type: :conflict,
              parameter_class: param,
              message: "Conflicting bounds for #{param}: min #{Enum.max(mins)} > max #{Enum.min(maxs)}"
            } | acc]
          else
            acc
          end
        else
          acc
        end
      end
    end)
  end

  # Does any extracted clause satisfy this template requirement?
  defp clause_matches_requirement?(clauses, requirement) do
    param_members = TemplateRegistry.parameter_class_members(requirement.parameter_class)

    Enum.any?(clauses, fn clause ->
      clause.type == requirement.clause_type and
        (is_nil(requirement.parameter_class) or
         clause.parameter in param_members or
         clause.parameter == requirement.parameter_class)
    end)
  end
end
