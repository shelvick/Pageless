defmodule PagelessWeb.FireTestAlertControllerTest do
  @moduledoc "Controller tests for the demo fire-test-alert endpoint."

  use PagelessWeb.ConnCase, async: true

  import Hammox

  alias Pageless.AlertEnvelope
  alias Pageless.AuditTrail.Decision
  alias Pageless.Config.Rules
  alias Pageless.Governance.{CapabilityGate, ToolCall}

  setup :verify_on_exit!

  @routes %{:webhook_fire_test_alert => %{burst: 3, refill_per_sec: 0.0167}}

  setup do
    pubsub = unique_atom("fire_test_pubsub")
    start_supervised!({Phoenix.PubSub, name: pubsub})

    limiter = start_rate_limiter(routes: @routes, clock: fn -> 0 end)

    %{pubsub: pubsub, rules: default_rules(), limiter: limiter}
  end

  @tag :acceptance
  test "POST /demo/fire-test-alert gates the deploy and approval executes kubectl once", %{
    conn: conn,
    pubsub: pubsub,
    rules: rules,
    limiter: limiter
  } do
    store = start_supervised!({Agent, fn -> %{} end})
    expect_repo_for_gated_request_and_approval(store)

    parent = self()

    Pageless.Tools.Kubectl.Mock
    |> expect(:exec, 1, fn %ToolCall{tool: :kubectl, args: ["apply", "-f", manifest_path]} = call ->
      assert String.ends_with?(manifest_path, "priv/k8s/11-payments-api-v241.yaml")
      send(parent, {:kubectl_exec, call})

      {:ok,
       %{
         output: "deployment.apps/payments-api-v2-4-1 configured",
         exit_status: 0,
         command: ["apply", "-f", manifest_path],
         duration_ms: 12
       }}
    end)

    Phoenix.PubSub.subscribe(pubsub, "alerts")

    conn =
      conn
      |> gated_conn(pubsub, rules, limiter)
      |> post_json("/demo/fire-test-alert", %{})

    assert conn.status == 202
    body = Jason.decode!(conn.resp_body)
    assert %{"deploy_id" => deploy_id, "gate_id" => gate_id, "status" => "gated"} = body
    assert is_binary(deploy_id) and deploy_id != ""
    assert gate_id =~ ~r/^gate_[a-f0-9]{16}$/
    refute Map.has_key?(body, "kubectl_exit_status")
    refute Map.has_key?(body, "output_excerpt")
    refute Map.has_key?(body, "error")

    assert_receive {:alert_received, %AlertEnvelope{} = envelope}, 500
    assert envelope.source == :demo
    assert envelope.alert_id == deploy_id
    assert envelope.source_ref == deploy_id
    assert envelope.status == :firing
    assert envelope.service == "payments-api"
    assert envelope.payload_raw["deploy_id"] == deploy_id

    assert_receive {:gate_fired, ^gate_id,
                    %ToolCall{tool: :kubectl, args: ["apply", "-f", manifest_path]} = call,
                    :write_prod_high, "apply", %{summary: summary}},
                   500

    assert call.alert_id == deploy_id
    assert String.ends_with?(manifest_path, "priv/k8s/11-payments-api-v241.yaml")
    assert summary =~ "Operator-initiated deploy"

    refute_received {:kubectl_exec, _call}
    Phoenix.PubSub.subscribe(pubsub, "alert:#{deploy_id}")

    assert {:ok, %{exit_status: 0}} =
             CapabilityGate.approve(
               gate_id,
               "operator:demo",
               tool_dispatch: fn call -> Pageless.Tools.Kubectl.Mock.exec(call) end,
               pubsub: pubsub,
               repo: Pageless.AuditTrailMock
             )

    assert_receive {:kubectl_exec, %ToolCall{args: ["apply", "-f", ^manifest_path]}}, 500
    assert_receive {:gate_decision, :approved, ^gate_id, "operator:demo"}, 500
    assert_receive {:gate_decision, :executed, ^gate_id, ^call, %{exit_status: 0}}, 500
    refute_received {:kubectl_exec, _call}
  end

  test "controller POST never calls kubectl before operator approval", %{
    conn: conn,
    pubsub: pubsub,
    rules: rules,
    limiter: limiter
  } do
    expect_gated_records(1)

    Pageless.Tools.Kubectl.Mock
    |> expect(:exec, 0, fn _call -> flunk("controller POST must not execute kubectl") end)

    conn =
      conn
      |> gated_conn(pubsub, rules, limiter)
      |> post_json("/demo/fire-test-alert", %{})

    assert conn.status == 202
    assert %{"gate_id" => _gate_id, "status" => "gated"} = Jason.decode!(conn.resp_body)
  end

  test "audit attrs classify kubectl apply as gated write_prod_high", %{
    conn: conn,
    pubsub: pubsub,
    rules: rules,
    limiter: limiter
  } do
    Pageless.AuditTrailMock
    |> expect(:record_decision, fn attrs ->
      assert attrs.tool == "kubectl"
      assert %{"argv" => ["apply", "-f", manifest_path]} = attrs.args
      assert String.ends_with?(manifest_path, "priv/k8s/11-payments-api-v241.yaml")
      assert attrs.extracted_verb == "apply"
      assert attrs.classification == "write_prod_high"
      assert attrs.decision == "gated"
      assert attrs.gate_id =~ ~r/^gate_[a-f0-9]{16}$/
      assert attrs.request_id == attrs.alert_id
      assert attrs.result_summary =~ "pageless:gate-context:"

      {:ok, decision_fixture(attrs)}
    end)

    expect_no_kubectl_exec()

    conn =
      conn
      |> gated_conn(pubsub, rules, limiter)
      |> post_json("/demo/fire-test-alert", %{})

    assert conn.status == 202
    assert %{"status" => "gated"} = Jason.decode!(conn.resp_body)
  end

  test "policy-denied gate result responds 403 without kubectl", %{
    conn: conn,
    pubsub: pubsub,
    rules: rules,
    limiter: limiter
  } do
    denied_rules =
      put_in(rules.capability_classes.write_prod_high, %{auto: false, audit: true, gated: false})

    Pageless.AuditTrailMock
    |> expect(:record_decision, fn attrs ->
      assert attrs.classification == "write_prod_high"
      assert attrs.decision == "rejected"
      assert attrs.result_status == "error"
      assert attrs.result_summary == ":policy_denied"
      {:ok, decision_fixture(attrs)}
    end)

    expect_no_kubectl_exec()

    conn =
      conn
      |> gated_conn(pubsub, denied_rules, limiter)
      |> post_json("/demo/fire-test-alert", %{})

    assert conn.status == 403
    assert %{"deploy_id" => deploy_id, "error" => "policy_denied"} = Jason.decode!(conn.resp_body)
    assert is_binary(deploy_id) and deploy_id != ""
  end

  test "audit-write failure responds 500 without kubectl", %{
    conn: conn,
    pubsub: pubsub,
    rules: rules,
    limiter: limiter
  } do
    Pageless.AuditTrailMock
    |> expect(:record_decision, fn _attrs -> {:error, %Ecto.Changeset{}} end)

    expect_no_kubectl_exec()

    conn =
      conn
      |> gated_conn(pubsub, rules, limiter)
      |> post_json("/demo/fire-test-alert", %{})

    assert conn.status == 500

    assert %{"deploy_id" => deploy_id, "error" => "audit_write_failed"} =
             Jason.decode!(conn.resp_body)

    assert is_binary(deploy_id) and deploy_id != ""
  end

  test "demo route uses JSON-only rate-limited pipeline", %{conn: conn} do
    limiter =
      start_rate_limiter(
        routes: %{webhook_fire_test_alert: %{burst: 0, refill_per_sec: 1}},
        clock: fn -> 0 end
      )

    rate_limited_conn =
      conn
      |> Plug.Conn.assign(:rate_limiter, limiter)
      |> post_json("/demo/fire-test-alert", %{})

    assert rate_limited_conn.status == 429

    assert Jason.decode!(rate_limited_conn.resp_body) == %{
             "error" => "rate_limited",
             "route_id" => "webhook_fire_test_alert",
             "retry_after_ms" => 2_147_483_648
           }
  end

  test "fourth fire-test-alert burst returns 429 + retry-after", %{
    conn: conn,
    pubsub: pubsub,
    rules: rules,
    limiter: limiter
  } do
    expect_gated_records(3)
    expect_no_kubectl_exec()

    responses =
      for _ <- 1..4 do
        conn
        |> gated_conn(pubsub, rules, limiter)
        |> post_json("/demo/fire-test-alert", %{})
      end

    assert [202, 202, 202, 429] = Enum.map(responses, & &1.status)

    Enum.each(Enum.take(responses, 3), fn response ->
      assert %{"gate_id" => gate_id, "status" => "gated"} = Jason.decode!(response.resp_body)
      assert gate_id =~ ~r/^gate_[a-f0-9]{16}$/
    end)

    rejected = List.last(responses)
    assert get_resp_header(rejected, "retry-after") == ["60"]

    assert %{
             "error" => "rate_limited",
             "route_id" => "webhook_fire_test_alert",
             "retry_after_ms" => retry_after_ms
           } = Jason.decode!(rejected.resp_body)

    assert retry_after_ms > 0
  end

  @tag :acceptance
  test "rate limiter uses rightmost X-Forwarded-For entry, defeating leftmost spoofing", %{
    pubsub: pubsub,
    rules: rules
  } do
    limiter =
      start_rate_limiter(
        routes: %{webhook_fire_test_alert: %{burst: 1, refill_per_sec: 0.0167}},
        clock: fn -> 0 end
      )

    stub_gated_records()
    expect_no_kubectl_exec()

    responses =
      for spoofed_xff <- ["1.2.3.4, 9.9.9.9", "5.6.7.8, 9.9.9.9"] do
        endpoint_post_json(
          "/demo/fire-test-alert",
          %{},
          pubsub,
          rules,
          limiter,
          spoofed_xff,
          trust_x_forwarded_for: true
        )
      end

    assert [202, 429] = Enum.map(responses, & &1.status)

    rejected = List.last(responses)

    assert %{"error" => "rate_limited", "route_id" => "webhook_fire_test_alert"} =
             Jason.decode!(rejected.resp_body)
  end

  test "fire-test-alert rate limit isolated per IP", %{
    conn: conn,
    pubsub: pubsub,
    rules: rules,
    limiter: limiter
  } do
    expect_gated_records(4)
    expect_no_kubectl_exec()

    first_ip_statuses =
      for _ <- 1..4 do
        conn
        |> Map.put(:remote_ip, {1, 2, 3, 4})
        |> gated_conn(pubsub, rules, limiter)
        |> post_json("/demo/fire-test-alert", %{})
        |> Map.fetch!(:status)
      end

    other_ip_conn =
      conn
      |> Map.put(:remote_ip, {5, 6, 7, 8})
      |> gated_conn(pubsub, rules, limiter)
      |> post_json("/demo/fire-test-alert", %{})

    assert first_ip_statuses == [202, 202, 202, 429]
    assert other_ip_conn.status == 202
    assert %{"gate_id" => _gate_id, "status" => "gated"} = Jason.decode!(other_ip_conn.resp_body)
  end

  defp gated_conn(conn, pubsub, rules, limiter) do
    conn
    |> Plug.Conn.assign(:pubsub_broker, pubsub)
    |> Plug.Conn.assign(:rules, rules)
    |> Plug.Conn.assign(:audit_repo, Pageless.AuditTrailMock)
    |> Plug.Conn.assign(:rate_limiter, limiter)
  end

  defp expect_gated_records(count) do
    Pageless.AuditTrailMock
    |> expect(:record_decision, count, fn attrs ->
      assert attrs.tool == "kubectl"
      assert %{"argv" => ["apply", "-f", manifest_path]} = attrs.args
      assert String.ends_with?(manifest_path, "priv/k8s/11-payments-api-v241.yaml")
      assert attrs.extracted_verb == "apply"
      assert attrs.classification == "write_prod_high"
      assert attrs.decision == "gated"
      assert attrs.gate_id =~ ~r/^gate_[a-f0-9]{16}$/
      {:ok, decision_fixture(attrs)}
    end)
  end

  defp stub_gated_records do
    Pageless.AuditTrailMock
    |> stub(:record_decision, fn attrs -> {:ok, decision_fixture(attrs)} end)
  end

  defp expect_repo_for_gated_request_and_approval(store) do
    Pageless.AuditTrailMock
    |> expect(:record_decision, fn attrs ->
      assert attrs.decision == "gated"
      assert attrs.classification == "write_prod_high"
      assert attrs.extracted_verb == "apply"
      assert %{"argv" => ["apply", "-f", manifest_path]} = attrs.args
      assert String.ends_with?(manifest_path, "priv/k8s/11-payments-api-v241.yaml")

      decision = decision_fixture(attrs)
      Agent.update(store, &Map.put(&1, decision.gate_id, decision))
      {:ok, decision}
    end)
    |> expect(:get_by_gate_id, fn gate_id ->
      Agent.get(store, &Map.get(&1, gate_id))
    end)
    |> expect(:claim_gate_for_approval, fn gate_id, operator_ref ->
      decision = Agent.get(store, &Map.fetch!(&1, gate_id))
      approved = %{decision | decision: "approved", operator_ref: operator_ref}
      Agent.update(store, &Map.put(&1, gate_id, approved))
      {:ok, approved}
    end)
    |> expect(:update_decision, fn decision, attrs ->
      updated = struct(decision, attrs)
      Agent.update(store, &Map.put(&1, decision.gate_id, updated))
      {:ok, updated}
    end)
  end

  defp expect_no_kubectl_exec do
    Pageless.Tools.Kubectl.Mock
    |> expect(:exec, 0, fn _call -> flunk("kubectl must only run after operator approval") end)
  end

  defp decision_fixture(attrs) do
    %Decision{
      id: Ecto.UUID.generate(),
      request_id: Map.fetch!(attrs, :request_id),
      gate_id: Map.get(attrs, :gate_id),
      alert_id: Map.fetch!(attrs, :alert_id),
      agent_id: Map.fetch!(attrs, :agent_id),
      agent_pid_inspect: Map.get(attrs, :agent_pid_inspect),
      tool: Map.fetch!(attrs, :tool),
      args: Map.fetch!(attrs, :args),
      extracted_verb: Map.get(attrs, :extracted_verb),
      classification: Map.fetch!(attrs, :classification),
      decision: Map.fetch!(attrs, :decision),
      result_status: Map.get(attrs, :result_status),
      result_summary: Map.get(attrs, :result_summary)
    }
  end

  defp default_rules do
    Rules.load!(Path.expand("../../fixtures/pageless_rules/default.yaml", __DIR__))
  end

  defp start_rate_limiter(opts) do
    {:ok, pid} = Pageless.RateLimiter.start_link(opts)

    on_exit(fn ->
      if Process.alive?(pid) do
        GenServer.stop(pid, :normal, :infinity)
      end
    end)

    pid
  end

  defp post_json(conn, path, params) do
    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json")
    |> post(path, Jason.encode!(params))
  end

  defp endpoint_post_json(path, params, pubsub, rules, limiter, x_forwarded_for, opts) do
    :post
    |> Phoenix.ConnTest.build_conn(path, Jason.encode!(params))
    |> Map.put(:remote_ip, {127, 0, 0, 1})
    |> Plug.Conn.assign(:pubsub_broker, pubsub)
    |> Plug.Conn.assign(:rules, rules)
    |> Plug.Conn.assign(:audit_repo, Pageless.AuditTrailMock)
    |> Plug.Conn.assign(:rate_limiter, limiter)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Plug.Conn.put_req_header("accept", "application/json")
    |> Plug.Conn.put_req_header("x-forwarded-for", x_forwarded_for)
    |> PagelessWeb.Endpoint.call(opts)
  end

  defp unique(prefix), do: "#{prefix}_#{System.unique_integer([:positive])}"

  defp unique_atom(prefix), do: String.to_atom(unique(prefix))
end
