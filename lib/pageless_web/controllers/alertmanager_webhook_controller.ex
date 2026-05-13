defmodule PagelessWeb.AlertmanagerWebhookController do
  @moduledoc """
  Accepts Alertmanager webhook payloads and broadcasts normalized alerts.
  """

  use Phoenix.Controller, formats: [:json]

  alias Pageless.PayloadNormalizer

  @doc "Handles inbound Alertmanager webhook POSTs."
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, params) do
    broker = conn.assigns[:pubsub_broker] || Pageless.PubSub

    case PayloadNormalizer.normalize_alertmanager(params) do
      {:ok, envelopes} ->
        Enum.each(envelopes, fn envelope ->
          Phoenix.PubSub.broadcast(broker, "alerts", {:alert_received, envelope})
        end)

        conn
        |> put_status(:accepted)
        |> json(%{received: length(envelopes)})

      {:error, :empty_alerts} ->
        conn
        |> put_status(:accepted)
        |> json(%{received: 0})

      {:error, {:malformed, field}} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "malformed_payload", field: to_string(field)})

      {:error, {:unsupported_version, version}} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "unsupported_version", version: version})
    end
  end
end
