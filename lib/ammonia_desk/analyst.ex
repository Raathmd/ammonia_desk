defmodule AmmoniaDesk.Analyst do
  @moduledoc """
  Claude-powered analyst that explains trading scenarios, Monte Carlo results,
  and agent decisions in plain English. Works with any product group.
  """

  require Logger

  alias AmmoniaDesk.ProductGroup

  @model "claude-sonnet-4-5-20250929"

  @doc """
  Explain a solve result for the trader.

  Accepts variables as a `%Variables{}` struct or a plain map.
  Product group is read from `result.product_group`.
  """
  def explain_solve(variables, result) do
    pg = result.product_group || :ammonia_domestic
    vars = to_var_map(variables)
    frame = ProductGroup.frame(pg)

    vars_text = format_variables(vars, frame)
    routes_text = format_routes(result, frame)

    prompt = """
    You are a #{frame.product} trading analyst at a global commodities firm.
    Product group: #{frame.name} (#{frame.geography}).
    Transport: #{frame.transport_mode}.

    A trader just ran an optimization with these inputs:

    #{vars_text}

    ROUTES:
    #{routes_text}

    RESULT:
    - Gross profit: $#{format_number(result.profit)}
    - Total tons: #{format_number(result.tons)}
    - #{vessel_label(frame)}: #{format_vessels(result, frame)}
    - ROI: #{Float.round(result.roi || 0.0, 1)}%
    - Capital deployed: $#{format_number(result.cost)}

    Write a 2-3 sentence analyst note explaining WHY this result makes sense given the inputs.
    Focus on the key drivers (margins, constraints, or risks). Be concise and tactical.
    """

    call_claude(prompt)
  end

  @doc """
  Explain a Monte Carlo distribution for the trader.

  Accepts variables as a `%Variables{}` struct or a plain map.
  Product group is read from `distribution.product_group`.
  """
  def explain_distribution(variables, distribution) do
    pg = distribution.product_group || :ammonia_domestic
    vars = to_var_map(variables)
    frame = ProductGroup.frame(pg)

    vars_summary = format_variables_compact(vars, frame)
    sensitivity_text = format_sensitivity(distribution.sensitivity)

    prompt = """
    You are a #{frame.product} trading analyst. Product: #{frame.name} (#{frame.geography}).

    A trader just ran #{distribution.n_scenarios} Monte Carlo scenarios with these center values:

    #{vars_summary}

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

  `result` must have `.center` (variable map), `.distribution`, `.triggers`,
  and `.product_group`.
  """
  def explain_agent(result) do
    pg = result[:product_group] || result.distribution.product_group || :ammonia_domestic
    center = to_var_map(result.center)
    frame = ProductGroup.frame(pg)

    trigger_text = format_triggers(result.triggers)
    vars_summary = format_variables_compact(center, frame)
    sensitivity_text = format_sensitivity(result.distribution.sensitivity)

    prompt = """
    You are an autonomous #{frame.product} trading agent analyst.
    Product: #{frame.name} (#{frame.geography}).

    The agent just ran Monte Carlo on live market data:

    #{trigger_text}

    CURRENT CONDITIONS:
    #{vars_summary}

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

  # ── Variable formatting ─────────────────────────────────────

  defp format_variables(vars, frame) do
    frame.variables
    |> Enum.group_by(& &1.group)
    |> Enum.map_join("\n\n", fn {group, var_defs} ->
      header = group |> to_string() |> String.upcase()
      lines = Enum.map_join(var_defs, "\n", fn v ->
        val = Map.get(vars, v.key)
        "- #{v.label}: #{format_var_value(val, v)}"
      end)
      "#{header}:\n#{lines}"
    end)
  end

  defp format_variables_compact(vars, frame) do
    frame.variables
    |> Enum.group_by(& &1.group)
    |> Enum.map_join("\n", fn {group, var_defs} ->
      header = group |> to_string() |> String.upcase()
      items = Enum.map_join(var_defs, ", ", fn v ->
        val = Map.get(vars, v.key)
        "#{v.label} #{format_var_value_short(val, v)}"
      end)
      "#{header}: #{items}"
    end)
  end

  defp format_var_value(val, %{type: :boolean}) do
    if val in [true, 1, 1.0], do: "YES", else: "NO"
  end

  defp format_var_value(val, v) when is_float(val) do
    unit = if v[:unit] && v[:unit] != "", do: " #{v.unit}", else: ""
    if abs(val) >= 1000, do: "#{format_number(val)}#{unit}", else: "#{Float.round(val, 1)}#{unit}"
  end

  defp format_var_value(val, v) when is_number(val) do
    unit = if v[:unit] && v[:unit] != "", do: " #{v.unit}", else: ""
    "#{val}#{unit}"
  end

  defp format_var_value(val, _v), do: "#{inspect(val)}"

  defp format_var_value_short(val, %{type: :boolean}) do
    if val in [true, 1, 1.0], do: "YES", else: "NO"
  end

  defp format_var_value_short(val, v) when is_number(val) do
    unit = if v[:unit] && v[:unit] != "", do: v.unit, else: ""

    formatted =
      cond do
        abs(val) >= 1_000_000 -> "#{Float.round(val / 1_000_000, 1)}M"
        abs(val) >= 1000 -> "#{format_number(val)}"
        is_float(val) -> "#{Float.round(val, 1)}"
        true -> "#{val}"
      end

    if unit != "", do: "#{formatted} #{unit}", else: formatted
  end

  defp format_var_value_short(val, _v), do: "#{inspect(val)}"

  # ── Route formatting ────────────────────────────────────────

  defp format_routes(result, frame) do
    routes = frame.routes
    route_tons = result.route_tons || []
    margins = result.margins || []

    routes
    |> Enum.with_index()
    |> Enum.map_join("\n", fn {route, i} ->
      tons = Enum.at(route_tons, i, 0.0)
      margin = Enum.at(margins, i, 0.0)
      "- #{route.name}: #{format_number(tons)} tons, margin $#{Float.round(margin, 1)}/t"
    end)
  end

  # ── Result formatting ───────────────────────────────────────

  defp vessel_label(frame) do
    case frame.transport_mode do
      :barge -> "Barges used"
      :ocean_vessel -> "Vessels used"
      _ -> "Units used"
    end
  end

  defp format_vessels(result, _frame) do
    barges = result.barges || 0.0
    if is_float(barges), do: Float.round(barges, 1), else: barges
  end

  # ── Sensitivity & triggers ──────────────────────────────────

  defp format_sensitivity(sensitivity) when is_list(sensitivity) and length(sensitivity) > 0 do
    top =
      sensitivity
      |> Enum.take(3)
      |> Enum.map_join(", ", fn {key, corr} ->
        sign = if corr > 0, do: "+", else: ""
        "#{key} (#{sign}#{Float.round(corr, 2)})"
      end)

    "\n- Top risk drivers: #{top}"
  end

  defp format_sensitivity(_), do: ""

  defp format_triggers(triggers) when is_list(triggers) and length(triggers) > 0 do
    changes =
      triggers
      |> Enum.map_join(", ", fn %{key: key, old: old, new: new} ->
        delta = new - old
        "#{key} #{if delta > 0, do: "+", else: ""}#{Float.round(delta, 1)}"
      end)

    "Triggered by: #{changes}."
  end

  defp format_triggers(_), do: "Scheduled run."

  # ── Variable map conversion ─────────────────────────────────

  defp to_var_map(%AmmoniaDesk.Variables{} = v), do: Map.from_struct(v)
  defp to_var_map(map) when is_map(map), do: Map.drop(map, [:__struct__])

  # ── Claude API ──────────────────────────────────────────────

  defp call_claude(prompt) do
    api_key = System.get_env("ANTHROPIC_API_KEY")

    if is_nil(api_key) do
      Logger.warning("ANTHROPIC_API_KEY not set, skipping analyst explanation")
      {:error, :no_api_key}
    else
      case Req.post("https://api.anthropic.com/v1/messages",
        json: %{
          model: @model,
          max_tokens: 300,
          messages: [%{role: "user", content: prompt}]
        },
        headers: [
          {"x-api-key", api_key},
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

  defp format_number(val) when is_integer(val) do
    val
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})/, "\\1,")
    |> String.reverse()
    |> String.trim_leading(",")
  end

  defp format_number(val), do: to_string(val)
end
