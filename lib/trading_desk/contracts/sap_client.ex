defmodule TradingDesk.Contracts.SapClient do
  @moduledoc """
  Pure data retrieval from SAP. Fetches contract records and open positions.
  No comparison logic — that belongs in the Validator.

  All calls are on-network only (SAP_API_BASE is an internal endpoint).
  No data leaves the network boundary.

  Returns raw SAP data as maps for Elixir to compare against extracted clauses.
  """

  require Logger

  @sap_timeout 15_000

  @type sap_contract :: %{
    contract_number: String.t(),
    vendor_name: String.t() | nil,
    customer_name: String.t() | nil,
    material_group: String.t() | nil,
    valid_from: Date.t() | nil,
    valid_to: Date.t() | nil,
    target_quantity: number() | nil,
    target_unit: String.t() | nil,
    condition_records: [%{parameter: atom(), value: number(), unit: String.t()}],
    open_quantity: number() | nil,
    delivered_quantity: number() | nil,
    currency: String.t(),
    fetched_at: DateTime.t()
  }

  @doc """
  Fetch a SAP contract by its contract number.
  Returns {:ok, sap_contract} or {:error, reason}.
  """
  def fetch_contract(contract_number) do
    with {:ok, base} <- sap_base() do
      url = "#{base}/api/v1/contracts/#{contract_number}"
      case sap_get(url) do
        {:ok, data} -> {:ok, normalize_contract(data)}
        error -> error
      end
    end
  end

  @doc """
  Search for a SAP contract by counterparty name and product group.
  Returns {:ok, sap_contract} or {:error, reason}.
  """
  def search_contract(counterparty, product_group) do
    with {:ok, base} <- sap_base() do
      url = "#{base}/api/v1/contracts/search"
      case sap_get(url, %{counterparty: counterparty, product_group: to_string(product_group)}) do
        {:ok, data} -> {:ok, normalize_contract(data)}
        error -> error
      end
    end
  end

  @doc """
  Fetch the current open position (undelivered quantity) for a counterparty.
  Returns {:ok, %{open_quantity: float, delivered_quantity: float, target_quantity: float}}
  """
  def fetch_open_position(counterparty, product_group) do
    with {:ok, base} <- sap_base() do
      url = "#{base}/api/v1/open-positions"
      case sap_get(url, %{counterparty: counterparty, product_group: to_string(product_group)}) do
        {:ok, data} ->
          {:ok, %{
            open_quantity: to_float(data[:open_quantity]),
            delivered_quantity: to_float(data[:delivered_quantity]),
            target_quantity: to_float(data[:target_quantity]),
            fetched_at: DateTime.utc_now()
          }}
        error -> error
      end
    end
  end

  @doc """
  Bulk-fetch open positions for multiple counterparties.
  Uses Task.async_stream for parallel fetching.
  """
  def fetch_open_positions(counterparties, product_group) do
    results =
      counterparties
      |> Task.async_stream(
        fn cp -> {cp, fetch_open_position(cp, product_group)} end,
        max_concurrency: 4,
        timeout: @sap_timeout + 5_000
      )
      |> Enum.map(fn
        {:ok, result} -> result
        {:exit, reason} -> {:error, {:task_failed, reason}}
      end)

    succeeded = Enum.filter(results, fn {_cp, r} -> match?({:ok, _}, r) end)
    failed = Enum.reject(results, fn {_cp, r} -> match?({:ok, _}, r) end)

    %{
      positions: Map.new(succeeded, fn {cp, {:ok, pos}} -> {cp, pos} end),
      failed: Enum.map(failed, fn {cp, {:error, r}} -> {cp, r} end),
      fetched_at: DateTime.utc_now()
    }
  end

  @doc "Check if SAP is configured and reachable"
  def available? do
    case sap_base() do
      {:ok, base} ->
        case Req.get("#{base}/api/v1/health",
               receive_timeout: 5_000,
               connect_options: [transport_opts: [verify: :verify_peer]]
             ) do
          {:ok, %{status: 200}} -> true
          _ -> false
        end
      _ -> false
    end
  end

  # --- Private: HTTP layer ---

  defp sap_base do
    case System.get_env("SAP_API_BASE") do
      nil -> {:error, :sap_not_configured}
      "" -> {:error, :sap_not_configured}
      base -> {:ok, String.trim_trailing(base, "/")}
    end
  end

  defp sap_get(url, params \\ %{}) do
    sap_user = System.get_env("SAP_API_USER")
    sap_pass = System.get_env("SAP_API_PASS")

    headers =
      if sap_user && sap_pass do
        [{"authorization", "Basic " <> Base.encode64("#{sap_user}:#{sap_pass}")}]
      else
        []
      end

    case Req.get(url,
           params: params,
           headers: headers,
           receive_timeout: @sap_timeout,
           connect_options: [transport_opts: [verify: :verify_peer]]
         ) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        {:ok, safe_atomize(body)}

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, %{status: status, body: body}} ->
        Logger.error("SAP API #{status}: #{inspect(body)}")
        {:error, {:sap_error, status}}

      {:error, reason} ->
        Logger.error("SAP request failed: #{inspect(reason)}")
        {:error, {:sap_unreachable, reason}}
    end
  end

  # --- Normalization ---

  defp normalize_contract(data) do
    %{
      contract_number: data[:contract_number] || data[:contract_id],
      vendor_name: data[:vendor_name],
      customer_name: data[:customer_name],
      material_group: data[:material_group],
      valid_from: parse_date(data[:valid_from]),
      valid_to: parse_date(data[:valid_to]),
      target_quantity: to_float(data[:target_quantity]),
      target_unit: data[:target_unit] || "TON",
      condition_records: normalize_conditions(data[:condition_records] || data[:prices] || []),
      open_quantity: to_float(data[:open_quantity]),
      delivered_quantity: to_float(data[:delivered_quantity]),
      currency: data[:currency] || "USD",
      fetched_at: DateTime.utc_now()
    }
  end

  defp normalize_conditions(records) when is_list(records) do
    Enum.map(records, fn rec ->
      %{
        parameter: safe_atom(rec[:parameter] || rec[:condition_type]),
        value: to_float(rec[:value] || rec[:amount]),
        unit: rec[:unit] || rec[:per_unit] || "$/ton"
      }
    end)
  end
  defp normalize_conditions(_), do: []

  defp parse_date(nil), do: nil
  defp parse_date(%Date{} = d), do: d
  defp parse_date(str) when is_binary(str) do
    case Date.from_iso8601(str) do
      {:ok, date} -> date
      _ -> nil
    end
  end
  defp parse_date(_), do: nil

  defp to_float(nil), do: 0.0
  defp to_float(v) when is_float(v), do: v
  defp to_float(v) when is_integer(v), do: v * 1.0
  defp to_float(v) when is_binary(v) do
    case Float.parse(String.replace(v, ",", "")) do
      {f, _} -> f
      :error -> 0.0
    end
  end
  defp to_float(_), do: 0.0

  # Only convert known keys to atoms — never trust external input to create atoms
  @known_keys ~w(
    contract_number contract_id vendor_name customer_name material_group
    valid_from valid_to target_quantity target_unit condition_records
    open_quantity delivered_quantity currency prices condition_type
    parameter value amount unit per_unit
  )a |> Enum.map(&to_string/1) |> MapSet.new()

  defp safe_atomize(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_binary(key) ->
        if MapSet.member?(@known_keys, key) do
          {String.to_existing_atom(key), safe_atomize(value)}
        else
          {key, safe_atomize(value)}
        end
      {key, value} ->
        {key, safe_atomize(value)}
    end)
  end
  defp safe_atomize(list) when is_list(list), do: Enum.map(list, &safe_atomize/1)
  defp safe_atomize(value), do: value

  defp safe_atom(nil), do: nil
  defp safe_atom(a) when is_atom(a), do: a
  defp safe_atom(s) when is_binary(s) do
    try do
      String.to_existing_atom(s)
    rescue
      ArgumentError -> String.to_atom(s)
    end
  end
end
