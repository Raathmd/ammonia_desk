defmodule TradingDesk.Data.API.Market do
  @moduledoc """
  Market price API integration for ammonia trading.

  Fetches ammonia and fertilizer spot/forward prices from market data
  providers. Maps to solver variables:

    - nola_buy: NH3 NOLA barge purchase price ($/ton)
    - sell_stl: NH3 St. Louis delivered price ($/ton)
    - sell_mem: NH3 Memphis delivered price ($/ton)

  ## Data Sources

  Ammonia market prices come from multiple sources:

  1. **Argus Media** (primary) — Argus Nitrogen (weekly, Friday)
     - NOLA barge: Argus assessment code `PA0010760`
     - Tampa CFR: `PA0010770`
     - Yuzhnyy FOB: `PA0010780`

  2. **ICIS/Profercy** (secondary) — Weekly Nitrogen Index
     - Profercy World Nitrogen Index
     - US Gulf ammonia barge assessment

  3. **Green Markets** (tertiary) — Bloomberg/S&P
     - US ammonia barge delivered prices

  4. **CME Group** — Fertilizer futures
     - UAN/Urea futures (ammonia futures limited liquidity)

  ## Authentication

  Most fertilizer price feeds are subscription-based.
  Configure via environment variables:
    - `ARGUS_API_KEY`: Argus Media API access
    - `ICIS_API_KEY`: ICIS/Profercy access
    - `MARKET_FEED_URL`: Custom price feed endpoint (internal or third-party)
  """

  require Logger

  @doc """
  Fetch current ammonia market prices.

  Returns `{:ok, %{nola_buy: float, sell_stl: float, sell_mem: float, ...}}`
  or `{:error, reason}`.

  Tries sources in order: Argus → ICIS → custom feed → last known.
  """
  @spec fetch() :: {:ok, map()} | {:error, term()}
  def fetch do
    cond do
      argus_configured?() ->
        fetch_argus()

      icis_configured?() ->
        fetch_icis()

      custom_feed_configured?() ->
        fetch_custom_feed()

      true ->
        Logger.warning("Market: no price feed configured")
        {:error, :no_feed_configured}
    end
  end

  # ──────────────────────────────────────────────────────────
  # ARGUS MEDIA
  # ──────────────────────────────────────────────────────────

  @doc "Fetch from Argus Media API."
  @spec fetch_argus() :: {:ok, map()} | {:error, term()}
  def fetch_argus do
    api_key = System.get_env("ARGUS_API_KEY")
    base_url = System.get_env("ARGUS_API_URL") || "https://api.argusmedia.com/v2"

    url = "#{base_url}/prices?" <>
      URI.encode_query(%{
        "assessmentCodes" => "PA0010760,PA0010770",
        "latest" => "true"
      })

    headers = [
      {"Authorization", "Bearer #{api_key}"},
      {"Accept", "application/json"}
    ]

    case http_get(url, headers) do
      {:ok, body} -> parse_argus(body)
      {:error, _} = err -> err
    end
  end

  defp parse_argus(body) do
    case Jason.decode(body) do
      {:ok, %{"data" => prices}} when is_list(prices) ->
        nola_price = find_price(prices, "PA0010760")

        # Delivered prices are typically NOLA + freight + handling
        # Use configured spreads or derive from historical data
        nola_buy = nola_price[:mid] || nola_price[:close]

        if nola_buy do
          {:ok, %{
            nola_buy: nola_buy,
            sell_stl: nola_buy + default_stl_spread(),
            sell_mem: nola_buy + default_mem_spread(),
            source: :argus,
            as_of: nola_price[:date],
            nola_low: nola_price[:low],
            nola_high: nola_price[:high]
          }}
        else
          {:error, :no_nola_price}
        end

      _ ->
        {:error, :parse_failed}
    end
  end

  defp find_price(prices, code) do
    case Enum.find(prices, fn p -> p["assessmentCode"] == code end) do
      nil -> %{}
      p ->
        %{
          low: parse_num(p["low"]),
          high: parse_num(p["high"]),
          mid: parse_num(p["mid"]),
          close: parse_num(p["close"]),
          date: p["date"]
        }
    end
  end

  # ──────────────────────────────────────────────────────────
  # ICIS / PROFERCY
  # ──────────────────────────────────────────────────────────

  @doc "Fetch from ICIS/Profercy API."
  @spec fetch_icis() :: {:ok, map()} | {:error, term()}
  def fetch_icis do
    api_key = System.get_env("ICIS_API_KEY")
    base_url = System.get_env("ICIS_API_URL") || "https://api.icis.com/v1"

    url = "#{base_url}/prices/ammonia?" <>
      URI.encode_query(%{
        "region" => "us-gulf",
        "latest" => "true"
      })

    headers = [
      {"X-API-Key", api_key},
      {"Accept", "application/json"}
    ]

    case http_get(url, headers) do
      {:ok, body} -> parse_icis(body)
      {:error, _} = err -> err
    end
  end

  defp parse_icis(body) do
    case Jason.decode(body) do
      {:ok, %{"prices" => prices}} when is_list(prices) ->
        us_gulf = Enum.find(prices, fn p ->
          p["region"] == "US Gulf" and p["product"] == "Ammonia"
        end)

        if us_gulf do
          nola_buy = parse_num(us_gulf["midpoint"] || us_gulf["close"])

          {:ok, %{
            nola_buy: nola_buy,
            sell_stl: nola_buy + default_stl_spread(),
            sell_mem: nola_buy + default_mem_spread(),
            source: :icis,
            as_of: us_gulf["date"]
          }}
        else
          {:error, :no_us_gulf_price}
        end

      _ ->
        {:error, :parse_failed}
    end
  end

  # ──────────────────────────────────────────────────────────
  # CUSTOM FEED (internal or third-party)
  # ──────────────────────────────────────────────────────────

  @doc "Fetch from a custom/internal price feed."
  @spec fetch_custom_feed() :: {:ok, map()} | {:error, term()}
  def fetch_custom_feed do
    url = System.get_env("MARKET_FEED_URL")
    api_key = System.get_env("MARKET_FEED_KEY")

    headers = if api_key do
      [{"Authorization", "Bearer #{api_key}"}, {"Accept", "application/json"}]
    else
      [{"Accept", "application/json"}]
    end

    case http_get(url, headers) do
      {:ok, body} -> parse_custom_feed(body)
      {:error, _} = err -> err
    end
  end

  defp parse_custom_feed(body) do
    case Jason.decode(body) do
      {:ok, data} when is_map(data) ->
        result = %{
          nola_buy: parse_num(data["nola_buy"] || data["nh3_nola"]),
          sell_stl: parse_num(data["sell_stl"] || data["nh3_stl_delivered"]),
          sell_mem: parse_num(data["sell_mem"] || data["nh3_mem_delivered"]),
          source: :custom_feed,
          as_of: data["timestamp"] || data["date"]
        }

        if result.nola_buy do
          {:ok, result}
        else
          {:error, :no_nola_price}
        end

      _ ->
        {:error, :parse_failed}
    end
  end

  # ──────────────────────────────────────────────────────────
  # HELPERS
  # ──────────────────────────────────────────────────────────

  # Typical NOLA→StL delivered spread (freight + handling + margin)
  defp default_stl_spread, do: 90.0  # $/ton
  # Typical NOLA→Memphis delivered spread
  defp default_mem_spread, do: 65.0  # $/ton

  defp argus_configured?, do: System.get_env("ARGUS_API_KEY") not in [nil, ""]
  defp icis_configured?, do: System.get_env("ICIS_API_KEY") not in [nil, ""]
  defp custom_feed_configured?, do: System.get_env("MARKET_FEED_URL") not in [nil, ""]

  defp parse_num(nil), do: nil
  defp parse_num(v) when is_number(v), do: v / 1.0
  defp parse_num(v) when is_binary(v) do
    case Float.parse(v) do
      {f, _} -> f
      :error -> nil
    end
  end

  defp http_get(url, headers \\ []) do
    case Req.get(url, headers: headers, receive_timeout: 15_000) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        {:ok, body}

      {:ok, %{status: 200, body: body}} when is_map(body) ->
        {:ok, Jason.encode!(body)}

      {:ok, %{status: status}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, {:http_error, reason}}
    end
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  end
end
