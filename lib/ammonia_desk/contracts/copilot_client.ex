defmodule AmmoniaDesk.Contracts.CopilotClient do
  @moduledoc """
  LLM client for on-demand clause extraction.

  Called by ScanCoordinator when a contract file needs to be extracted.
  This module does one thing: send document text to the Copilot LLM
  and return structured clause data.

  It does NOT:
  - Scan folders (ScanCoordinator + NetworkScanner do that)
  - Download files (NetworkScanner does that)
  - Compare hashes (ScanCoordinator does that)
  - Persist contracts (CopilotIngestion does that)

  ## Usage

      text = DocumentReader.read("contract.docx")
      {:ok, extraction} = CopilotClient.extract_text(text)
      # extraction = %{"clauses" => [...], "counterparty" => "Koch", ...}

  ## Configuration

    COPILOT_ENDPOINT  — LLM API endpoint (OpenAI-compatible, required)
    COPILOT_API_KEY   — API key (required)
    COPILOT_MODEL     — model identifier (default: gpt-4o)
    COPILOT_TIMEOUT   — request timeout in ms (default: 120000)
  """

  alias AmmoniaDesk.Contracts.TemplateRegistry

  require Logger

  @default_timeout 120_000
  @default_model "gpt-4o"

  # ──────────────────────────────────────────────────────────
  # PUBLIC API
  # ──────────────────────────────────────────────────────────

  @doc """
  Extract structured clause data from contract text.

  Sends the text + canonical clause inventory to the LLM.
  Returns a map with clauses, counterparty, incoterm, etc.

  This is the only function ScanCoordinator calls.
  """
  @spec extract_text(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def extract_text(contract_text, _opts \\ []) do
    with {:ok, config} <- get_config() do
      call_llm(contract_text, config)
    end
  end

  @doc "Check if the LLM API is configured and reachable."
  @spec available?() :: boolean()
  def available? do
    case get_config() do
      {:ok, config} ->
        case Req.get(config.endpoint <> "/models",
               headers: auth_headers(config),
               receive_timeout: 5_000) do
          {:ok, %{status: s}} when s in 200..299 -> true
          _ -> false
        end

      _ ->
        false
    end
  end

  # ──────────────────────────────────────────────────────────
  # LLM CALL
  # ──────────────────────────────────────────────────────────

  defp call_llm(contract_text, config) do
    body = %{
      model: config.model,
      messages: [
        %{role: "system", content: system_prompt()},
        %{role: "user", content: extraction_prompt(contract_text)}
      ],
      temperature: 0.1,
      response_format: %{type: "json_object"}
    }

    case Req.post(config.endpoint <> "/chat/completions",
           json: body,
           headers: auth_headers(config),
           receive_timeout: timeout()
         ) do
      {:ok, %{status: 200, body: %{"choices" => [%{"message" => %{"content" => json_str}} | _]}}} ->
        parse_response(json_str)

      {:ok, %{status: status, body: body}} ->
        Logger.error("LLM API error (#{status}): #{inspect(body)}")
        {:error, {:api_error, status}}

      {:error, reason} ->
        Logger.error("LLM API unreachable: #{inspect(reason)}")
        {:error, {:api_unreachable, reason}}
    end
  end

  defp parse_response(json_str) do
    case Jason.decode(json_str) do
      {:ok, %{"clauses" => clauses} = extraction} when is_list(clauses) ->
        {:ok, extraction}
      {:ok, _} ->
        {:error, :missing_clauses_key}
      {:error, reason} ->
        {:error, {:json_parse_failed, reason}}
    end
  end

  # ──────────────────────────────────────────────────────────
  # PROMPTS
  # ──────────────────────────────────────────────────────────

  defp system_prompt do
    inventory = clause_inventory_text()
    families = family_signatures_text()

    """
    You are a contract extraction specialist for Trammo's ammonia trading desk.
    Extract structured clause data from commodity trading contracts.

    Return a JSON object with the exact structure specified in the user prompt.
    Be precise with numerical values. Preserve original units and currencies.

    ## Known Clause Inventory
    #{inventory}

    ## Known Contract Families
    #{families}
    """
  end

  defp extraction_prompt(contract_text) do
    """
    Extract all clauses from this contract. Return JSON:

    {
      "contract_number": "string or null",
      "counterparty": "name",
      "counterparty_type": "supplier" or "customer",
      "direction": "purchase" or "sale",
      "incoterm": "FOB" etc.,
      "term_type": "spot" or "long_term",
      "company": "trammo_inc" or "trammo_sas" or "trammo_dmcc",
      "effective_date": "YYYY-MM-DD or null",
      "expiry_date": "YYYY-MM-DD or null",
      "family_id": "matched family ID or null",
      "clauses": [
        {
          "clause_id": "PRICE",
          "category": "commercial",
          "extracted_fields": {"price_value": 340.00, "price_uom": "$/ton"},
          "source_text": "exact contract text",
          "section_ref": "Section 5",
          "confidence": "high",
          "anchors_matched": ["Price", "US $"]
        }
      ],
      "new_clause_definitions": []
    }

    Rules:
    - Extract EVERY identifiable clause, not just known types
    - Include exact source_text from the contract
    - Precise numerical values (prices, quantities, percentages)
    - confidence: "low" if uncertain
    - new_clause_definitions only for clauses NOT in the inventory

    CONTRACT:
    ---
    #{contract_text}
    ---
    """
  end

  defp clause_inventory_text do
    TemplateRegistry.canonical_clauses()
    |> Enum.sort_by(fn {id, _} -> id end)
    |> Enum.map(fn {id, d} ->
      "- #{id} (#{d.category}): anchors=[#{Enum.join(d.anchors, ", ")}], " <>
      "fields=[#{Enum.join(Enum.map(d.extract_fields, &to_string/1), ", ")}]"
    end)
    |> Enum.join("\n")
  end

  defp family_signatures_text do
    TemplateRegistry.family_signatures()
    |> Enum.sort_by(fn {id, _} -> id end)
    |> Enum.map(fn {id, f} ->
      "- #{id}: #{f.direction}/#{f.term_type}/#{f.transport}, " <>
      "incoterms=[#{Enum.join(Enum.map(f.default_incoterms, &to_string/1), ", ")}]"
    end)
    |> Enum.join("\n")
  end

  # ──────────────────────────────────────────────────────────
  # CONFIG
  # ──────────────────────────────────────────────────────────

  defp get_config do
    endpoint = System.get_env("COPILOT_ENDPOINT")
    api_key = System.get_env("COPILOT_API_KEY")

    cond do
      is_nil(endpoint) or endpoint == "" -> {:error, :endpoint_not_configured}
      is_nil(api_key) or api_key == "" -> {:error, :api_key_not_configured}
      true ->
        {:ok, %{
          endpoint: String.trim_trailing(endpoint, "/"),
          api_key: api_key,
          model: System.get_env("COPILOT_MODEL") || @default_model
        }}
    end
  end

  defp auth_headers(%{api_key: key}), do: [{"authorization", "Bearer #{key}"}]

  defp timeout do
    case System.get_env("COPILOT_TIMEOUT") do
      nil -> @default_timeout
      val ->
        case Integer.parse(val) do
          {n, _} -> n
          :error -> @default_timeout
        end
    end
  end
end
