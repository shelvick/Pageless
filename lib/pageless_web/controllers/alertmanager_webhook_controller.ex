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
    dedup_server = conn.assigns[:webhook_dedup] || Pageless.WebhookDedup

    with :ok <- check_gemini_budget(conn),
         :ok <- check_alert_tree_utilization(conn) do
      create_after_budget_check(conn, params, broker, dedup_server)
    end
  end

  defp create_after_budget_check(conn, params, broker, dedup_server) do
    case PayloadNormalizer.normalize_alertmanager(params) do
      {:ok, envelopes} ->
        {received, deduplicated} = process_batch(envelopes, broker, dedup_server)

        conn
        |> put_status(:accepted)
        |> json(%{received: received, deduplicated: deduplicated})

      {:error, :empty_alerts} ->
        conn
        |> put_status(:accepted)
        |> json(%{received: 0, deduplicated: 0})

      {:error, {:too_many_alerts, count}} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "too_many_alerts", limit: 50, received: count})

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

  defp check_alert_tree_utilization(conn) do
    alert_tree = conn.assigns[:alert_tree] || Pageless.AlertTree

    if Pageless.Sup.AlertTree.utilization(alert_tree) > 0.8 do
      conn
      |> put_resp_header("retry-after", "1")
      |> put_status(:service_unavailable)
      |> json(%{error: "overloaded", retry_after_ms: 1000})
    else
      :ok
    end
  end

  defp process_batch(envelopes, broker, dedup_server) do
    Enum.reduce(envelopes, {0, 0}, fn envelope, {received, deduplicated} ->
      case Pageless.WebhookDedup.check_or_record(dedup_server, :alertmanager, envelope) do
        :ok ->
          Phoenix.PubSub.broadcast(broker, "alerts", {:alert_received, envelope})
          {received + 1, deduplicated}

        {:duplicate, _age_ms} ->
          {received, deduplicated + 1}
      end
    end)
  end
end
