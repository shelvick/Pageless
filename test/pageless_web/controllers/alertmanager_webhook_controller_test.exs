defmodule PagelessWeb.AlertmanagerWebhookControllerTest do
  @moduledoc "Controller tests for Alertmanager webhook intake."

  use PagelessWeb.ConnCase, async: true

  alias Pageless.PubSubHelpers

  setup %{conn: conn} do
    broker = PubSubHelpers.start_isolated_pubsub()
    :ok = PubSubHelpers.subscribe(broker, "alerts")
    dedup = start_supervised!({Pageless.WebhookDedup, []})

    limiter =
      start_supervised!(
        {Pageless.RateLimiter, routes: %{webhook_alertmanager: %{burst: 10, refill_per_sec: 5}}}
      )

    %{conn: test_conn(conn, broker, dedup, limiter), dedup: dedup}
  end

  @tag :acceptance
  test "POST /webhook/alertmanager broadcasts one firing alert", %{conn: conn} do
    payload = fixture("alertmanager_v4_firing.json")

    conn = post_json(conn, "/webhook/alertmanager", payload)

    assert conn.status == 202
    assert Jason.decode!(conn.resp_body) == %{"received" => 1, "deduplicated" => 0}
    assert_receive {:alert_received, envelope}
    assert envelope.__struct__ == Pageless.AlertEnvelope
    assert envelope.source == :alertmanager
    assert envelope.status == :firing
    assert envelope.severity == :critical
    assert envelope.service == "payments-api"
    refute_received {:alert_received, _unexpected}
  end

  test "budget exhaustion returns 503 before normalizing or broadcasting", %{conn: conn} do
    budget = start_supervised!({Pageless.GeminiBudget, cap: 0, clock: fn -> ~D[2026-05-15] end})
    conn = Plug.Conn.assign(conn, :gemini_budget, budget)

    conn = post_json(conn, "/webhook/alertmanager", fixture("alertmanager_v4_firing.json"))

    assert conn.status == 503
    assert get_resp_header(conn, "retry-after") == ["86400"]

    assert Jason.decode!(conn.resp_body) == %{
             "error" => "gemini_budget_exhausted",
             "retry_after_ms" => 86_400_000
           }

    refute_received {:alert_received, _unexpected}
  end

  test "alert tree overload returns 503 before normalizing or broadcasting", %{conn: conn} do
    tree = start_supervised!({Pageless.Sup.AlertTree, max_children: 1})

    assert {:ok, _pid} =
             Pageless.Sup.AlertTree.start_alert(tree,
               envelope: alert_envelope("alertmanager-overload"),
               pubsub: conn.assigns.pubsub_broker,
               caller: self(),
               idle_ttl_ms: 60_000
             )

    conn = Plug.Conn.assign(conn, :alert_tree, tree)
    conn = post_json(conn, "/webhook/alertmanager", fixture("alertmanager_v4_firing.json"))

    assert conn.status == 503
    assert get_resp_header(conn, "retry-after") == ["1"]

    assert Jason.decode!(conn.resp_body) == %{
             "error" => "overloaded",
             "retry_after_ms" => 1000
           }

    refute_received {:alert_received, _unexpected}
  end

  test "POST batch broadcasts both alerts when neither is duplicate", %{conn: conn} do
    payload = fixture("alertmanager_v4_batch.json")

    conn = post_json(conn, "/webhook/alertmanager", payload)

    assert conn.status == 202
    assert Jason.decode!(conn.resp_body) == %{"received" => 2, "deduplicated" => 0}
    assert_receive {:alert_received, first}
    assert_receive {:alert_received, second}

    assert [first.title, second.title] == [
             "payments-api p95 latency above SLO",
             "orders-db connection pool exhausted"
           ]
  end

  test "POST resolved status broadcasts even after firing was deduped", %{conn: conn} do
    firing_payload = fixture("alertmanager_v4_firing.json")
    resolved_payload = fixture("alertmanager_v4_resolved.json")

    firing_conn = post_json(conn, "/webhook/alertmanager", firing_payload)
    assert firing_conn.status == 202
    assert_receive {:alert_received, firing}
    assert firing.status == :firing

    resolved_conn = post_json(conn, "/webhook/alertmanager", resolved_payload)

    assert resolved_conn.status == 202
    assert Jason.decode!(resolved_conn.resp_body) == %{"received" => 1, "deduplicated" => 0}
    assert_receive {:alert_received, resolved}
    assert resolved.status == :resolved
  end

  test "empty alerts batch returns received: 0, deduplicated: 0", %{conn: conn} do
    payload = fixture("alertmanager_v4_empty_alerts.json")

    conn = post_json(conn, "/webhook/alertmanager", payload)

    assert conn.status == 202
    assert Jason.decode!(conn.resp_body) == %{"received" => 0, "deduplicated" => 0}
    refute_received {:alert_received, _unexpected}
  end

  test "oversized alerts batch returns 422 and broadcasts nothing", %{conn: conn} do
    payload = payload_with_alert_count(51)

    conn = post_json(conn, "/webhook/alertmanager", payload)

    assert conn.status == 422

    assert Jason.decode!(conn.resp_body) == %{
             "error" => "too_many_alerts",
             "limit" => 50,
             "received" => 51
           }

    refute_received {:alert_received, _unexpected}
  end

  test "exactly 50 alerts at the boundary are accepted", %{conn: conn} do
    payload = payload_with_alert_count(50)

    conn = post_json(conn, "/webhook/alertmanager", payload)

    assert conn.status == 202
    assert %{"received" => 50, "deduplicated" => 0} = Jason.decode!(conn.resp_body)
  end

  test "preserves malformed_payload and unsupported_version 400s", %{conn: conn} do
    malformed = fixture("alertmanager_v4_firing.json") |> Map.delete("alerts")
    unsupported = fixture("alertmanager_v4_firing.json") |> Map.put("version", "3")

    malformed_conn = post_json(conn, "/webhook/alertmanager", malformed)
    unsupported_conn = post_json(conn, "/webhook/alertmanager", unsupported)

    assert malformed_conn.status == 400

    assert Jason.decode!(malformed_conn.resp_body) == %{
             "error" => "malformed_payload",
             "field" => "alerts"
           }

    assert unsupported_conn.status == 400

    assert Jason.decode!(unsupported_conn.resp_body) == %{
             "error" => "unsupported_version",
             "version" => "3"
           }
  end

  test "POST batch broadcasts only the non-duplicate envelope", %{conn: conn, dedup: dedup} do
    payload = fixture("alertmanager_v4_batch.json")
    [_first, duplicate] = payload["alerts"]

    :ok = Pageless.WebhookDedup.check_or_record(dedup, :alertmanager, envelope_for(duplicate))
    conn = post_json(conn, "/webhook/alertmanager", payload)

    assert conn.status == 202
    assert Jason.decode!(conn.resp_body) == %{"received" => 1, "deduplicated" => 1}
    assert_receive {:alert_received, envelope}
    assert envelope.fingerprint == "payments-api:HighLatency:warning:_unknown"
    refute envelope.fingerprint == "orders-db:DBConnectionPoolExhausted:high:_unknown"
    refute_received {:alert_received, _unexpected}
  end

  test "POST batch with all duplicates broadcasts nothing", %{conn: conn, dedup: dedup} do
    payload = fixture("alertmanager_v4_batch.json")

    for alert <- payload["alerts"] do
      :ok = Pageless.WebhookDedup.check_or_record(dedup, :alertmanager, envelope_for(alert))
    end

    conn = post_json(conn, "/webhook/alertmanager", payload)

    assert conn.status == 202
    assert Jason.decode!(conn.resp_body) == %{"received" => 0, "deduplicated" => 2}
    refute_received {:alert_received, _unexpected}
  end

  test "duplicate AM firing within window does not re-broadcast", %{conn: conn} do
    payload = fixture("alertmanager_v4_firing.json")

    first_conn = post_json(conn, "/webhook/alertmanager", payload)
    second_conn = post_json(conn, "/webhook/alertmanager", payload)

    assert Jason.decode!(first_conn.resp_body) == %{"received" => 1, "deduplicated" => 0}
    assert Jason.decode!(second_conn.resp_body) == %{"received" => 0, "deduplicated" => 1}
    assert_receive {:alert_received, envelope}
    assert envelope.fingerprint == "payments-api:PaymentsAPIDown:critical:_unknown"
    refute_received {:alert_received, _unexpected}
  end

  test "controller uses conn.assigns[:webhook_dedup] when present", %{conn: conn, dedup: dedup} do
    payload = fixture("alertmanager_v4_firing.json")

    :ok =
      Pageless.WebhookDedup.check_or_record(
        dedup,
        :alertmanager,
        envelope_for(hd(payload["alerts"]))
      )

    conn = post_json(conn, "/webhook/alertmanager", payload)

    assert conn.status == 202
    assert Jason.decode!(conn.resp_body) == %{"received" => 0, "deduplicated" => 1}
    refute_received {:alert_received, _unexpected}
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

  defp post_json(conn, path, payload) do
    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json")
    |> post(path, Jason.encode!(payload))
  end

  defp envelope_for(alert) do
    labels = Map.get(alert, "labels", %{})

    composite =
      [
        Map.get(labels, "service", "_unknown"),
        Map.get(labels, "alertname", "_unknown"),
        Map.get(labels, "severity", "_unknown"),
        Map.get(labels, "status", "_unknown")
      ]
      |> Enum.join(":")

    %{fingerprint: composite, status: String.to_existing_atom(alert["status"])}
  end

  defp alert_envelope(alert_id) do
    %Pageless.AlertEnvelope{
      alert_id: alert_id,
      source: :alertmanager,
      source_ref: "am-ref",
      fingerprint: "fingerprint-#{alert_id}",
      received_at: DateTime.utc_now(),
      started_at: DateTime.utc_now(),
      status: :firing,
      severity: :critical,
      alert_class: :latency,
      title: "payments-api p95 latency above SLO",
      service: "payments-api",
      labels: %{"service" => "payments-api"},
      annotations: %{},
      payload_raw: %{"fixture" => true}
    }
  end

  defp payload_with_alert_count(count) do
    base = fixture("alertmanager_v4_firing.json")
    [alert] = base["alerts"]

    alerts =
      Enum.map(1..count, fn index ->
        alert
        |> put_in(["labels", "service"], "service-#{index}")
        |> put_in(["labels", "instance"], "instance-#{index}")
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
