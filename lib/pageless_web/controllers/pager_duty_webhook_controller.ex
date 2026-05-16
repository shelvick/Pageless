defmodule PagelessWeb.PagerDutyWebhookController do
  @moduledoc """
  Accepts PagerDuty webhook payloads and broadcasts normalized alerts.
  """

  use Phoenix.Controller, formats: [:json]

  alias Pageless.PayloadNormalizer

  @doc "Handles inbound PagerDuty webhook POSTs."
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, params) do
    broker = conn.assigns[:pubsub_broker] || Pageless.PubSub
    dedup_server = conn.assigns[:webhook_dedup] || Pageless.WebhookDedup

    with :ok <- check_gemini_budget(conn) do
      create_after_budget_check(conn, params, broker, dedup_server)
    end
  end

  defp create_after_budget_check(conn, params, broker, dedup_server) do
    case PayloadNormalizer.normalize_pagerduty(params) do
      {:ok, envelope} ->
        case Pageless.WebhookDedup.check_or_record(dedup_server, :pagerduty, envelope) do
          :ok ->
            Phoenix.PubSub.broadcast(broker, "alerts", {:alert_received, envelope})

            conn
            |> put_status(:accepted)
            |> json(%{received: 1, alert_id: envelope.alert_id})

          {:duplicate, age_ms} ->
            conn
            |> put_status(:accepted)
            |> json(%{received: 0, deduplicated: true, age_ms: age_ms})
        end

      {:error, {:malformed, field}} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "malformed_payload", field: to_string(field)})
    end
  end

  defp check_gemini_budget(conn) do
    budget = conn.assigns[:gemini_budget] || Pageless.GeminiBudget

    if Pageless.GeminiBudget.current(budget) >= Pageless.GeminiBudget.cap(budget) do
      conn
      |> put_resp_header("retry-after", "86400")
      |> put_status(:service_unavailable)
      |> json(%{error: "gemini_budget_exhausted", retry_after_ms: 86_400_000})
    else
      :ok
    end
  end
end
