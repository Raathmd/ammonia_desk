defmodule AmmoniaDesk.Contracts.LlmValidator do
  @moduledoc """
  Local LLM second-pass validation of extracted contract clauses.

  Runs entirely on-network via a local Ollama instance (or any
  OpenAI-compatible local endpoint). No data leaves the network.

  Purpose: catch extraction errors that pattern matching missed.
  The LLM reviews the original text alongside the extracted structured
  data and flags discrepancies. It does NOT generate clause data —
  it only validates what the deterministic parser already extracted.

  This is a verification layer, not an extraction layer.
  The parser's output is the source of truth. The LLM can only
  flag issues for human review, never silently change values.

  Configure via environment:
    LLM_ENDPOINT   — default http://localhost:11434 (Ollama)
    LLM_MODEL      — default llama3
  """

  alias AmmoniaDesk.Contracts.{Contract, Clause, Store}

  require Logger

  @default_endpoint "http://localhost:11434"
  @default_model "llama3"
  @timeout 60_000

  @doc """
  Validate a contract's extracted clauses against the original text
  using a local LLM. Returns a list of findings (potential issues).

  Each finding is:
    %{clause_id: id, issue: description, severity: :info | :warning | :error}
  """
  def validate(contract_id) do
    with {:ok, contract} <- Store.get(contract_id),
         {:ok, _} <- check_llm_available() do
      findings =
        (contract.clauses || [])
        |> Enum.flat_map(fn clause ->
          validate_clause(clause, contract)
        end)

      {:ok, %{
        contract_id: contract_id,
        findings: findings,
        finding_count: length(findings),
        errors: Enum.count(findings, &(&1.severity == :error)),
        warnings: Enum.count(findings, &(&1.severity == :warning)),
        validated_at: DateTime.utc_now()
      }}
    end
  end

  @doc """
  Validate all contracts in a product group using the local LLM.
  Runs each contract validation concurrently on the BEAM.
  """
  def validate_product_group(product_group) do
    contracts = Store.list_by_product_group(product_group)

    results =
      contracts
      |> Task.async_stream(
        fn contract -> {contract.id, validate(contract.id)} end,
        max_concurrency: 2,  # LLM is resource-intensive, limit concurrency
        timeout: @timeout * 2
      )
      |> Enum.map(fn
        {:ok, result} -> result
        {:exit, reason} -> {:error, {:task_failed, reason}}
      end)

    {:ok, %{
      product_group: product_group,
      total: length(contracts),
      results: results
    }}
  end

  @doc "Check if the local LLM endpoint is available"
  def available? do
    case check_llm_available() do
      {:ok, _} -> true
      _ -> false
    end
  end

  # --- Private ---

  defp validate_clause(%Clause{} = clause, %Contract{} = contract) do
    prompt = build_validation_prompt(clause, contract)

    case call_local_llm(prompt) do
      {:ok, response} ->
        parse_llm_findings(response, clause.id)

      {:error, reason} ->
        Logger.warning("LLM validation failed for clause #{clause.id}: #{inspect(reason)}")
        []
    end
  end

  defp build_validation_prompt(%Clause{} = clause, %Contract{} = _contract) do
    """
    You are a contract data quality checker. Review the following extracted clause data
    and the original text it was extracted from. Report ONLY factual errors in the
    extraction — where the structured data does not match what the text says.

    Do NOT suggest improvements. Do NOT interpret meaning. Only flag mismatches.

    ORIGINAL TEXT:
    #{clause.description}

    EXTRACTED DATA:
    - Type: #{clause.type}
    - Parameter: #{clause.parameter}
    - Operator: #{clause.operator}
    - Value: #{clause.value}#{if clause.value_upper, do: " to #{clause.value_upper}", else: ""}
    - Unit: #{clause.unit}
    - Penalty per unit: #{clause.penalty_per_unit || "none"}
    - Penalty cap: #{clause.penalty_cap || "none"}
    - Period: #{clause.period || "not specified"}
    - Confidence: #{clause.confidence}

    Respond with ONLY a JSON array of issues found. Each issue should be:
    {"issue": "description of mismatch", "severity": "error" or "warning"}

    If the extraction is correct, respond with: []
    """
  end

  defp call_local_llm(prompt) do
    endpoint = System.get_env("LLM_ENDPOINT") || @default_endpoint
    model = System.get_env("LLM_MODEL") || @default_model

    url = "#{endpoint}/api/generate"

    case Req.post(url,
           json: %{
             model: model,
             prompt: prompt,
             format: "json",
             stream: false,
             options: %{temperature: 0.1}  # low temperature for factual checking
           },
           receive_timeout: @timeout
         ) do
      {:ok, %{status: 200, body: %{"response" => text}}} ->
        {:ok, text}

      {:ok, %{status: status, body: body}} ->
        {:error, {:llm_error, status, body}}

      {:error, reason} ->
        {:error, {:llm_unreachable, reason}}
    end
  end

  defp parse_llm_findings(response_text, clause_id) do
    case Jason.decode(response_text) do
      {:ok, findings} when is_list(findings) ->
        Enum.map(findings, fn finding ->
          %{
            clause_id: clause_id,
            issue: Map.get(finding, "issue", "Unknown issue"),
            severity: parse_severity(Map.get(finding, "severity", "warning"))
          }
        end)

      {:ok, %{"issue" => _} = single} ->
        [%{
          clause_id: clause_id,
          issue: single["issue"],
          severity: parse_severity(single["severity"] || "warning")
        }]

      _ ->
        # LLM didn't return valid JSON — treat entire response as a warning
        if String.trim(response_text) != "[]" and String.length(response_text) > 5 do
          [%{
            clause_id: clause_id,
            issue: "LLM response not parseable: #{String.slice(response_text, 0, 200)}",
            severity: :info
          }]
        else
          []
        end
    end
  end

  defp parse_severity("error"), do: :error
  defp parse_severity("warning"), do: :warning
  defp parse_severity(_), do: :info

  defp check_llm_available do
    endpoint = System.get_env("LLM_ENDPOINT") || @default_endpoint

    case Req.get("#{endpoint}/api/tags", receive_timeout: 5_000) do
      {:ok, %{status: 200}} -> {:ok, :available}
      {:ok, %{status: s}} -> {:error, {:llm_not_ready, s}}
      {:error, reason} -> {:error, {:llm_unreachable, reason}}
    end
  end
end
