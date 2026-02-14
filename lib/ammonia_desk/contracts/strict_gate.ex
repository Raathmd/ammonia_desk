defmodule AmmoniaDesk.Contracts.StrictGate do
  @moduledoc """
  Multi-stage gate system with hard blocks at every transition.

  This replaces ad-hoc checks scattered across the pipeline with a
  single, auditable gate system. Every contract status transition
  must pass through a gate. Every product-group-level operation
  (optimization, constraint application) must pass a master gate.

  Gate hierarchy (each gate includes all checks from previous gates):

    GATE 1: EXTRACTION COMPLETE
      - Document was successfully read
      - Parser produced at least 1 clause
      - Template validation ran and all REQUIRED clauses present
      - No extraction errors (not warnings — errors only)
      → Allows: submit for legal review

    GATE 2: REVIEW READY
      - Gate 1 passed
      - LLM validation ran (if available) with no :error findings
      - All low-confidence clauses have been acknowledged
      - SAP validation ran with no high-severity discrepancies
      → Allows: legal approval

    GATE 3: APPROVED & VALIDATED
      - Gate 2 passed
      - Legal has approved (status == :approved)
      - Open position loaded from SAP
      - Contract not expired
      → Allows: activation for optimization

    GATE 4: PRODUCT GROUP READY (master gate)
      - Every counterparty has a Gate 3-passing contract
      - All currency timestamps within thresholds
      - All external APIs fresh
      - Full product group refresh ran within threshold
      → Allows: constraint application, optimization

  Each gate returns {:pass, details} or {:fail, blocking_reasons, details}.
  Blocking reasons are specific and actionable.
  """

  alias AmmoniaDesk.Contracts.{
    Contract,
    Store,
    TemplateValidator,
    CurrencyTracker,
    LlmValidator
  }

  require Logger

  @type gate_result :: {:pass, map()} | {:fail, [blocker()], map()}
  @type blocker :: %{gate: atom(), code: atom(), message: String.t(), details: term()}

  # ──────────────────────────────────────────────────────────
  # GATE 1: EXTRACTION COMPLETE
  # ──────────────────────────────────────────────────────────

  @doc """
  Can this contract be submitted for legal review?
  Checks extraction completeness against template.
  """
  @spec gate_extraction(Contract.t()) :: gate_result()
  def gate_extraction(%Contract{} = contract) do
    blockers = []
    |> check_has_clauses(contract)
    |> check_template_assigned(contract)
    |> check_template_required(contract)
    |> check_no_extraction_errors(contract)

    details = %{
      contract_id: contract.id,
      clause_count: length(contract.clauses || []),
      template_type: contract.template_type,
      incoterm: contract.incoterm,
      checked_at: DateTime.utc_now()
    }

    if Enum.empty?(blockers) do
      {:pass, details}
    else
      {:fail, blockers, details}
    end
  end

  defp check_has_clauses(blockers, contract) do
    if is_nil(contract.clauses) or Enum.empty?(contract.clauses) do
      [%{gate: :extraction, code: :no_clauses,
         message: "No clauses extracted from document",
         details: contract.source_file} | blockers]
    else
      blockers
    end
  end

  defp check_template_assigned(blockers, contract) do
    if is_nil(contract.template_type) do
      [%{gate: :extraction, code: :no_template,
         message: "Contract type (template) not assigned — select purchase/sale/spot",
         details: nil} | blockers]
    else
      blockers
    end
  end

  defp check_template_required(blockers, contract) do
    if is_nil(contract.template_type) do
      blockers
    else
      case TemplateValidator.validate(contract) do
        {:ok, result} ->
          if result.blocks_submission do
            missing = Enum.filter(result.findings, &(&1.level == :missing_required))
            Enum.reduce(missing, blockers, fn finding, acc ->
              [%{gate: :extraction, code: :missing_required_clause,
                 message: finding.message,
                 details: {finding.clause_type, finding.parameter_class}} | acc]
            end)
          else
            blockers
          end

        {:error, reason} ->
          [%{gate: :extraction, code: :template_validation_failed,
             message: "Template validation failed: #{inspect(reason)}",
             details: reason} | blockers]
      end
    end
  end

  defp check_no_extraction_errors(blockers, contract) do
    # Check for value conflicts and suspiciously wrong values
    case TemplateValidator.validate(contract) do
      {:ok, result} ->
        suspicious = Enum.filter(result.findings, fn f ->
          f.level == :value_suspicious and
            String.contains?(f.message, "Conflicting")
        end)

        Enum.reduce(suspicious, blockers, fn finding, acc ->
          [%{gate: :extraction, code: :conflicting_values,
             message: finding.message,
             details: finding.parameter_class} | acc]
        end)

      _ -> blockers
    end
  end

  # ──────────────────────────────────────────────────────────
  # GATE 2: REVIEW READY
  # ──────────────────────────────────────────────────────────

  @doc """
  Can legal approve this contract?
  Gate 1 + LLM validation + SAP check.
  """
  @spec gate_review(Contract.t()) :: gate_result()
  def gate_review(%Contract{} = contract) do
    # Gate 1 must pass first
    case gate_extraction(contract) do
      {:fail, blockers, details} ->
        {:fail, blockers, Map.put(details, :gate1_failed, true)}

      {:pass, _} ->
        blockers = []
        |> check_llm_validation(contract)
        |> check_low_confidence_acknowledged(contract)
        |> check_sap_no_high_severity(contract)

        details = %{
          contract_id: contract.id,
          sap_validated: contract.sap_validated,
          discrepancy_count: length(contract.sap_discrepancies || []),
          checked_at: DateTime.utc_now()
        }

        if Enum.empty?(blockers) do
          {:pass, details}
        else
          {:fail, blockers, details}
        end
    end
  end

  defp check_llm_validation(blockers, contract) do
    # Only block if LLM is available AND found errors
    if LlmValidator.available?() do
      case LlmValidator.validate(contract.id) do
        {:ok, %{errors: error_count}} when error_count > 0 ->
          [%{gate: :review, code: :llm_errors,
             message: "LLM validation found #{error_count} error(s) — review before approval",
             details: error_count} | blockers]
        _ -> blockers
      end
    else
      # LLM not available — don't block, but note it
      blockers
    end
  end

  defp check_low_confidence_acknowledged(blockers, contract) do
    low_conf = Enum.filter(contract.clauses || [], &(&1.confidence == :low))

    if length(low_conf) > 0 and is_nil(contract.review_notes) do
      [%{gate: :review, code: :unacknowledged_low_confidence,
         message: "#{length(low_conf)} low-confidence clause(s) require reviewer acknowledgment",
         details: Enum.map(low_conf, & &1.id)} | blockers]
    else
      blockers
    end
  end

  defp check_sap_no_high_severity(blockers, contract) do
    high_severity =
      (contract.sap_discrepancies || [])
      |> Enum.filter(fn d -> d.severity == :high end)

    if length(high_severity) > 0 do
      [%{gate: :review, code: :sap_high_severity_discrepancies,
         message: "#{length(high_severity)} high-severity SAP discrepancy(ies) unresolved",
         details: Enum.map(high_severity, & &1.field)} | blockers]
    else
      blockers
    end
  end

  # ──────────────────────────────────────────────────────────
  # GATE 3: APPROVED & VALIDATED
  # ──────────────────────────────────────────────────────────

  @doc """
  Can this contract be activated for optimization?
  Gate 2 + legal approval + position + expiry.
  """
  @spec gate_activation(Contract.t()) :: gate_result()
  def gate_activation(%Contract{} = contract) do
    case gate_review(contract) do
      {:fail, blockers, details} ->
        {:fail, blockers, Map.put(details, :gate2_failed, true)}

      {:pass, _} ->
        blockers = []
        |> check_approved(contract)
        |> check_position_loaded(contract)
        |> check_not_expired(contract)
        |> check_currency(contract)

        details = %{
          contract_id: contract.id,
          status: contract.status,
          open_position: contract.open_position,
          expired: Contract.expired?(contract),
          checked_at: DateTime.utc_now()
        }

        if Enum.empty?(blockers) do
          {:pass, details}
        else
          {:fail, blockers, details}
        end
    end
  end

  defp check_approved(blockers, contract) do
    if contract.status != :approved do
      [%{gate: :activation, code: :not_approved,
         message: "Contract status is #{contract.status}, must be :approved",
         details: contract.status} | blockers]
    else
      blockers
    end
  end

  defp check_position_loaded(blockers, contract) do
    if is_nil(contract.open_position) do
      [%{gate: :activation, code: :no_position,
         message: "Open position not loaded from SAP for #{contract.counterparty}",
         details: nil} | blockers]
    else
      blockers
    end
  end

  defp check_not_expired(blockers, contract) do
    if Contract.expired?(contract) do
      [%{gate: :activation, code: :expired,
         message: "Contract expired on #{contract.expiry_date}",
         details: contract.expiry_date} | blockers]
    else
      blockers
    end
  end

  defp check_currency(blockers, contract) do
    stale = CurrencyTracker.stale_events(contract.id)

    # Only block on critical staleness: SAP and positions
    critical_stale = Enum.filter(stale, fn s ->
      s.event in [:sap_validated_at, :position_refreshed_at]
    end)

    Enum.reduce(critical_stale, blockers, fn s, acc ->
      [%{gate: :activation, code: :stale_data,
         message: "#{s.event} is stale (#{s.age_minutes || "never"}min, max #{s.max_age_minutes}min)",
         details: s} | acc]
    end)
  end

  # ──────────────────────────────────────────────────────────
  # GATE 4: PRODUCT GROUP MASTER GATE
  # ──────────────────────────────────────────────────────────

  @doc """
  Can we optimize for this product group?
  All counterparties must have Gate 3-passing contracts +
  currency + API freshness.
  """
  @spec gate_product_group(atom()) :: gate_result()
  def gate_product_group(product_group) do
    all_contracts = Store.list_by_product_group(product_group)
    active_contracts = Store.get_active_set(product_group)
    api_timestamps = AmmoniaDesk.Data.LiveState.last_updated()
    now = DateTime.utc_now()

    blockers = []
    |> check_pg_has_contracts(product_group, all_contracts)
    |> check_pg_all_counterparties_covered(all_contracts, active_contracts)
    |> check_pg_all_gates_pass(active_contracts)
    |> check_pg_currency(product_group)
    |> check_pg_api_freshness(api_timestamps, now)

    total_counterparties =
      all_contracts |> Enum.map(& &1.counterparty) |> Enum.uniq() |> length()

    active_passing =
      active_contracts
      |> Enum.count(fn c ->
        case gate_activation(c) do
          {:pass, _} -> true
          _ -> false
        end
      end)

    details = %{
      product_group: product_group,
      total_contracts: length(all_contracts),
      active_contracts: length(active_contracts),
      total_counterparties: total_counterparties,
      active_passing_gate3: active_passing,
      checked_at: now
    }

    if Enum.empty?(blockers) do
      Logger.info("Product group #{product_group} PASSED master gate (Gate 4)")
      {:pass, details}
    else
      Logger.warning(
        "Product group #{product_group} FAILED master gate: " <>
        "#{length(blockers)} blocker(s)"
      )
      {:fail, blockers, details}
    end
  end

  defp check_pg_has_contracts(blockers, product_group, all_contracts) do
    if Enum.empty?(all_contracts) do
      [%{gate: :product_group, code: :no_contracts,
         message: "No contracts in product group #{product_group}",
         details: nil} | blockers]
    else
      blockers
    end
  end

  defp check_pg_all_counterparties_covered(blockers, all_contracts, active_contracts) do
    all_cps = all_contracts |> Enum.map(& &1.counterparty) |> Enum.uniq()
    active_cps = active_contracts |> Enum.map(& &1.counterparty) |> Enum.uniq()
    missing = all_cps -- active_cps

    if length(missing) > 0 do
      [%{gate: :product_group, code: :counterparties_without_active,
         message: "#{length(missing)} counterparty(ies) without active (approved) contract: #{Enum.join(missing, ", ")}",
         details: missing} | blockers]
    else
      blockers
    end
  end

  defp check_pg_all_gates_pass(blockers, active_contracts) do
    failing =
      active_contracts
      |> Enum.reject(fn c ->
        case gate_activation(c) do
          {:pass, _} -> true
          _ -> false
        end
      end)

    Enum.reduce(failing, blockers, fn c, acc ->
      {:fail, contract_blockers, _} = gate_activation(c)
      first_blocker = List.first(contract_blockers)

      [%{gate: :product_group, code: :contract_gate_failed,
         message: "#{c.counterparty} v#{c.version} fails Gate 3: #{first_blocker.message}",
         details: %{counterparty: c.counterparty, contract_id: c.id,
                    blocker_count: length(contract_blockers)}} | acc]
    end)
  end

  defp check_pg_currency(blockers, product_group) do
    if CurrencyTracker.product_group_current?(product_group) do
      blockers
    else
      staleness = CurrencyTracker.product_group_staleness(product_group)

      stale_contracts =
        staleness.contracts
        |> Enum.reject(fn {_id, stale} -> Enum.empty?(stale) end)

      if length(stale_contracts) > 0 do
        [%{gate: :product_group, code: :stale_contracts,
           message: "#{length(stale_contracts)} contract(s) have stale data — re-run validation pipeline",
           details: Enum.map(stale_contracts, fn {id, stale} -> {id, stale} end)} | blockers]
      else
        blockers
      end
    end
  end

  @api_freshness %{
    usgs: 20,
    noaa: 35,
    usace: 35,
    eia: 65,
    internal: 10
  }

  defp check_pg_api_freshness(blockers, api_timestamps, now) do
    stale_apis =
      @api_freshness
      |> Enum.filter(fn {source, max_age_min} ->
        case Map.get(api_timestamps, source) do
          nil -> true
          ts -> DateTime.diff(now, ts, :second) > max_age_min * 60
        end
      end)
      |> Enum.map(fn {source, _} -> source end)

    if length(stale_apis) > 0 do
      [%{gate: :product_group, code: :stale_apis,
         message: "#{length(stale_apis)} API source(s) stale: #{Enum.join(stale_apis, ", ")}",
         details: stale_apis} | blockers]
    else
      blockers
    end
  end

  # ──────────────────────────────────────────────────────────
  # CONVENIENCE: Full gate report for UI
  # ──────────────────────────────────────────────────────────

  @doc """
  Run all 4 gates and return a complete report for a product group.
  Shows per-contract gate status and the master gate.
  """
  def full_report(product_group) do
    active_contracts = Store.get_active_set(product_group)
    all_contracts = Store.list_by_product_group(product_group)

    contract_reports =
      all_contracts
      |> Enum.map(fn c ->
        g1 = gate_extraction(c)
        g2 = gate_review(c)
        g3 = gate_activation(c)

        %{
          contract_id: c.id,
          counterparty: c.counterparty,
          version: c.version,
          status: c.status,
          template_type: c.template_type,
          incoterm: c.incoterm,
          gate1_extraction: gate_status(g1),
          gate2_review: gate_status(g2),
          gate3_activation: gate_status(g3),
          blockers: collect_all_blockers(g1, g2, g3)
        }
      end)

    g4 = gate_product_group(product_group)

    %{
      product_group: product_group,
      master_gate: gate_status(g4),
      master_blockers: case g4 do
        {:pass, _} -> []
        {:fail, blockers, _} -> blockers
      end,
      contracts: contract_reports,
      total_contracts: length(all_contracts),
      active_contracts: length(active_contracts),
      all_passing: match?({:pass, _}, g4),
      checked_at: DateTime.utc_now()
    }
  end

  defp gate_status({:pass, _}), do: :pass
  defp gate_status({:fail, _, _}), do: :fail

  defp collect_all_blockers(g1, g2, g3) do
    [g1, g2, g3]
    |> Enum.flat_map(fn
      {:fail, blockers, _} -> blockers
      {:pass, _} -> []
    end)
  end
end
