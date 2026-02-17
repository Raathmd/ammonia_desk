defmodule AmmoniaDesk.Data.API.USACE do
  @moduledoc """
  USACE Lock Performance Monitoring System integration.

  Fetches lock delay and status data from the Army Corps of Engineers.
  Maps to `lock_hrs` solver variable — total expected delay hours through
  the lock system between NOLA terminals and delivery points.

  ## Data Sources

  The USACE Lock Performance Monitoring System (LPMS) provides:
    - Average lock processing times
    - Current queue lengths (vessels waiting)
    - Lock status (open, closed, restricted)
    - Historical delay averages

  Primary endpoint: https://corpslocks.usace.army.mil/lpwb/f?p=121:1

  The LPMS also provides data via the USACE Navigation Data Center (NDC):
    https://ndc.ops.usace.army.mil/

  ## Locks on the Route

  NOLA → Memphis route passes through:
    - Old River Lock (GIWW connection)
    - Lock 25 (Mississippi near Winfield, MO) — StL route
    - Lock 27 (near Granite City, IL) — StL route
    - Lock 52/53 (Ohio River) — alternate routing

  ## Note

  The USACE API requires specific access credentials. This module
  supports both the official API and a web scraping fallback for
  the publicly available lock status pages.
  """

  require Logger

  @locks %{
    lock_25: %{
      name: "Lock 25",
      river: "Mississippi",
      mile: 241.4,
      route: :stl
    },
    lock_27: %{
      name: "Lock 27 (Chain of Rocks)",
      river: "Mississippi",
      mile: 185.5,
      route: :stl
    },
    old_river: %{
      name: "Old River Lock",
      river: "Mississippi/Atchafalaya",
      mile: 302.8,
      route: :both
    },
    lock_52: %{
      name: "Lock 52 (Olmsted)",
      river: "Ohio",
      mile: 964.4,
      route: :alternate
    }
  }

  @ndc_base_url "https://ndc.ops.usace.army.mil/api"

  @doc """
  Fetch current lock conditions.

  Returns `{:ok, %{lock_hrs: float, locks: map}}` or `{:error, reason}`.

  `lock_hrs` is the total expected delay hours for a barge transiting
  from NOLA terminals to the furthest delivery point (St. Louis).
  """
  @spec fetch() :: {:ok, map()} | {:error, term()}
  def fetch do
    case fetch_lock_status() do
      {:ok, lock_data} ->
        total_delay = compute_total_delay(lock_data)

        {:ok, %{
          lock_hrs: total_delay,
          locks: lock_data
        }}

      {:error, reason} ->
        # Fall back to LPMS web scraping
        case fetch_lpms_fallback() do
          {:ok, data} -> {:ok, data}
          {:error, _} -> {:error, reason}
        end
    end
  end

  @doc "Fetch lock status from NDC API."
  @spec fetch_lock_status() :: {:ok, map()} | {:error, term()}
  def fetch_lock_status do
    url = "#{@ndc_base_url}/lockstatus"

    case http_get(url) do
      {:ok, body} -> parse_lock_status(body)
      {:error, _} = err -> err
    end
  end

  # ──────────────────────────────────────────────────────────
  # PARSING
  # ──────────────────────────────────────────────────────────

  defp parse_lock_status(body) do
    case Jason.decode(body) do
      {:ok, data} when is_list(data) ->
        lock_data =
          @locks
          |> Enum.map(fn {key, lock_info} ->
            matching = Enum.find(data, fn entry ->
              entry_name = entry["lockName"] || entry["name"] || ""
              String.contains?(String.downcase(entry_name), String.downcase(lock_info.name))
            end)

            status = if matching do
              %{
                name: lock_info.name,
                status: parse_status(matching["status"] || matching["operationalStatus"]),
                avg_delay_hrs: parse_delay(matching["averageDelay"] || matching["avgProcessingTime"]),
                queue_length: matching["queueLength"] || matching["vesselCount"] || 0,
                last_updated: matching["lastUpdated"]
              }
            else
              %{
                name: lock_info.name,
                status: :unknown,
                avg_delay_hrs: default_delay(key),
                queue_length: 0,
                last_updated: nil
              }
            end

            {key, status}
          end)
          |> Map.new()

        {:ok, lock_data}

      {:ok, _} ->
        {:error, :unexpected_format}

      {:error, reason} ->
        {:error, {:parse_failed, reason}}
    end
  end

  defp parse_status(nil), do: :unknown
  defp parse_status(status) when is_binary(status) do
    case String.downcase(status) do
      s when s in ["open", "operational"] -> :open
      s when s in ["closed", "inoperative"] -> :closed
      s when s in ["restricted", "limited"] -> :restricted
      _ -> :unknown
    end
  end
  defp parse_status(_), do: :unknown

  defp parse_delay(nil), do: nil
  defp parse_delay(v) when is_number(v), do: v / 1.0
  defp parse_delay(v) when is_binary(v) do
    case Float.parse(v) do
      {f, _} -> f
      :error -> nil
    end
  end

  defp default_delay(:lock_25), do: 4.0
  defp default_delay(:lock_27), do: 3.0
  defp default_delay(:old_river), do: 2.0
  defp default_delay(:lock_52), do: 3.0
  defp default_delay(_), do: 3.0

  defp compute_total_delay(lock_data) do
    # Sum delays for locks on the StL route (worst case)
    lock_data
    |> Enum.filter(fn {key, _} ->
      lock_meta = @locks[key]
      lock_meta && lock_meta.route in [:stl, :both]
    end)
    |> Enum.reduce(0.0, fn {_key, status}, acc ->
      delay = status.avg_delay_hrs || default_delay(:lock_25)

      # Closed locks add major delay (assume 24hr until reopened)
      case status.status do
        :closed -> acc + 24.0
        :restricted -> acc + delay * 1.5
        _ -> acc + delay
      end
    end)
  end

  # ──────────────────────────────────────────────────────────
  # LPMS FALLBACK (web scraping)
  # ──────────────────────────────────────────────────────────

  defp fetch_lpms_fallback do
    url = "https://corpslocks.usace.army.mil/lpwb/f?p=121:6"

    case http_get(url) do
      {:ok, body} ->
        # Parse HTML for lock delay tables
        total_delay = estimate_delay_from_html(body)

        {:ok, %{
          lock_hrs: total_delay,
          locks: %{
            source: :lpms_fallback,
            estimated: true
          }
        }}

      {:error, _} ->
        # Final fallback: use historical average
        Logger.warning("USACE: all sources failed, using historical average")
        {:ok, %{
          lock_hrs: 12.0,
          locks: %{source: :historical_default, estimated: true}
        }}
    end
  end

  defp estimate_delay_from_html(html) when is_binary(html) do
    # Look for delay values in the HTML
    # This is a rough extraction — production would use a proper HTML parser
    delays =
      Regex.scan(~r/(\d+\.?\d*)\s*(?:hours?|hrs?)/i, html)
      |> Enum.map(fn [_, v] ->
        case Float.parse(v) do
          {f, _} -> f
          :error -> 0.0
        end
      end)

    if length(delays) > 0 do
      Enum.sum(delays) / length(delays) * 3  # rough estimate for 3 locks
    else
      12.0  # historical average
    end
  end
  defp estimate_delay_from_html(_), do: 12.0

  # ──────────────────────────────────────────────────────────
  # HTTP
  # ──────────────────────────────────────────────────────────

  defp http_get(url) do
    case Req.get(url, receive_timeout: 20_000) do
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
