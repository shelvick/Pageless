defmodule PagelessWeb.PagerDutyWebhookControllerTest do
  @moduledoc "Controller tests for PagerDuty webhook intake."

  use PagelessWeb.ConnCase, async: true

  alias Pageless.PubSubHelpers
  alias PagelessWeb.PagerDutyWebhookController

  setup do
    broker = PubSubHelpers.start_isolated_pubsub()
    :ok = PubSubHelpers.subscribe(broker, "alerts")
    %{pubsub: broker}
  end

  @tag :acceptance
  test "POST /webhook/pagerduty-events-v2 broadcasts incident alert", %{
    conn: conn,
    pubsub: broker
  } do
    payload = fixture("pagerduty_v3_incident_triggered.json")
    conn = Plug.Conn.assign(conn, :pubsub_broker, broker)

    conn = PagerDutyWebhookController.create(conn, payload)

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
    refute_receive {:alert_received, _unexpected}, 25
  end

  test "resolved event broadcasts resolved status", %{conn: conn, pubsub: broker} do
    payload = fixture("pagerduty_v3_incident_resolved.json")
    conn = Plug.Conn.assign(conn, :pubsub_broker, broker)

    conn = PagerDutyWebhookController.create(conn, payload)

    assert conn.status == 202
    assert_receive {:alert_received, envelope}
    assert envelope.status == :resolved
  end

  test "PagerDuty low urgency maps to low severity", %{conn: conn, pubsub: broker} do
    payload =
      put_in(fixture("pagerduty_v3_incident_triggered.json"), ["event", "data", "urgency"], "low")

    conn = Plug.Conn.assign(conn, :pubsub_broker, broker)

    conn = PagerDutyWebhookController.create(conn, payload)

    assert conn.status == 202
    assert_receive {:alert_received, envelope}
    assert envelope.severity == :low
  end

  test "missing event key returns structured malformed-payload JSON", %{
    conn: conn,
    pubsub: broker
  } do
    payload = fixture("pagerduty_v3_missing_event.json")
    conn = Plug.Conn.assign(conn, :pubsub_broker, broker)

    conn = PagerDutyWebhookController.create(conn, payload)

    assert conn.status == 400
    assert Jason.decode!(conn.resp_body) == %{"error" => "malformed_payload", "field" => "event"}
  end

  test "missing event data returns structured malformed-payload JSON", %{
    conn: conn,
    pubsub: broker
  } do
    payload =
      update_in(
        fixture("pagerduty_v3_incident_triggered.json"),
        ["event"],
        &Map.delete(&1, "data")
      )

    conn = Plug.Conn.assign(conn, :pubsub_broker, broker)

    conn = PagerDutyWebhookController.create(conn, payload)

    assert conn.status == 400

    assert Jason.decode!(conn.resp_body) == %{
             "error" => "malformed_payload",
             "field" => "event_data"
           }
  end

  test "missing incident id returns structured malformed-payload JSON", %{
    conn: conn,
    pubsub: broker
  } do
    payload =
      update_in(
        fixture("pagerduty_v3_incident_triggered.json"),
        ["event", "data"],
        &Map.delete(&1, "id")
      )

    conn = Plug.Conn.assign(conn, :pubsub_broker, broker)

    conn = PagerDutyWebhookController.create(conn, payload)

    assert conn.status == 400

    assert Jason.decode!(conn.resp_body) == %{
             "error" => "malformed_payload",
             "field" => "incident_id"
           }
  end

  test "the PagerDuty webhook route is registered", %{conn: conn} do
    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> post(
        "/webhook/pagerduty-events-v2",
        Jason.encode!(fixture("pagerduty_v3_incident_triggered.json"))
      )

    assert conn.status in [202, 400]
  end

  defp fixture(name) do
    ["test", "fixtures", "webhooks", name]
    |> Path.join()
    |> File.read!()
    |> Jason.decode!()
  end
end
