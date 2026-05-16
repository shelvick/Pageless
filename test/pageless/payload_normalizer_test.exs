defmodule Pageless.PayloadNormalizerTest do
  @moduledoc "Fixture-driven tests for vendor webhook payload normalization."

  use ExUnit.Case, async: true

  alias Pageless.AlertEnvelope
  alias Pageless.PayloadNormalizer

  describe "normalize_alertmanager/1" do
    test "normalizes a realistic v4 firing payload into one alert envelope" do
      payload = fixture("alertmanager_v4_firing.json")

      assert {:ok, [envelope]} = PayloadNormalizer.normalize_alertmanager(payload)
      assert envelope.__struct__ == AlertEnvelope
      assert Ecto.UUID.cast(envelope.alert_id) == {:ok, envelope.alert_id}
      assert envelope.source == :alertmanager
      assert envelope.source_ref == payload["groupKey"]
      assert envelope.fingerprint == "payments-api:PaymentsAPIDown:critical:_unknown"
      assert %DateTime{} = envelope.received_at
      assert envelope.started_at == ~U[2026-05-13 03:44:12Z]
      assert envelope.status == :firing
      assert envelope.severity == :critical
      assert envelope.alert_class == :service_down_with_recent_deploy
      assert envelope.title == "payments-api health check failing"
      assert envelope.service == "payments-api"
      assert envelope.labels["service"] == "payments-api"
      assert envelope.annotations["description"] =~ "deploy v2.4.1"
      assert envelope.payload_raw == payload
    end

    test "normalizes every alert in a batch while preserving order and batch context" do
      payload = fixture("alertmanager_v4_batch.json")

      assert {:ok, [latency, db_pool]} = PayloadNormalizer.normalize_alertmanager(payload)

      assert [latency.title, db_pool.title] == [
               "payments-api p95 latency above SLO",
               "orders-db connection pool exhausted"
             ]

      assert [latency.alert_class, db_pool.alert_class] == [:latency_creep, :db_pool_exhaustion]

      assert [latency.source_ref, db_pool.source_ref] == [
               payload["groupKey"],
               payload["groupKey"]
             ]

      assert [latency.payload_raw, db_pool.payload_raw] == [payload, payload]
    end

    test "maps a resolved alert to resolved status" do
      assert {:ok, [envelope]} =
               "alertmanager_v4_resolved.json"
               |> fixture()
               |> PayloadNormalizer.normalize_alertmanager()

      assert envelope.status == :resolved
    end

    test "returns empty-alerts for an empty alerts array" do
      assert {:error, :empty_alerts} =
               "alertmanager_v4_empty_alerts.json"
               |> fixture()
               |> PayloadNormalizer.normalize_alertmanager()
    end

    test "rejects unsupported Alertmanager versions" do
      payload = fixture("alertmanager_v4_firing.json") |> Map.put("version", "3")

      assert {:error, {:unsupported_version, "3"}} =
               PayloadNormalizer.normalize_alertmanager(payload)
    end

    test "reports missing alerts key as malformed" do
      payload = fixture("alertmanager_v4_firing.json") |> Map.delete("alerts")

      assert {:error, {:malformed, :alerts}} = PayloadNormalizer.normalize_alertmanager(payload)
    end

    test "rejects Alertmanager batch above 50 alerts" do
      payload = payload_with_alert_count(51)

      assert {:error, {:too_many_alerts, 51}} = PayloadNormalizer.normalize_alertmanager(payload)
    end

    test "accepts Alertmanager batch of exactly 50 alerts" do
      payload = payload_with_alert_count(50)

      assert {:ok, envelopes} = PayloadNormalizer.normalize_alertmanager(payload)
      assert length(envelopes) == 50
    end

    test "reports actual count for very large Alertmanager batch" do
      payload = payload_with_alert_count(1_000)

      assert {:error, {:too_many_alerts, 1_000}} =
               PayloadNormalizer.normalize_alertmanager(payload)
    end

    test "always computes composite fingerprint, ignoring vendor-supplied value" do
      payload =
        fixture("alertmanager_v4_firing.json")
        |> put_in(
          ["alerts", Access.at(0), "fingerprint"],
          "attacker-controlled-#{:rand.uniform()}"
        )
        |> put_in(["alerts", Access.at(0), "labels", "status"], "firing")

      assert {:ok, [first]} = PayloadNormalizer.normalize_alertmanager(payload)
      assert {:ok, [second]} = PayloadNormalizer.normalize_alertmanager(payload)
      assert first.fingerprint == "payments-api:PaymentsAPIDown:critical:firing"
      assert first.fingerprint == second.fingerprint
    end

    test "composite fingerprints ignore noisy labels and fill unknown placeholders" do
      noisy =
        fixture("alertmanager_v4_firing.json")
        |> update_in(["alerts", Access.at(0)], &Map.delete(&1, "fingerprint"))

      baseline = put_in(noisy, ["alerts", Access.at(0), "labels", "instance"], "pod-a")
      varied = put_in(noisy, ["alerts", Access.at(0), "labels", "instance"], "pod-b")

      assert {:ok, [baseline_envelope]} = PayloadNormalizer.normalize_alertmanager(baseline)
      assert {:ok, [varied_envelope]} = PayloadNormalizer.normalize_alertmanager(varied)
      assert baseline_envelope.fingerprint == varied_envelope.fingerprint

      unknown =
        noisy
        |> update_in(["alerts", Access.at(0), "labels"], fn labels ->
          Map.drop(labels, ["service", "alertname", "severity", "status"])
        end)

      assert {:ok, [unknown_envelope]} = PayloadNormalizer.normalize_alertmanager(unknown)
      assert unknown_envelope.fingerprint == "_unknown:_unknown:_unknown:_unknown"
    end

    test "treats unparseable startsAt as nil without failing the alert" do
      payload =
        put_in(
          fixture("alertmanager_v4_firing.json"),
          ["alerts", Access.at(0), "startsAt"],
          "not-a-date"
        )

      assert {:ok, [envelope]} = PayloadNormalizer.normalize_alertmanager(payload)
      assert envelope.started_at == nil
    end

    test "maps severity values and defaults unknown values" do
      base = fixture("alertmanager_v4_firing.json")

      assert_severity(base, "CRITICAL", :critical)
      assert_severity(base, "Critical", :critical)
      assert_severity(base, "warning", :medium)
      assert_severity(base, "nonsense", :medium)

      missing_severity =
        update_in(base, ["alerts", Access.at(0), "labels"], &Map.delete(&1, "severity"))

      assert {:ok, [envelope]} = PayloadNormalizer.normalize_alertmanager(missing_severity)
      assert envelope.severity == :medium
    end

    test "derives service-down and unknown alert classes from alert labels" do
      base = fixture("alertmanager_v4_firing.json")

      service_down =
        base
        |> put_in(["alerts", Access.at(0), "labels", "alertname"], "PaymentsAPIDown")
        |> update_in(["alerts", Access.at(0), "labels"], &Map.delete(&1, "version"))
        |> put_in(["alerts", Access.at(0), "annotations", "description"], "health check failing")

      unknown = put_in(base, ["alerts", Access.at(0), "labels", "alertname"], "DiskFull")

      assert {:ok, [service_down_envelope]} =
               PayloadNormalizer.normalize_alertmanager(service_down)

      assert service_down_envelope.alert_class == :service_down

      assert {:ok, [unknown_envelope]} = PayloadNormalizer.normalize_alertmanager(unknown)
      assert unknown_envelope.alert_class == :unknown
    end
  end

  describe "normalize_pagerduty/1" do
    test "normalizes a realistic v3 incident.triggered payload" do
      payload = fixture("pagerduty_v3_incident_triggered.json")

      assert {:ok, envelope} = PayloadNormalizer.normalize_pagerduty(payload)
      assert envelope.__struct__ == AlertEnvelope
      assert Ecto.UUID.cast(envelope.alert_id) == {:ok, envelope.alert_id}
      assert envelope.source == :pagerduty
      assert envelope.source_ref == "PXYZ123"
      assert envelope.fingerprint == "PXYZ123"
      assert %DateTime{} = envelope.received_at
      assert envelope.started_at == ~U[2026-05-13 03:44:30Z]
      assert envelope.status == :firing
      assert envelope.severity == :high
      assert envelope.alert_class == :latency_creep
      assert envelope.title == "payments-api latency creep"
      assert envelope.service == "payments-api"

      assert envelope.labels == %{
               "alertname" => "payments-api latency creep",
               "incident_id" => "PXYZ123",
               "priority" => "P1",
               "urgency" => "high"
             }

      assert envelope.annotations == %{}
      assert envelope.payload_raw == payload
    end

    test "maps incident.resolved events to resolved status" do
      assert {:ok, envelope} =
               "pagerduty_v3_incident_resolved.json"
               |> fixture()
               |> PayloadNormalizer.normalize_pagerduty()

      assert envelope.status == :resolved
    end

    test "maps low urgency to low severity" do
      payload =
        put_in(
          fixture("pagerduty_v3_incident_triggered.json"),
          ["event", "data", "urgency"],
          "low"
        )

      assert {:ok, envelope} = PayloadNormalizer.normalize_pagerduty(payload)
      assert envelope.severity == :low
    end

    test "reports missing event, event data, and incident id as malformed" do
      assert {:error, {:malformed, :event}} =
               "pagerduty_v3_missing_event.json"
               |> fixture()
               |> PayloadNormalizer.normalize_pagerduty()

      missing_data =
        update_in(
          fixture("pagerduty_v3_incident_triggered.json"),
          ["event"],
          &Map.delete(&1, "data")
        )

      assert {:error, {:malformed, :event_data}} =
               PayloadNormalizer.normalize_pagerduty(missing_data)

      missing_incident_id =
        update_in(
          fixture("pagerduty_v3_incident_triggered.json"),
          ["event", "data"],
          &Map.delete(&1, "id")
        )

      assert {:error, {:malformed, :incident_id}} =
               PayloadNormalizer.normalize_pagerduty(missing_incident_id)
    end
  end

  defp assert_severity(base, value, expected) do
    payload = put_in(base, ["alerts", Access.at(0), "labels", "severity"], value)
    assert {:ok, [envelope]} = PayloadNormalizer.normalize_alertmanager(payload)
    assert envelope.severity == expected
  end

  defp payload_with_alert_count(count) do
    base = fixture("alertmanager_v4_firing.json")
    [alert] = base["alerts"]

    alerts =
      Enum.map(1..count, fn index ->
        alert
        |> put_in(["fingerprint"], "batch-fingerprint-#{index}")
        |> put_in(["labels", "instance"], "payments-api-#{index}")
      end)

    Map.put(base, "alerts", alerts)
  end

  defp fixture(name) do
    ["test", "fixtures", "webhooks", name]
    |> Path.join()
    |> File.read!()
    |> Jason.decode!()
  end
end
