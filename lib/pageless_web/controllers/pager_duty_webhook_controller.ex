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

    case PayloadNormalizer.normalize_pagerduty(params) do
      {:ok, envelope} ->
        Phoenix.PubSub.broadcast(broker, "alerts", {:alert_received, envelope})

        conn
        |> put_status(:accepted)
        |> json(%{received: 1, alert_id: envelope.alert_id})

      {:error, {:malformed, field}} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "malformed_payload", field: to_string(field)})
    end
  end
end
