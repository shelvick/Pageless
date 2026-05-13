defmodule PagelessWeb.AlertmanagerWebhookControllerTest do
  @moduledoc "Controller tests for Alertmanager webhook intake."

  use PagelessWeb.ConnCase, async: true

  alias Pageless.PubSubHelpers
  alias PagelessWeb.AlertmanagerWebhookController

  setup do
    broker = PubSubHelpers.start_isolated_pubsub()
    :ok = PubSubHelpers.subscribe(broker, "alerts")
    %{pubsub: broker}
  end

  @tag :acceptance
  test "POST broadcasts one firing alert", %{conn: conn, pubsub: broker} do
    payload = fixture("alertmanager_v4_firing.json")
    conn = Plug.Conn.assign(conn, :pubsub_broker, broker)

    conn = AlertmanagerWebhookController.create(conn, payload)

    assert conn.status == 202
    assert Jason.decode!(conn.resp_body) == %{"received" => 1}
    assert_receive {:alert_received, envelope}
    assert envelope.__struct__ == Pageless.AlertEnvelope
    assert envelope.source == :alertmanager
    assert envelope.status == :firing
    assert envelope.severity == :critical
    assert envelope.service == "payments-api"
    refute_receive {:alert_received, _unexpected}, 25
  end

  test "POST /webhook/alertmanager broadcasts batch alerts in order", %{
    conn: conn,
    pubsub: broker
  } do
    payload = fixture("alertmanager_v4_batch.json")
    conn = Plug.Conn.assign(conn, :pubsub_broker, broker)

    conn = AlertmanagerWebhookController.create(conn, payload)

    assert conn.status == 202
    assert Jason.decode!(conn.resp_body) == %{"received" => 2}
    assert_receive {:alert_received, first}
    assert_receive {:alert_received, second}

    assert [first.title, second.title] == [
             "payments-api p95 latency above SLO",
             "orders-db connection pool exhausted"
           ]
  end

  test "POST broadcasts resolved alerts", %{conn: conn, pubsub: broker} do
    payload = fixture("alertmanager_v4_resolved.json")
    conn = Plug.Conn.assign(conn, :pubsub_broker, broker)

    conn = AlertmanagerWebhookController.create(conn, payload)

    assert conn.status == 202
    assert_receive {:alert_received, envelope}
    assert envelope.status == :resolved
  end

  test "empty Alertmanager batches return accepted without broadcast", %{
    conn: conn,
    pubsub: broker
  } do
    payload = fixture("alertmanager_v4_empty_alerts.json")
    conn = Plug.Conn.assign(conn, :pubsub_broker, broker)

    conn = AlertmanagerWebhookController.create(conn, payload)

    assert conn.status == 202
    assert Jason.decode!(conn.resp_body) == %{"received" => 0}
    refute_receive {:alert_received, _unexpected}, 25
  end

  test "missing alerts key returns structured malformed-payload JSON", %{
    conn: conn,
    pubsub: broker
  } do
    payload = fixture("alertmanager_v4_firing.json") |> Map.delete("alerts")
    conn = Plug.Conn.assign(conn, :pubsub_broker, broker)

    conn = AlertmanagerWebhookController.create(conn, payload)

    assert conn.status == 400
    assert Jason.decode!(conn.resp_body) == %{"error" => "malformed_payload", "field" => "alerts"}
  end

  test "unsupported Alertmanager version returns structured error JSON", %{
    conn: conn,
    pubsub: broker
  } do
    payload = fixture("alertmanager_v4_firing.json") |> Map.put("version", "3")
    conn = Plug.Conn.assign(conn, :pubsub_broker, broker)

    conn = AlertmanagerWebhookController.create(conn, payload)

    assert conn.status == 400
    assert Jason.decode!(conn.resp_body) == %{"error" => "unsupported_version", "version" => "3"}
  end

  test "the Alertmanager webhook route is registered", %{conn: conn} do
    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> post("/webhook/alertmanager", Jason.encode!(fixture("alertmanager_v4_firing.json")))

    assert conn.status in [202, 400]
  end

  defp fixture(name) do
    ["test", "fixtures", "webhooks", name]
    |> Path.join()
    |> File.read!()
    |> Jason.decode!()
  end
end
