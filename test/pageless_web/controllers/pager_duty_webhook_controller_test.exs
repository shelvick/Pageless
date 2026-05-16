defmodule PagelessWeb.PagerDutyWebhookControllerTest do
  @moduledoc "Controller tests for PagerDuty webhook intake."

  use PagelessWeb.ConnCase, async: true

  alias Pageless.PubSubHelpers

  setup %{conn: conn} do
    broker = PubSubHelpers.start_isolated_pubsub()
    :ok = PubSubHelpers.subscribe(broker, "alerts")
    dedup = start_supervised!({Pageless.WebhookDedup, []})

    limiter =
      start_supervised!(
        {Pageless.RateLimiter, routes: %{webhook_pagerduty: %{burst: 10, refill_per_sec: 5}}}
      )

    %{conn: test_conn(conn, broker, dedup, limiter), dedup: dedup}
  end

  @tag :acceptance
  test "POST /webhook/pagerduty-events-v2 triggers single envelope broadcast", %{conn: conn} do
    payload = fixture("pagerduty_v3_incident_triggered.json")

    conn = post_signed_json(conn, "/webhook/pagerduty-events-v2", payload)

    body = Jason.decode!(conn.resp_body)
    assert conn.status == 202
    assert body["received"] == 1
    assert_receive {:alert_received, envelope}
    assert envelope.__struct__ == Pageless.AlertEnvelope
    assert envelope.source == :pagerduty
    assert envelope.status == :firing
    assert envelope.severity == :high
    assert envelope.service == "payments-api"
    assert body["alert_id"] == envelope.alert_id
    refute_received {:alert_received, _unexpected}
  end

  test "budget exhaustion returns 503 after HMAC but before broadcast", %{conn: conn} do
    budget = start_supervised!({Pageless.GeminiBudget, cap: 0, clock: fn -> ~D[2026-05-15] end})
    conn = Plug.Conn.assign(conn, :gemini_budget, budget)

    conn =
      post_signed_json(
        conn,
        "/webhook/pagerduty-events-v2",
        fixture("pagerduty_v3_incident_triggered.json")
      )

    assert conn.status == 503
    assert get_resp_header(conn, "retry-after") == ["86400"]

    assert Jason.decode!(conn.resp_body) == %{
             "error" => "gemini_budget_exhausted",
             "retry_after_ms" => 86_400_000
           }

    refute_received {:alert_received, _unexpected}
  end

  test "POST resolved event broadcasts with status :resolved", %{conn: conn} do
    payload = fixture("pagerduty_v3_incident_resolved.json")

    conn = post_signed_json(conn, "/webhook/pagerduty-events-v2", payload)

    assert conn.status == 202
    assert_receive {:alert_received, envelope}
    assert envelope.status == :resolved
  end

  test "POST low urgency event normalizes severity :low", %{conn: conn} do
    payload =
      put_in(fixture("pagerduty_v3_incident_triggered.json"), ["event", "data", "urgency"], "low")

    conn = post_signed_json(conn, "/webhook/pagerduty-events-v2", payload)

    assert conn.status == 202
    assert_receive {:alert_received, envelope}
    assert envelope.severity == :low
  end

  test "preserves all three malformed_payload 400 variants", %{conn: conn} do
    missing_event = fixture("pagerduty_v3_missing_event.json")

    missing_data =
      update_in(
        fixture("pagerduty_v3_incident_triggered.json"),
        ["event"],
        &Map.delete(&1, "data")
      )

    missing_incident_id =
      update_in(
        fixture("pagerduty_v3_incident_triggered.json"),
        ["event", "data"],
        &Map.delete(&1, "id")
      )

    assert_error(post_signed_json(conn, "/webhook/pagerduty-events-v2", missing_event), "event")

    assert_error(
      post_signed_json(conn, "/webhook/pagerduty-events-v2", missing_data),
      "event_data"
    )

    assert_error(
      post_signed_json(conn, "/webhook/pagerduty-events-v2", missing_incident_id),
      "incident_id"
    )
  end

  test "response alert_id matches broadcast envelope alert_id", %{conn: conn} do
    payload = fixture("pagerduty_v3_incident_triggered.json")

    conn = post_signed_json(conn, "/webhook/pagerduty-events-v2", payload)

    body = Jason.decode!(conn.resp_body)
    assert_receive {:alert_received, envelope}
    assert body["alert_id"] == envelope.alert_id
  end

  test "duplicate PD trigger within window does not re-broadcast", %{conn: conn} do
    payload = fixture("pagerduty_v3_incident_triggered.json")

    first_conn = post_signed_json(conn, "/webhook/pagerduty-events-v2", payload)
    second_conn = post_signed_json(conn, "/webhook/pagerduty-events-v2", payload)

    assert Jason.decode!(first_conn.resp_body)["received"] == 1

    assert %{"received" => 0, "deduplicated" => true, "age_ms" => age_ms} =
             Jason.decode!(second_conn.resp_body)

    assert age_ms >= 0
    assert_receive {:alert_received, envelope}
    assert envelope.fingerprint == "PXYZ123"
    refute_received {:alert_received, _unexpected}
  end

  test "firing-then-resolved transitions both broadcast", %{conn: conn} do
    firing_conn =
      post_signed_json(
        conn,
        "/webhook/pagerduty-events-v2",
        fixture("pagerduty_v3_incident_triggered.json")
      )

    resolved_conn =
      post_signed_json(
        conn,
        "/webhook/pagerduty-events-v2",
        fixture("pagerduty_v3_incident_resolved.json")
      )

    assert Jason.decode!(firing_conn.resp_body)["received"] == 1
    assert Jason.decode!(resolved_conn.resp_body)["received"] == 1
    assert_receive {:alert_received, firing}
    assert_receive {:alert_received, resolved}
    assert [firing.status, resolved.status] == [:firing, :resolved]
  end

  test "controller uses injected dedup server to suppress duplicates", %{conn: conn, dedup: dedup} do
    payload = fixture("pagerduty_v3_incident_triggered.json")

    :ok = Pageless.WebhookDedup.check_or_record(dedup, :pagerduty, envelope_for(payload))
    conn = post_signed_json(conn, "/webhook/pagerduty-events-v2", payload)

    assert conn.status == 202

    assert %{"received" => 0, "deduplicated" => true, "age_ms" => age_ms} =
             Jason.decode!(conn.resp_body)

    assert age_ms >= 0
    refute_received {:alert_received, _unexpected}
  end

  test "tampered PD body 401s at plug with no alert broadcast", %{conn: conn} do
    body = Jason.encode!(fixture("pagerduty_v3_incident_triggered.json"))
    tampered = String.replace(body, "payments-api", "payments-apx")

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-pagerduty-signature", "v1=#{signature_for(body)}")
      |> post("/webhook/pagerduty-events-v2", tampered)

    assert conn.status == 401
    refute_received {:alert_received, _unexpected}
  end

  defp assert_error(conn, field) do
    assert conn.status == 400
    assert Jason.decode!(conn.resp_body) == %{"error" => "malformed_payload", "field" => field}
  end

  defp test_conn(conn, broker, dedup, limiter) do
    conn
    |> Plug.Conn.assign(:pubsub_broker, broker)
    |> Plug.Conn.assign(:webhook_dedup, dedup)
    |> assign_if_present(:rate_limiter, limiter)
    |> put_private(:phoenix_recycled, true)
  end

  defp assign_if_present(conn, _key, nil), do: conn
  defp assign_if_present(conn, key, value), do: Plug.Conn.assign(conn, key, value)

  defp post_signed_json(conn, path, payload) do
    body = Jason.encode!(payload)

    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-pagerduty-signature", "v1=#{signature_for(body)}")
    |> post(path, body)
  end

  defp envelope_for(payload) do
    incident_id = get_in(payload, ["event", "data", "id"])
    event_type = get_in(payload, ["event", "event_type"])
    status = if event_type == "incident.resolved", do: :resolved, else: :firing
    %{fingerprint: incident_id, status: status}
  end

  defp signature_for(body) do
    :hmac
    |> :crypto.mac(:sha256, hmac_secret(), body)
    |> Base.encode16(case: :lower)
  end

  defp hmac_secret, do: "test-pagerduty-secret"

  defp fixture(name) do
    ["test", "fixtures", "webhooks", name]
    |> Path.join()
    |> File.read!()
    |> Jason.decode!()
  end
end
