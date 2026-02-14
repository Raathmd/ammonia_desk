defmodule AmmoniaDesk.Contracts.Parser do
  @moduledoc """
  Deterministic, local-only contract clause extraction using Elixir pattern matching.

  No external API calls. No LLM. Every extracted value has a confidence score
  and a reference back to the original text. Correctness over convenience:
  if a pattern doesn't match cleanly, it's flagged :low confidence for
  manual review rather than guessed.

  Extraction pipeline:
    1. Normalize text (whitespace, line breaks, encoding)
    2. Split into sections/paragraphs
    3. Run each paragraph through clause matchers
    4. Score confidence based on pattern match quality
    5. Deduplicate and resolve conflicts
  """

  alias AmmoniaDesk.Contracts.Clause

  require Logger

  # --- Number patterns ---
  # Matches: 12,000  12000  12_000  12.5  $320  $4,200,000.00
  @number_pattern ~r/[\$]?\s*([\d,_]+(?:\.\d+)?)/

  # --- Unit patterns ---
  @unit_patterns %{
    "tons" => ~r/\b(tons?|mt|metric\s+tons?|tonnes?)\b/i,
    "$/ton" => ~r/\b(\$\s*\/\s*(?:ton|mt|tonne)|(?:dollars?|usd)\s+per\s+(?:ton|mt))\b/i,
    "days" => ~r/\b(days?|business\s+days?|calendar\s+days?)\b/i,
    "barges" => ~r/\b(barges?|vessels?)\b/i,
    "$" => ~r/\b(dollars?|usd|\$)\b/i,
    "$/day" => ~r/\b(\$\s*\/\s*day|(?:dollars?|usd)\s+per\s+day)\b/i,
    "$/MMBtu" => ~r/\b(\$\s*\/\s*mmbtu)\b/i
  }

  # --- Period patterns ---
  @period_patterns [
    {:monthly, ~r/\b(monthly|per\s+month|each\s+month|calendar\s+month)\b/i},
    {:quarterly, ~r/\b(quarterly|per\s+quarter|each\s+quarter)\b/i},
    {:annual, ~r/\b(annual(?:ly)?|per\s+(?:year|annum)|each\s+year|yearly)\b/i},
    {:spot, ~r/\b(spot|per\s+shipment|per\s+load|per\s+barge)\b/i}
  ]

  @doc """
  Parse contract text into a list of extracted clauses.
  Returns {clauses, warnings} where warnings are paragraphs that
  looked like clauses but couldn't be parsed with high confidence.
  """
  @spec parse(String.t()) :: {[Clause.t()], [String.t()]}
  def parse(text) when is_binary(text) do
    now = DateTime.utc_now()

    paragraphs =
      text
      |> normalize_text()
      |> split_into_sections()

    {clauses, warnings} =
      paragraphs
      |> Enum.reduce({[], []}, fn {section_ref, para}, {clauses_acc, warn_acc} ->
        case extract_clause(para, section_ref) do
          {:ok, clause} ->
            clause = %{clause | id: Clause.generate_id(), extracted_at: now}
            {[clause | clauses_acc], warn_acc}

          :skip ->
            {clauses_acc, warn_acc}

          {:warn, reason} ->
            {clauses_acc, ["[#{section_ref}] #{reason}: #{String.slice(para, 0, 120)}" | warn_acc]}
        end
      end)

    {Enum.reverse(clauses) |> deduplicate(), Enum.reverse(warnings)}
  end

  # --- Text normalization ---

  defp normalize_text(text) do
    text
    |> String.replace(~r/\r\n/, "\n")
    |> String.replace(~r/["""]/, "\"")
    |> String.replace(~r/[''']/, "'")
    |> String.replace(~r/\s{2,}/, " ")
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
  end

  # --- Section splitting ---
  # Attempts to detect section/paragraph numbering for reference back to source

  defp split_into_sections(text) do
    text
    |> String.split(~r/\n{2,}|\n(?=\d+[\.\)]\s)|\n(?=[A-Z][a-z]+\s+\d)/)
    |> Enum.with_index(1)
    |> Enum.map(fn {para, idx} ->
      section_ref = detect_section_ref(para, idx)
      {section_ref, String.trim(para)}
    end)
    |> Enum.reject(fn {_, para} -> String.length(para) < 10 end)
  end

  defp detect_section_ref(para, fallback_idx) do
    cond do
      # "Section 4.2" or "Article 3"
      match = Regex.run(~r/^(?:Section|Article|Clause|Para(?:graph)?)\s+([\d\.]+)/i, para) ->
        "Section #{Enum.at(match, 1)}"

      # "4.2 Delivery Terms"
      match = Regex.run(~r/^([\d]+\.[\d\.]*)\s+/, para) ->
        "Section #{Enum.at(match, 1)}"

      # "(a)" or "(iv)"
      match = Regex.run(~r/^\(([a-z]+|[ivxlc]+)\)/, para) ->
        "Clause (#{Enum.at(match, 1)})"

      true ->
        "Para #{fallback_idx}"
    end
  end

  # --- Clause extraction (pattern matching) ---
  # Each matcher returns {:ok, %Clause{}} | :skip | {:warn, reason}
  # Order matters: more specific patterns first.

  defp extract_clause(para, section_ref) do
    lower = String.downcase(para)

    matchers = [
      &match_minimum_volume/3,
      &match_maximum_volume/3,
      &match_price_term/3,
      &match_demurrage_penalty/3,
      &match_shortfall_penalty/3,
      &match_late_delivery_penalty/3,
      &match_delivery_window/3,
      &match_barge_capacity/3,
      &match_force_majeure/3,
      &match_take_or_pay/3,
      &match_freight_rate/3,
      &match_inventory_requirement/3,
      &match_working_capital/3
    ]

    result =
      Enum.find_value(matchers, :skip, fn matcher ->
        case matcher.(para, lower, section_ref) do
          {:ok, _clause} = ok -> ok
          {:warn, _reason} = warn -> warn
          :skip -> nil
        end
      end)

    result
  end

  # --- Individual clause matchers ---

  defp match_minimum_volume(para, lower, section_ref) do
    cond do
      String.contains?(lower, "minimum") and
        (String.contains?(lower, "volume") or String.contains?(lower, "quantity") or
           String.contains?(lower, "tonnage")) ->
        case extract_number(para) do
          {:ok, value} ->
            {:ok, %Clause{
              type: :obligation,
              description: para,
              parameter: detect_volume_parameter(lower),
              operator: :>=,
              value: value,
              unit: detect_unit(para) || "tons",
              period: detect_period(lower),
              reference_section: section_ref,
              confidence: if(value > 0, do: :high, else: :low)
            }}

          :none ->
            {:warn, "minimum volume clause found but no numeric value extracted"}
        end

      true ->
        :skip
    end
  end

  defp match_maximum_volume(para, lower, section_ref) do
    cond do
      String.contains?(lower, "maximum") and
        (String.contains?(lower, "volume") or String.contains?(lower, "quantity") or
           String.contains?(lower, "capacity")) ->
        case extract_number(para) do
          {:ok, value} ->
            {:ok, %Clause{
              type: :limit,
              description: para,
              parameter: detect_volume_parameter(lower),
              operator: :<=,
              value: value,
              unit: detect_unit(para) || "tons",
              period: detect_period(lower),
              reference_section: section_ref,
              confidence: if(value > 0, do: :high, else: :low)
            }}

          :none ->
            {:warn, "maximum volume clause found but no numeric value extracted"}
        end

      true ->
        :skip
    end
  end

  defp match_price_term(para, lower, section_ref) do
    cond do
      (String.contains?(lower, "price") or String.contains?(lower, "rate")) and
        (String.contains?(lower, "per ton") or String.contains?(lower, "$/ton") or
           String.contains?(lower, "per mt") or String.contains?(lower, "per metric")) ->
        case extract_dollar_amount(para) do
          {:ok, value} ->
            {:ok, %Clause{
              type: :price_term,
              description: para,
              parameter: detect_price_parameter(lower),
              operator: :==,
              value: value,
              unit: "$/ton",
              period: detect_period(lower),
              reference_section: section_ref,
              confidence: :high
            }}

          :none ->
            {:warn, "price term found but no dollar amount extracted"}
        end

      true ->
        :skip
    end
  end

  defp match_demurrage_penalty(para, lower, section_ref) do
    if String.contains?(lower, "demurrage") do
      case extract_dollar_amount(para) do
        {:ok, value} ->
          cap = extract_penalty_cap(para)

          {:ok, %Clause{
            type: :penalty,
            description: para,
            parameter: :demurrage,
            operator: :>=,
            value: 0,
            unit: "$/day",
            penalty_per_unit: value,
            penalty_cap: cap,
            reference_section: section_ref,
            confidence: :high
          }}

        :none ->
          {:warn, "demurrage clause found but no rate extracted"}
      end
    else
      :skip
    end
  end

  defp match_shortfall_penalty(para, lower, section_ref) do
    if String.contains?(lower, "shortfall") and
         (String.contains?(lower, "penalty") or String.contains?(lower, "liquidated")) do
      case extract_dollar_amount(para) do
        {:ok, value} ->
          {:ok, %Clause{
            type: :penalty,
            description: para,
            parameter: :volume_shortfall,
            operator: :>=,
            value: 0,
            unit: "$/ton",
            penalty_per_unit: value,
            penalty_cap: extract_penalty_cap(para),
            period: detect_period(lower),
            reference_section: section_ref,
            confidence: :high
          }}

        :none ->
          {:warn, "shortfall penalty clause found but no rate extracted"}
      end
    else
      :skip
    end
  end

  defp match_late_delivery_penalty(para, lower, section_ref) do
    if (String.contains?(lower, "late") or String.contains?(lower, "delay")) and
         (String.contains?(lower, "penalty") or String.contains?(lower, "liquidated damage")) do
      case extract_dollar_amount(para) do
        {:ok, value} ->
          {:ok, %Clause{
            type: :penalty,
            description: para,
            parameter: :late_delivery,
            operator: :>=,
            value: 0,
            unit: detect_unit(para) || "$/day",
            penalty_per_unit: value,
            penalty_cap: extract_penalty_cap(para),
            reference_section: section_ref,
            confidence: :high
          }}

        :none ->
          {:warn, "late delivery penalty found but no amount extracted"}
      end
    else
      :skip
    end
  end

  defp match_delivery_window(para, lower, section_ref) do
    if String.contains?(lower, "delivery") and
         (String.contains?(lower, "window") or String.contains?(lower, "within") or
            String.contains?(lower, "schedule")) do
      case extract_number(para) do
        {:ok, value} ->
          {:ok, %Clause{
            type: :delivery,
            description: para,
            parameter: :delivery_window,
            operator: :<=,
            value: value,
            unit: detect_unit(para) || "days",
            reference_section: section_ref,
            confidence: if(value > 0, do: :medium, else: :low)
          }}

        :none ->
          # Delivery clauses without a number may still be relevant
          {:warn, "delivery window clause found but no duration extracted"}
      end
    else
      :skip
    end
  end

  defp match_barge_capacity(para, lower, section_ref) do
    if String.contains?(lower, "barge") and
         (String.contains?(lower, "capacity") or String.contains?(lower, "minimum") or
            String.contains?(lower, "fleet")) do
      case extract_number(para) do
        {:ok, value} ->
          {:ok, %Clause{
            type: :limit,
            description: para,
            parameter: :barge_count,
            operator: detect_operator(lower),
            value: value,
            unit: "barges",
            reference_section: section_ref,
            confidence: :medium
          }}

        :none ->
          :skip
      end
    else
      :skip
    end
  end

  defp match_force_majeure(para, lower, section_ref) do
    if String.contains?(lower, "force majeure") do
      {:ok, %Clause{
        type: :condition,
        description: para,
        parameter: :force_majeure,
        reference_section: section_ref,
        confidence: :high
      }}
    else
      :skip
    end
  end

  defp match_take_or_pay(para, lower, section_ref) do
    if String.contains?(lower, "take or pay") or String.contains?(lower, "take-or-pay") do
      case extract_number(para) do
        {:ok, value} ->
          {:ok, %Clause{
            type: :obligation,
            description: para,
            parameter: detect_volume_parameter(lower),
            operator: :>=,
            value: value,
            unit: detect_unit(para) || "tons",
            period: detect_period(lower),
            penalty_per_unit: extract_secondary_dollar(para),
            reference_section: section_ref,
            confidence: :high
          }}

        :none ->
          {:warn, "take-or-pay clause found but no commitment volume extracted"}
      end
    else
      :skip
    end
  end

  defp match_freight_rate(para, lower, section_ref) do
    if String.contains?(lower, "freight") and
         (String.contains?(lower, "rate") or String.contains?(lower, "$/ton") or
            String.contains?(lower, "per ton")) do
      case extract_dollar_amount(para) do
        {:ok, value} ->
          {:ok, %Clause{
            type: :price_term,
            description: para,
            parameter: detect_freight_parameter(lower),
            operator: :==,
            value: value,
            unit: "$/ton",
            reference_section: section_ref,
            confidence: :high
          }}

        :none ->
          {:warn, "freight rate clause found but no rate extracted"}
      end
    else
      :skip
    end
  end

  defp match_inventory_requirement(para, lower, section_ref) do
    if String.contains?(lower, "inventory") and
         (String.contains?(lower, "maintain") or String.contains?(lower, "minimum") or
            String.contains?(lower, "buffer")) do
      case extract_number(para) do
        {:ok, value} ->
          {:ok, %Clause{
            type: :obligation,
            description: para,
            parameter: detect_inventory_parameter(lower),
            operator: :>=,
            value: value,
            unit: "tons",
            reference_section: section_ref,
            confidence: :medium
          }}

        :none ->
          :skip
      end
    else
      :skip
    end
  end

  defp match_working_capital(para, lower, section_ref) do
    if (String.contains?(lower, "working capital") or String.contains?(lower, "credit limit") or
          String.contains?(lower, "credit facility")) do
      case extract_dollar_amount(para) do
        {:ok, value} ->
          {:ok, %Clause{
            type: :limit,
            description: para,
            parameter: :working_cap,
            operator: :<=,
            value: value,
            unit: "$",
            reference_section: section_ref,
            confidence: :medium
          }}

        :none ->
          :skip
      end
    else
      :skip
    end
  end

  # --- Number extraction helpers ---

  defp extract_number(text) do
    case Regex.run(@number_pattern, text) do
      [_, raw] ->
        cleaned = raw |> String.replace(~r/[,_]/, "")
        case Float.parse(cleaned) do
          {val, _} -> {:ok, val}
          :error -> :none
        end
      nil -> :none
    end
  end

  defp extract_dollar_amount(text) do
    # More specific: look for $ followed by number
    case Regex.run(~r/\$\s*([\d,_]+(?:\.\d+)?)/, text) do
      [_, raw] ->
        cleaned = raw |> String.replace(~r/[,_]/, "")
        case Float.parse(cleaned) do
          {val, _} -> {:ok, val}
          :error -> :none
        end
      nil ->
        # Fallback: "X dollars per" pattern
        case Regex.run(~r/([\d,]+(?:\.\d+)?)\s+(?:dollars?|usd)/i, text) do
          [_, raw] ->
            cleaned = raw |> String.replace(",", "")
            case Float.parse(cleaned) do
              {val, _} -> {:ok, val}
              :error -> :none
            end
          nil -> :none
        end
    end
  end

  defp extract_secondary_dollar(text) do
    # Extract the second dollar amount (e.g., "10,000 tons at $25/ton penalty")
    case Regex.scan(~r/\$\s*([\d,_]+(?:\.\d+)?)/, text) do
      [_, [_, raw] | _] ->
        cleaned = raw |> String.replace(~r/[,_]/, "")
        case Float.parse(cleaned) do
          {val, _} -> val
          :error -> nil
        end
      _ -> nil
    end
  end

  defp extract_penalty_cap(text) do
    lower = String.downcase(text)
    if String.contains?(lower, "cap") or String.contains?(lower, "maximum") or
         String.contains?(lower, "not to exceed") do
      # Look for the cap amount (usually the larger number after "cap" or "not to exceed")
      cap_text = Regex.run(~r/(?:cap|maximum|not\s+to\s+exceed)[^\$]*\$\s*([\d,]+(?:\.\d+)?)/i, text)
      case cap_text do
        [_, raw] ->
          cleaned = raw |> String.replace(",", "")
          case Float.parse(cleaned) do
            {val, _} -> val
            :error -> nil
          end
        nil -> nil
      end
    else
      nil
    end
  end

  # --- Parameter detection helpers ---
  # Map clause context to solver variable keys

  defp detect_volume_parameter(lower) do
    cond do
      String.contains?(lower, "donaldsonville") or String.contains?(lower, "don ") -> :inv_don
      String.contains?(lower, "geismar") or String.contains?(lower, "geis") -> :inv_geis
      String.contains?(lower, "st. louis") or String.contains?(lower, "stl") -> :sell_stl
      String.contains?(lower, "memphis") or String.contains?(lower, "mem") -> :sell_mem
      true -> :total_volume
    end
  end

  defp detect_price_parameter(lower) do
    cond do
      String.contains?(lower, "buy") or String.contains?(lower, "purchase") -> :nola_buy
      String.contains?(lower, "st. louis") or String.contains?(lower, "stl") -> :sell_stl
      String.contains?(lower, "memphis") or String.contains?(lower, "mem") -> :sell_mem
      String.contains?(lower, "natural gas") or String.contains?(lower, "henry hub") -> :nat_gas
      true -> :contract_price
    end
  end

  defp detect_freight_parameter(lower) do
    cond do
      String.contains?(lower, "donaldsonville") and String.contains?(lower, "st. louis") -> :fr_don_stl
      String.contains?(lower, "donaldsonville") and String.contains?(lower, "memphis") -> :fr_don_mem
      String.contains?(lower, "geismar") and String.contains?(lower, "st. louis") -> :fr_geis_stl
      String.contains?(lower, "geismar") and String.contains?(lower, "memphis") -> :fr_geis_mem
      String.contains?(lower, "don") and String.contains?(lower, "stl") -> :fr_don_stl
      String.contains?(lower, "don") and String.contains?(lower, "mem") -> :fr_don_mem
      String.contains?(lower, "geis") and String.contains?(lower, "stl") -> :fr_geis_stl
      String.contains?(lower, "geis") and String.contains?(lower, "mem") -> :fr_geis_mem
      true -> :freight_rate
    end
  end

  defp detect_inventory_parameter(lower) do
    cond do
      String.contains?(lower, "donaldsonville") or String.contains?(lower, "don") -> :inv_don
      String.contains?(lower, "geismar") or String.contains?(lower, "geis") -> :inv_geis
      true -> :inventory
    end
  end

  defp detect_unit(text) do
    Enum.find_value(@unit_patterns, fn {unit_name, pattern} ->
      if Regex.match?(pattern, text), do: unit_name
    end)
  end

  defp detect_period(lower) do
    Enum.find_value(@period_patterns, fn {period, pattern} ->
      if Regex.match?(pattern, lower), do: period
    end)
  end

  defp detect_operator(lower) do
    cond do
      String.contains?(lower, "minimum") or String.contains?(lower, "at least") or
        String.contains?(lower, "no fewer") -> :>=
      String.contains?(lower, "maximum") or String.contains?(lower, "at most") or
        String.contains?(lower, "not to exceed") or String.contains?(lower, "no more") -> :<=
      true -> :>=
    end
  end

  # --- Deduplication ---
  # If the same parameter+operator+value appears multiple times, keep the one
  # with highest confidence and the most specific section reference.

  defp deduplicate(clauses) do
    clauses
    |> Enum.group_by(fn c -> {c.parameter, c.operator, c.value, c.type} end)
    |> Enum.map(fn {_key, group} ->
      Enum.max_by(group, fn c ->
        confidence_rank(c.confidence)
      end)
    end)
    |> Enum.sort_by(& &1.reference_section)
  end

  defp confidence_rank(:high), do: 3
  defp confidence_rank(:medium), do: 2
  defp confidence_rank(:low), do: 1
  defp confidence_rank(_), do: 0
end
