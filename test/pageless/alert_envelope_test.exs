defmodule Pageless.AlertEnvelopeTest do
  @moduledoc "Tests for the canonical alert envelope data contract."

  use ExUnit.Case, async: true

  alias Pageless.AlertEnvelope

  describe "new/1" do
    test "returns an alert envelope with every supplied field preserved" do
      received_at = DateTime.utc_now()
      started_at = ~U[2026-05-13 03:44:12Z]
      payload_raw = %{"alerts" => [%{"labels" => %{"service" => "payments-api"}}]}

      attrs = %{
        alert_id: "9f20ef39-3f97-4552-a659-7d8cfd0f7a91",
        source: :alertmanager,
        source_ref: "{}/{alertname=\"PaymentsAPIDown\"}:{}",
        fingerprint: "abc123paymentsdown",
        received_at: received_at,
        started_at: started_at,
        status: :firing,
        severity: :critical,
        alert_class: :service_down_with_recent_deploy,
        title: "payments-api health check failing",
        service: "payments-api",
        labels: %{"severity" => "critical", "service" => "payments-api"},
        annotations: %{"summary" => "payments-api health check failing"},
        payload_raw: payload_raw
      }

      assert {:ok, envelope} = AlertEnvelope.new(attrs)
      assert envelope.__struct__ == AlertEnvelope
      assert Map.take(envelope, Map.keys(attrs)) == attrs
    end

    test "defaults optional label and annotation maps when omitted" do
      attrs = valid_attrs() |> Map.drop([:labels, :annotations])

      assert {:ok, envelope} = AlertEnvelope.new(attrs)
      assert envelope.labels == %{}
      assert envelope.annotations == %{}
    end

    test "reports the first missing required field by atom name" do
      attrs = valid_attrs() |> Map.delete(:source_ref)

      assert {:error, {:missing_field, :source_ref}} = AlertEnvelope.new(attrs)
    end

    test "does not validate source-specific semantic values" do
      attrs = %{valid_attrs() | severity: :nonsense, status: :whatever}

      assert {:ok, envelope} = AlertEnvelope.new(attrs)
      assert envelope.severity == :nonsense
      assert envelope.status == :whatever
    end

    test "round-trips through Jason without losing nested payload_raw structure" do
      assert {:ok, envelope} = AlertEnvelope.new(valid_attrs())

      decoded = envelope |> Jason.encode!() |> Jason.decode!()

      assert decoded["payload_raw"]["alerts"] == [
               %{"labels" => %{"service" => "payments-api", "severity" => "critical"}}
             ]
    end
  end

  defp valid_attrs do
    %{
      alert_id: "9f20ef39-3f97-4552-a659-7d8cfd0f7a91",
      source: :alertmanager,
      source_ref: "{}/{alertname=\"PaymentsAPIDown\"}:{}",
      fingerprint: "abc123paymentsdown",
      received_at: DateTime.utc_now(),
      started_at: ~U[2026-05-13 03:44:12Z],
      status: :firing,
      severity: :critical,
      alert_class: :service_down_with_recent_deploy,
      title: "payments-api health check failing",
      service: "payments-api",
      labels: %{"severity" => "critical", "service" => "payments-api"},
      annotations: %{"summary" => "payments-api health check failing"},
      payload_raw: %{
        "alerts" => [%{"labels" => %{"service" => "payments-api", "severity" => "critical"}}]
      }
    }
  end
end
