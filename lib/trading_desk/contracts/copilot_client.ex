defmodule TradingDesk.Contracts.CopilotClient do
  @moduledoc """
  LLM client for on-demand clause extraction from SharePoint files.

  Called by ScanCoordinator when a contract file needs to be extracted.
  Two modes:

    1. `extract_file/3` — given a Graph API file reference (drive_id + item_id),
       fetches the file content via Graph API, extracts text, sends to LLM.
       Copilot handles all file access — Zig scanner never downloads content.

    2. `extract_text/1` — given pre-extracted text, sends directly to LLM.
       Used when text is already available (e.g. from a local file test).

  ## Architecture

  ```
  ScanCoordinator: "this file changed, extract it"
       │
       ▼
  CopilotClient.extract_file(drive_id, item_id, token)
       │
       ├── Graph API: download file content
       ├── DocumentReader: convert binary → text
       └── LLM: extract clauses from text
       │
       ▼
  Returns: {:ok, %{"clauses" => [...], "counterparty" => "Koch", ...}}
  ```

  ## Configuration

    COPILOT_ENDPOINT  — LLM API endpoint (OpenAI-compatible, required)
    COPILOT_API_KEY   — API key (required)
    COPILOT_MODEL     — model identifier (default: gpt-4o)
    COPILOT_TIMEOUT   — request timeout in ms (default: 120000)
  """

  alias TradingDesk.Contracts.{TemplateRegistry, DocumentReader}

  require Logger

  @default_timeout 120_000
  @default_model "gpt-4o"
  @graph_base "https://graph.microsoft.com/v1.0"
  @max_concurrent_extractions 4

  # ──────────────────────────────────────────────────────────
  # PUBLIC API
  # ──────────────────────────────────────────────────────────

  @doc """
  Extract clauses from a SharePoint file by reference.

  Downloads the file via Graph API, extracts text, sends to LLM.
  Copilot handles all file access — Zig scanner never downloads content.

  Returns:
    {:ok, %{"clauses" => [...], "counterparty" => "Koch", ...}}
  """
  @spec extract_file(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def extract_file(drive_id, item_id, graph_token, opts \\ []) do
    filename = Keyword.get(opts, :filename, "document")

    with {:ok, config} <- get_config(),
         {:ok, content} <- download_from_graph(drive_id, item_id, graph_token),
         {:ok, text} <- extract_text_from_binary(content, filename),
         {:ok, extraction} <- call_llm(text, config) do
      {:ok, Map.merge(extraction, %{
        "graph_drive_id" => drive_id,
        "graph_item_id" => item_id,
        "file_size" => byte_size(content),
        "file_hash" => sha256(content)
      })}
    end
  end

  @doc """
  Extract clauses from multiple SharePoint files concurrently.

  Each file is a map: %{drive_id, item_id, name, ...}
  Runs up to #{@max_concurrent_extractions} extractions in parallel.

  Returns a list of {file, result} tuples:
    [{%{name: "Koch.pdf", ...}, {:ok, extraction}}, ...]
  """
  @spec extract_files([map()], String.t(), keyword()) :: [{map(), {:ok, map()} | {:error, term()}}]
  def extract_files(files, graph_token, _opts \\ []) do
    files
    |> Task.async_stream(
      fn file ->
        drive_id = file["drive_id"] || file[:drive_id]
        item_id = file["item_id"] || file[:item_id]
        name = file["name"] || file[:name] || "document"

        result = extract_file(drive_id, item_id, graph_token, filename: name)
        {file, result}
      end,
      max_concurrency: @max_concurrent_extractions,
      timeout: @default_timeout + 30_000,
      on_timeout: :kill_task
    )
    |> Enum.map(fn
      {:ok, {file, result}} -> {file, result}
      {:exit, :timeout} -> {%{}, {:error, :extraction_timeout}}
    end)
  end

  @doc """
  Extract structured clause data from pre-extracted contract text.

  Used when text is already available (e.g. local file test).
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
  # GRAPH API FILE ACCESS
  # ──────────────────────────────────────────────────────────

  defp download_from_graph(drive_id, item_id, graph_token) do
    url = "#{@graph_base}/drives/#{drive_id}/items/#{item_id}/content"

    case Req.get(url,
           headers: [{"authorization", graph_token}],
           receive_timeout: 60_000,
           max_redirects: 3) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        Logger.error("Graph file download failed (#{status}): #{inspect(body)}")
        {:error, {:graph_download_failed, status}}

      {:error, reason} ->
        Logger.error("Graph file download error: #{inspect(reason)}")
        {:error, {:graph_download_error, reason}}
    end
  end

  defp extract_text_from_binary(content, filename) do
    ext = Path.extname(filename)
    tmp_path = Path.join(System.tmp_dir!(), "copilot_#{:erlang.unique_integer([:positive])}#{ext}")

    try do
      File.write!(tmp_path, content)
      DocumentReader.read(tmp_path)
    after
      File.rm(tmp_path)
    end
  end

  defp sha256(content) do
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
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
