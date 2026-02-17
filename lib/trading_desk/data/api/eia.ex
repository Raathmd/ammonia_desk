defmodule TradingDesk.Data.API.EIA do
  @moduledoc """
  EIA (Energy Information Administration) API integration.

  Fetches natural gas prices from the EIA open data API.
  Maps to `nat_gas` solver variable — Henry Hub spot price in $/MMBtu.

  Natural gas is a primary feedstock for ammonia production (Haber-Bosch
  process), so gas prices directly affect ammonia production costs and
  therefore NOLA buy prices.

  API documentation: https://www.eia.gov/opendata/
  API v2 docs: https://api.eia.gov/v2/

  ## Series

    - `NG.RNGWHHD.D` — Henry Hub Natural Gas Spot Price (daily)
    - `NG.RNGC1.D` — Natural Gas Futures Contract 1 (Nymex)
    - `NG.RNGWHHD.W` — Henry Hub weekly average

  ## Authentication

  Requires an API key from: https://www.eia.gov/opendata/register.php
  Set via `EIA_API_KEY` environment variable.
  """

  require Logger

  @base_url "https://api.eia.gov/v2"

  # Henry Hub spot price (daily)
  @series_spot "NG.RNGWHHD.D"
  # Nymex futures front month
  @series_futures "NG.RNGC1.D"

  @doc """
  Fetch current natural gas prices.

  Returns `{:ok, %{nat_gas: float, spot: float, futures: float, as_of: string}}`
  or `{:error, reason}`.

  Uses the Henry Hub spot price as the primary value.
  """
  @spec fetch() :: {:ok, map()} | {:error, term()}
  def fetch do
    api_key = System.get_env("EIA_API_KEY")

    if is_nil(api_key) or api_key == "" do
      fetch_fallback()
    else
      fetch_with_api(api_key)
    end
  end

  defp fetch_with_api(api_key) do
    url = "#{@base_url}/natural-gas/pri/fut/data/?" <>
      URI.encode_query(%{
        "api_key" => api_key,
        "frequency" => "daily",
        "data[0]" => "value",
        "facets[series][]" => @series_spot,
        "sort[0][column]" => "period",
        "sort[0][direction]" => "desc",
        "length" => "5"
      })

    case http_get(url) do
      {:ok, body} -> parse_eia_v2(body)
      {:error, _} = err -> err
    end
  end

  @doc """
  Fetch natural gas futures prices (front month).

  Returns `{:ok, %{futures_price: float, contract: string, as_of: string}}`
  """
  @spec fetch_futures() :: {:ok, map()} | {:error, term()}
  def fetch_futures do
    api_key = System.get_env("EIA_API_KEY")

    unless api_key do
      {:error, :api_key_not_configured}
    else
      url = "#{@base_url}/natural-gas/pri/fut/data/?" <>
        URI.encode_query(%{
          "api_key" => api_key,
          "frequency" => "daily",
          "data[0]" => "value",
          "facets[series][]" => @series_futures,
          "sort[0][column]" => "period",
          "sort[0][direction]" => "desc",
          "length" => "5"
        })

      case http_get(url) do
        {:ok, body} -> parse_eia_v2_futures(body)
        {:error, _} = err -> err
      end
    end
  end

  # ──────────────────────────────────────────────────────────
  # PARSING
  # ──────────────────────────────────────────────────────────

  defp parse_eia_v2(body) do
    case Jason.decode(body) do
      {:ok, %{"response" => %{"data" => [latest | _]}}} ->
        value = parse_price(latest["value"])

        {:ok, %{
          nat_gas: value,
          spot: value,
          as_of: latest["period"],
          series: latest["series"],
          unit: latest["units"] || "$/MMBtu"
        }}

      {:ok, %{"response" => %{"data" => []}}} ->
        {:error, :no_data}

      {:ok, %{"error" => error}} ->
        {:error, {:api_error, error}}

      {:error, reason} ->
        {:error, {:parse_failed, reason}}

      _ ->
        {:error, :unexpected_format}
    end
  end

  defp parse_eia_v2_futures(body) do
    case Jason.decode(body) do
      {:ok, %{"response" => %{"data" => [latest | _]}}} ->
        {:ok, %{
          futures_price: parse_price(latest["value"]),
          contract: latest["series"],
          as_of: latest["period"]
        }}

      _ ->
        {:error, :parse_failed}
    end
  end

  defp parse_price(nil), do: nil
  defp parse_price(v) when is_number(v), do: v / 1.0
  defp parse_price(v) when is_binary(v) do
    case Float.parse(v) do
      {f, _} -> f
      :error -> nil
    end
  end

  # ──────────────────────────────────────────────────────────
  # FALLBACK — FRED API (Federal Reserve Economic Data)
  #
  # If EIA API key not available, try FRED for Henry Hub data.
  # Series: MHHNGSP (monthly) or DHHNGSP (daily)
  # ──────────────────────────────────────────────────────────

  defp fetch_fallback do
    fred_key = System.get_env("FRED_API_KEY")

    if fred_key do
      url = "https://api.stlouisfed.org/fred/series/observations?" <>
        URI.encode_query(%{
          "series_id" => "DHHNGSP",
          "api_key" => fred_key,
          "file_type" => "json",
          "sort_order" => "desc",
          "limit" => "5"
        })

      case http_get(url) do
        {:ok, body} -> parse_fred(body)
        {:error, _} = err -> err
      end
    else
      Logger.warning("EIA: no API key configured (EIA_API_KEY or FRED_API_KEY)")
      {:error, :api_key_not_configured}
    end
  end

  defp parse_fred(body) do
    case Jason.decode(body) do
      {:ok, %{"observations" => [latest | _]}} ->
        value = parse_price(latest["value"])

        if value do
          {:ok, %{
            nat_gas: value,
            spot: value,
            as_of: latest["date"],
            source: :fred
          }}
        else
          {:error, :no_valid_data}
        end

      _ ->
        {:error, :parse_failed}
    end
  end

  # ──────────────────────────────────────────────────────────
  # HTTP
  # ──────────────────────────────────────────────────────────

  defp http_get(url) do
    case Req.get(url, receive_timeout: 15_000) do
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
