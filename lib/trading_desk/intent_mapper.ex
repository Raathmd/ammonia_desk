defmodule TradingDesk.IntentMapper do
  @moduledoc """
  Maps a trader's plain-text action description into solver variable adjustments
  and contract impact context.

  The trader types something like:
    "What if I redirect the March Yuzhnyy cargo to India instead of Morocco?"
    "I want to test selling 5000 more tons to Koch at Memphis"
    "Simulate a river drop to 15 feet with both plants running"

  Claude interprets this in the context of:
    - Current solver variables
    - Open positions per counterparty (from SAP)
    - Contract penalties and obligations

  Returns a structured intent that the pre-solve review popup displays,
  and variable adjustments that get applied before solving.
  """

  require Logger

  alias TradingDesk.ProductGroup
  alias TradingDesk.Contracts.SapPositions

  @model "claude-sonnet-4-5-20250929"

  @doc """
  Parse trader intent and produce a structured solve context.

  Returns:
    {:ok, %{
      summary: "one-line summary of what will be tested",
      variable_adjustments: %{key => new_value},
      affected_contracts: [%{counterparty, direction, impact_description, open_qty}],
      risk_notes: ["list of risks or penalties that may be triggered"],
      position_context: %{net_position, total_purchase, total_sale}
    }}

  Or {:error, reason} if parsing fails.
  """
  def parse_intent(action_text, current_vars, product_group \\ :ammonia_domestic) do
    frame = ProductGroup.frame(product_group)
    book = SapPositions.book_summary()
    vars_text = format_current_vars(current_vars, frame)
    positions_text = format_positions(book)

    prompt = """
    You are a commodity trading desk system that interprets trader actions.

    The trader typed this action they want to test:
    "#{action_text}"

    CURRENT SOLVER VARIABLES:
    #{vars_text}

    OPEN BOOK POSITIONS (from SAP):
    #{positions_text}

    Net position: #{book.net_position} MT (positive = Trammo is long ammonia)

    INSTRUCTIONS:
    Interpret the trader's intent and return ONLY a JSON object (no markdown, no explanation) with these fields:

    {
      "summary": "One-line summary of the trading action being tested",
      "variable_adjustments": {"variable_key": new_value},
      "affected_contracts": [
        {"counterparty": "name", "direction": "purchase|sale", "impact": "description of impact", "open_qty_change": 0}
      ],
      "risk_notes": ["any penalties or contract risks triggered by this action"],
      "confidence": "high|medium|low"
    }

    Rules:
    - variable_adjustments keys MUST be valid solver variable keys from the list above
    - Only include variables that the trader's action would change
    - If the trader describes a market scenario (river drop, outage, price change), adjust those variables
    - If the trader describes a trading action (redirect cargo, increase volume), note the affected contracts
    - risk_notes should mention specific penalty clauses if volume shortfall or late delivery is possible
    - Return ONLY the JSON, nothing else
    """

    case call_claude(prompt) do
      {:ok, json_text} ->
        parse_json_response(json_text, book)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── Private ──────────────────────────────────────────────

  defp format_current_vars(vars, frame) do
    (frame[:variables] || [])
    |> Enum.map_join("\n", fn v ->
      val = Map.get(vars, v[:key])
      "- #{v[:key]}: #{val} (#{v[:label]}, #{v[:unit]})"
    end)
  end

  defp format_positions(book) do
    book.positions
    |> Enum.sort_by(fn {_k, v} -> v.open_qty_mt end, :desc)
    |> Enum.map_join("\n", fn {name, pos} ->
      dir = if pos.direction == :purchase, do: "BUY", else: "SELL"
      "- #{name}: #{dir} #{pos.incoterm |> to_string() |> String.upcase()} | " <>
      "contract=#{pos.total_qty_mt} MT, delivered=#{pos.delivered_qty_mt} MT, " <>
      "open=#{pos.open_qty_mt} MT (#{pos.contract_number})"
    end)
  end

  defp parse_json_response(json_text, book) do
    # Strip markdown code fences if present
    cleaned =
      json_text
      |> String.replace(~r/^```json\s*/m, "")
      |> String.replace(~r/^```\s*/m, "")
      |> String.trim()

    case Jason.decode(cleaned) do
      {:ok, parsed} ->
        {:ok, %{
          summary: Map.get(parsed, "summary", "Trading action"),
          variable_adjustments: parse_adjustments(Map.get(parsed, "variable_adjustments", %{})),
          affected_contracts: parse_affected(Map.get(parsed, "affected_contracts", [])),
          risk_notes: Map.get(parsed, "risk_notes", []),
          confidence: String.to_atom(Map.get(parsed, "confidence", "medium")),
          position_context: %{
            net_position: book.net_position,
            total_purchase: book.total_purchase_open,
            total_sale: book.total_sale_open
          }
        }}

      {:error, _} ->
        Logger.warning("IntentMapper: failed to parse JSON from Claude response")
        {:ok, %{
          summary: "Could not parse action — using current variables as-is",
          variable_adjustments: %{},
          affected_contracts: [],
          risk_notes: ["Intent could not be mapped to specific variables"],
          confidence: :low,
          position_context: %{
            net_position: book.net_position,
            total_purchase: book.total_purchase_open,
            total_sale: book.total_sale_open
          }
        }}
    end
  end

  defp parse_adjustments(adj) when is_map(adj) do
    Map.new(adj, fn {k, v} ->
      key = String.to_atom(k)
      val = if is_number(v), do: v / 1, else: parse_number(v)
      {key, val}
    end)
  end
  defp parse_adjustments(_), do: %{}

  defp parse_affected(contracts) when is_list(contracts) do
    Enum.map(contracts, fn c ->
      %{
        counterparty: Map.get(c, "counterparty", "Unknown"),
        direction: Map.get(c, "direction", "unknown"),
        impact: Map.get(c, "impact", ""),
        open_qty_change: Map.get(c, "open_qty_change", 0)
      }
    end)
  end
  defp parse_affected(_), do: []

  defp parse_number(v) when is_binary(v) do
    case Float.parse(v) do
      {f, _} -> f
      :error -> 0.0
    end
  end
  defp parse_number(v) when is_number(v), do: v / 1
  defp parse_number(_), do: 0.0

  defp call_claude(prompt) do
    api_key = System.get_env("ANTHROPIC_API_KEY")

    if is_nil(api_key) or api_key == "" do
      {:error, :no_api_key}
    else
      case Req.post("https://api.anthropic.com/v1/messages",
        json: %{
          model: @model,
          max_tokens: 500,
          messages: [%{role: "user", content: prompt}]
        },
        headers: [
          {"x-api-key", api_key},
          {"anthropic-version", "2023-06-01"},
          {"content-type", "application/json"}
        ],
        receive_timeout: 15_000
      ) do
        {:ok, %{status: 200, body: %{"content" => [%{"text" => text} | _]}}} ->
          {:ok, String.trim(text)}

        {:ok, %{status: status, body: body}} ->
          Logger.error("IntentMapper Claude API error #{status}: #{inspect(body)}")
          {:error, :api_error}

        {:error, reason} ->
          Logger.error("IntentMapper request failed: #{inspect(reason)}")
          {:error, :request_failed}
      end
    end
  end
end
