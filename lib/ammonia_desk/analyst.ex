defmodule AmmoniaDesk.Analyst do
  @moduledoc """
  Claude-powered analyst that explains trading scenarios, Monte Carlo results,
  and agent decisions in plain English.
  """

  require Logger

  @anthropic_api_key System.get_env("ANTHROPIC_API_KEY")
  @model "claude-sonnet-4-20250514"

  @doc """
  Explain a solve result for the trader.
  """
  def explain_solve(variables, result) do
    prompt = """
    You are an ammonia trading analyst. A trader just ran an optimization with these inputs:

    MARKET:
    - NH3 buy price (NOLA): $#{variables.nola_buy}/ton
    - StL sell price: $#{variables.sell_stl}/ton
    - Mem sell price: $#{variables.sell_mem}/ton
    - Natural gas: $#{variables.nat_gas}/MMBtu

    LOGISTICS:
    - River stage: #{variables.river_stage} ft
    - Lock delays: #{variables.lock_hrs} hrs
    - Freight Don→StL: $#{variables.fr_don_stl}/ton
    - Freight Don→Mem: $#{variables.fr_don_mem}/ton
    - Freight Geis→StL: $#{variables.fr_geis_stl}/ton
    - Freight Geis→Mem: $#{variables.fr_geis_mem}/ton
    - Temperature: #{variables.temp_f}°F
    - Wind: #{variables.wind_mph} mph
    - Visibility: #{variables.vis_mi} mi
    - Precipitation: #{variables.precip_in} in
    - StL outage: #{if variables.stl_outage, do: "YES", else: "NO"}
    - Mem outage: #{if variables.mem_outage, do: "YES", else: "NO"}

    INVENTORY & FLEET:
    - Donaldsonville: #{round(variables.inv_don)} tons
    - Geismar: #{round(variables.inv_geis)} tons
    - Barges available: #{round(variables.barge_count)}
    - Working capital: $#{format_number(variables.working_cap)}

    RESULT:
    - Gross profit: $#{format_number(result.profit)}
    - Total tons: #{format_number(result.tons)}
    - Barges used: #{Float.round(result.barges, 1)}
    - ROI: #{Float.round(result.roi, 1)}%
    - Capital deployed: $#{format_number(result.cost)}

    Write a 2-3 sentence analyst note explaining WHY this result makes sense given the inputs.
    Focus on the key drivers (margins, constraints, or risks). Be concise and tactical.
    """

    call_claude(prompt)
  end

  @doc """
  Explain a Monte Carlo distribution for the trader.
  """
  def explain_distribution(variables, distribution) do
    sensitivity_text =
      if length(distribution.sensitivity) > 0 do
        top_3 =
          distribution.sensitivity
          |> Enum.take(3)
          |> Enum.map_join(", ", fn {key, corr} ->
            "#{key} (#{if corr > 0, do: "+", else: ""}#{Float.round(corr, 2)})"
          end)

        "\n- Top risk drivers: #{top_3}"
      else
        ""
      end

    prompt = """
    You are an ammonia trading analyst. A trader just ran 1000 Monte Carlo scenarios with these center values:

    MARKET: NH3 buy $#{variables.nola_buy}, StL sell $#{variables.sell_stl}, Mem sell $#{variables.sell_mem}, Gas $#{variables.nat_gas}
    LOGISTICS: River #{variables.river_stage}ft, Locks #{variables.lock_hrs}hrs
    INVENTORY: Don #{round(variables.inv_don)}t, Geis #{round(variables.inv_geis)}t
    FLEET: #{round(variables.barge_count)} barges, $#{format_number(variables.working_cap)} capital

    DISTRIBUTION:
    - #{distribution.n_feasible}/#{distribution.n_scenarios} scenarios feasible
    - Mean: $#{format_number(distribution.mean)}
    - VaR 5%: $#{format_number(distribution.p5)}
    - P95: $#{format_number(distribution.p95)}
    - Std dev: $#{format_number(distribution.stddev)}
    - Signal: #{distribution.signal}#{sensitivity_text}

    Write a 2-3 sentence analyst note interpreting this distribution and signal.
    What does the VaR/upside spread tell us? Should the trader proceed?
    """

    call_claude(prompt)
  end

  @doc """
  Explain an AutoRunner agent decision.
  """
  def explain_agent(result) do
    trigger_text =
      if length(result.triggers) > 0 do
        changes =
          result.triggers
          |> Enum.map_join(", ", fn %{key: key, old: old, new: new} ->
            delta = new - old
            "#{key} #{if delta > 0, do: "+", else: ""}#{Float.round(delta, 1)}"
          end)

        "Triggered by: #{changes}. "
      else
        "Scheduled run. "
      end

    sensitivity_text =
      if length(result.distribution.sensitivity) > 0 do
        top_2 =
          result.distribution.sensitivity
          |> Enum.take(2)
          |> Enum.map_join(", ", fn {key, corr} ->
            "#{key} (#{if corr > 0, do: "+", else: ""}#{Float.round(corr, 2)})"
          end)

        " Key drivers: #{top_2}."
      else
        ""
      end

    prompt = """
    You are an autonomous trading agent analyst. The agent just ran Monte Carlo on live market data:

    #{trigger_text}

    CURRENT CONDITIONS:
    - River: #{result.center.river_stage}ft, Locks: #{result.center.lock_hrs}hrs
    - NH3 buy: $#{result.center.nola_buy}, StL: $#{result.center.sell_stl}, Mem: $#{result.center.sell_mem}
    - Gas: $#{result.center.nat_gas}, Fleet: #{round(result.center.barge_count)} barges
    - StL outage: #{if result.center.stl_outage, do: "YES", else: "NO"}

    AGENT RESULT:
    - Signal: #{result.distribution.signal}
    - Mean: $#{format_number(result.distribution.mean)}
    - VaR 5%: $#{format_number(result.distribution.p5)}
    - #{result.distribution.n_feasible}/#{result.distribution.n_scenarios} feasible#{sensitivity_text}

    Write 2-3 sentences explaining what the agent sees and why it gave this signal.
    What changed? What's the agent watching?
    """

    call_claude(prompt)
  end

  # --- Private ---

  defp call_claude(prompt) do
    if is_nil(@anthropic_api_key) do
      Logger.warn("ANTHROPIC_API_KEY not set, skipping analyst explanation")
      {:error, :no_api_key}
    else
      case Req.post("https://api.anthropic.com/v1/messages",
        json: %{
          model: @model,
          max_tokens: 300,
          messages: [%{role: "user", content: prompt}]
        },
        headers: [
          {"x-api-key", @anthropic_api_key},
          {"anthropic-version", "2023-06-01"}
        ],
        receive_timeout: 10_000
      ) do
        {:ok, %{status: 200, body: %{"content" => [%{"text" => text} | _]}}} ->
          {:ok, String.trim(text)}

        {:ok, %{status: status, body: body}} ->
          Logger.error("Claude API error #{status}: #{inspect(body)}")
          {:error, :api_error}

        {:error, reason} ->
          Logger.error("Claude API request failed: #{inspect(reason)}")
          {:error, :request_failed}
      end
    end
  end

  defp format_number(val) when is_float(val) do
    val
    |> round()
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})/, "\\1,")
    |> String.reverse()
    |> String.trim_leading(",")
  end

  defp format_number(val), do: to_string(val)
end
