defmodule TradingDeskWeb.SapWebhookController do
  @moduledoc """
  Webhook endpoint for SAP push notifications.

  SAP triggers a ping to this endpoint when a contract position changes
  (e.g., a delivery is posted, a new contract is created, or open
  quantities are updated). This triggers an immediate refresh of the
  affected product group's positions from SAP OData.

  ## SAP Configuration

  In SAP, configure a Business Event (BAdI) or Change Pointer to call:

    POST /api/sap/ping
    Content-Type: application/json
    Authorization: Bearer <webhook_token>

    {
      "event": "position_changed",
      "product_group": "ammonia",
      "contract_id": "4600000101",
      "timestamp": "2026-02-18T14:30:00Z"
    }

  The endpoint accepts any JSON body. The only field used is
  `product_group` (optional — if omitted, refreshes all groups).

  ## Authentication

  Set SAP_WEBHOOK_TOKEN env var. The request must include:
    Authorization: Bearer <token>

  If no token is configured, the endpoint accepts all requests
  (development mode).
  """

  use Phoenix.Controller, namespace: TradingDeskWeb

  require Logger

  alias TradingDesk.Contracts.SapRefreshScheduler

  @doc """
  Handle SAP ping — triggers immediate position refresh.

  Responds with 200 OK immediately. The actual refresh runs
  asynchronously via the SapRefreshScheduler.
  """
  def ping(conn, params) do
    case authenticate(conn) do
      :ok ->
        Logger.info("SAP webhook ping received: #{inspect(params)}")

        SapRefreshScheduler.sap_ping(params)

        conn
        |> put_status(200)
        |> json(%{
          status: "ok",
          message: "SAP position refresh triggered",
          product_group: params["product_group"],
          received_at: DateTime.utc_now() |> DateTime.to_iso8601()
        })

      :unauthorized ->
        conn
        |> put_status(401)
        |> json(%{error: "unauthorized", message: "Invalid or missing webhook token"})
    end
  end

  @doc """
  Health check — returns SAP refresh scheduler status.
  """
  def status(conn, _params) do
    case authenticate(conn) do
      :ok ->
        status = SapRefreshScheduler.status()

        conn
        |> put_status(200)
        |> json(%{
          sap_connected: status.sap_connected,
          scheduler_enabled: status.enabled,
          refresh_interval_ms: status.interval_ms,
          last_refresh_at: format_datetime(status.last_refresh_at),
          refresh_count: status.refresh_count
        })

      :unauthorized ->
        conn
        |> put_status(401)
        |> json(%{error: "unauthorized"})
    end
  end

  defp authenticate(conn) do
    token = System.get_env("SAP_WEBHOOK_TOKEN")

    if is_nil(token) or token == "" do
      # No token configured — accept all (dev mode)
      :ok
    else
      case get_req_header(conn, "authorization") do
        ["Bearer " <> provided] when provided == token -> :ok
        _ -> :unauthorized
      end
    end
  end

  defp format_datetime(nil), do: nil
  defp format_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
end
