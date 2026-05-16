defmodule Pageless.PayloadNormalizer do
  @moduledoc """
  Normalizes vendor webhook payloads into canonical alert envelopes.
  """

  alias Pageless.AlertEnvelope

  @max_alerts 50

  @type normalize_error ::
          {:malformed, atom() | String.t()}
          | {:unsupported_version, String.t()}
          | {:too_many_alerts, pos_integer()}
          | :empty_alerts

  @doc "Normalizes a Prometheus Alertmanager webhook payload into alert envelopes."
  @spec normalize_alertmanager(map()) ::
          {:ok, [AlertEnvelope.t()]} | {:error, normalize_error()}
  def normalize_alertmanager(payload) when is_map(payload), do: do_normalize_alertmanager(payload)

  @doc "Normalizes a PagerDuty Webhooks v3 payload into an alert envelope."
  @spec normalize_pagerduty(map()) :: {:ok, AlertEnvelope.t()} | {:error, normalize_error()}
  def normalize_pagerduty(payload) when is_map(payload), do: do_normalize_pagerduty(payload)

  defp do_normalize_alertmanager(%{"version" => version}) when version not in ["4", nil] do
    {:error, {:unsupported_version, version}}
  end

  defp do_normalize_alertmanager(%{"alerts" => []}), do: {:error, :empty_alerts}

  defp do_normalize_alertmanager(payload) when not is_map_key(payload, "alerts"),
    do: {:error, {:malformed, :alerts}}

  defp do_normalize_alertmanager(%{"alerts" => alerts}) when length(alerts) > @max_alerts do
    {:error, {:too_many_alerts, length(alerts)}}
  end

  defp do_normalize_alertmanager(%{"alerts" => alerts} = payload) when is_list(alerts) do
    alerts
    |> Enum.reduce_while({:ok, []}, fn alert, {:ok, envelopes} ->
      case build_alertmanager_envelope(payload, alert) do
        {:ok, envelope} -> {:cont, {:ok, [envelope | envelopes]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, envelopes} -> {:ok, Enum.reverse(envelopes)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_normalize_pagerduty(
         %{"event" => %{"data" => %{"id" => incident_id} = data} = event} = payload
       )
       when is_binary(incident_id) do
    attrs = %{
      alert_id: Ecto.UUID.generate(),
      source: :pagerduty,
      source_ref: incident_id,
      fingerprint: incident_id,
      received_at: DateTime.utc_now(),
      started_at: parse_datetime(event["occurred_at"]),
      status: pagerduty_status(event["event_type"]),
      severity: pagerduty_severity(data["urgency"]),
      alert_class: parse_alert_class([data["title"], get_in(data, ["priority", "summary"])]),
      title: data["title"] || "PagerDuty incident #{data["number"]}",
      service: get_in(data, ["service", "summary"]),
      labels: pagerduty_labels(data),
      annotations: %{},
      payload_raw: payload
    }

    attrs
    |> AlertEnvelope.new()
    |> normalize_envelope_result()
  end

  defp do_normalize_pagerduty(%{"event" => %{"data" => data}}) when is_map(data),
    do: {:error, {:malformed, :incident_id}}

  defp do_normalize_pagerduty(%{"event" => event}) when is_map(event),
    do: {:error, {:malformed, :event_data}}

  defp do_normalize_pagerduty(_payload), do: {:error, {:malformed, :event}}

  defp build_alertmanager_envelope(payload, alert) when is_map(alert) do
    labels = Map.get(alert, "labels", %{})
    annotations = Map.get(alert, "annotations", %{})

    attrs = %{
      alert_id: Ecto.UUID.generate(),
      source: :alertmanager,
      source_ref: payload["groupKey"],
      fingerprint: fingerprint_from_labels(labels),
      received_at: DateTime.utc_now(),
      started_at: parse_datetime(alert["startsAt"]),
      status: alertmanager_status(alert["status"]),
      severity: parse_severity(labels["severity"]),
      alert_class: parse_alert_class([labels["alertname"], labels, annotations]),
      title: annotations["summary"] || labels["alertname"] || "Untitled alert",
      service: labels["service"],
      labels: labels,
      annotations: annotations,
      payload_raw: payload
    }

    attrs
    |> AlertEnvelope.new()
    |> normalize_envelope_result()
  end

  defp build_alertmanager_envelope(_payload, _alert), do: {:error, {:malformed, :alerts}}

  defp normalize_envelope_result({:ok, envelope}), do: {:ok, envelope}

  defp normalize_envelope_result({:error, {:missing_field, field}}),
    do: {:error, {:malformed, field}}

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      {:error, _reason} -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp alertmanager_status("resolved"), do: :resolved
  defp alertmanager_status(_status), do: :firing

  defp pagerduty_status(event_type)
       when event_type in ["incident.resolved", "incident.acknowledged"],
       do: :resolved

  defp pagerduty_status(_event_type), do: :firing

  defp parse_severity(value) when is_binary(value) do
    case String.downcase(value) do
      "critical" -> :critical
      "high" -> :high
      "warning" -> :medium
      "medium" -> :medium
      "low" -> :low
      "info" -> :info
      _other -> :medium
    end
  end

  defp parse_severity(_value), do: :medium

  defp pagerduty_severity("high"), do: :high
  defp pagerduty_severity("low"), do: :low
  defp pagerduty_severity(_urgency), do: :medium

  defp pagerduty_labels(data) do
    %{
      "alertname" => data["title"],
      "incident_id" => data["id"],
      "urgency" => data["urgency"],
      "priority" => get_in(data, ["priority", "summary"]) || "unknown"
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp fingerprint_from_labels(labels) do
    [
      Map.get(labels, "service", "_unknown"),
      Map.get(labels, "alertname", "_unknown"),
      Map.get(labels, "severity", "_unknown"),
      Map.get(labels, "status", "_unknown")
    ]
    |> Enum.join(":")
  end

  defp parse_alert_class(parts) do
    text =
      parts
      |> List.wrap()
      |> Enum.map_join(" ", &inspectable_text/1)
      |> String.downcase()

    cond do
      String.contains?(text, "down") and deploy_hint?(text) -> :service_down_with_recent_deploy
      String.contains?(text, "down") -> :service_down
      String.contains?(text, ["latency", "slow", "timeout"]) -> :latency_creep
      String.contains?(text, ["pool", "connection", "db"]) -> :db_pool_exhaustion
      true -> :unknown
    end
  end

  defp deploy_hint?(text), do: String.contains?(text, ["deploy", "version"])

  defp inspectable_text(value) when is_binary(value), do: value
  defp inspectable_text(value) when is_map(value), do: value |> Map.values() |> Enum.join(" ")
  defp inspectable_text(nil), do: ""
  defp inspectable_text(value), do: to_string(value)
end
