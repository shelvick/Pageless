defmodule Pageless.Governance.CapabilityGateTest do
  @moduledoc "Tests Packet 3 capability-gate policy engine behavior."

  use ExUnit.Case, async: true

  import Hammox

  alias Ecto.Adapters.SQL.Sandbox
  alias Pageless.AuditTrail
  alias Pageless.AuditTrail.Decision
  alias Pageless.Config.Rules
  alias Pageless.Governance.CapabilityGate
  alias Pageless.Governance.ToolCall
  alias Pageless.Repo

  setup :verify_on_exit!

  setup do
    sandbox_owner = Sandbox.start_owner!(Repo, shared: false)

    pubsub = unique_atom("gate_pubsub")
    start_supervised!({Phoenix.PubSub, name: pubsub})

    on_exit(fn -> Sandbox.stop_owner(sandbox_owner) end)

    %{pubsub: pubsub, rules: default_rules(), sandbox_owner: sandbox_owner}
  end

  describe "request/3 policy decisions" do
    test "request/3 auto-executes :read class and returns result", %{pubsub: pubsub, rules: rules} do
      dispatch = fn tool_call -> {:ok, {:ran, tool_call.tool}} end
      tool_call = tool_call(:kubectl, ["get", "pods"])

      assert CapabilityGate.request(tool_call, rules, opts(pubsub, dispatch)) ==
               {:ok, {:ran, :kubectl}}

      assert %Decision{decision: "executed", classification: "read", result_status: "ok"} =
               Repo.get_by(Decision, request_id: tool_call.request_id)
    end

    test "request/3 writes audit row and executes :write_dev class", %{
      pubsub: pubsub,
      rules: rules
    } do
      rules = put_in(rules.kubectl_verbs.write_dev, ["annotate"])
      tool_call = tool_call(:kubectl, ["annotate", "deployment/payments-api", "team=ops"])

      assert CapabilityGate.request(tool_call, rules, opts(pubsub, ok_dispatch(:annotated))) ==
               {:ok, :annotated}

      assert %Decision{decision: "executed", classification: "write_dev"} =
               Repo.get_by(Decision, request_id: tool_call.request_id)
    end

    test "request/3 audits and executes :write_prod_low (e.g., rollout restart)", %{
      pubsub: pubsub,
      rules: rules
    } do
      tool_call = tool_call(:kubectl, ["rollout", "restart", "deployment/payments-api"])
      Phoenix.PubSub.subscribe(pubsub, topic(tool_call))

      assert CapabilityGate.request(tool_call, rules, opts(pubsub, ok_dispatch(:restarted))) ==
               {:ok, :restarted}

      assert %Decision{decision: "executed", classification: "write_prod_low"} =
               Repo.get_by(Decision, request_id: tool_call.request_id)

      assert_receive {:gate_decision, :audit_and_execute, ^tool_call, :write_prod_low,
                      "rollout restart"}

      assert_receive {:gate_decision, :executed, _gate_id, ^tool_call, :restarted}
    end

    test "request/3 returns {:gated, gate_id} for rollout undo without executing", %{
      pubsub: pubsub,
      rules: rules
    } do
      tool_call = rollout_undo_call()
      dispatch = fn _tool_call -> flunk("gated calls must not execute before approval") end

      assert {:gated, "gate_" <> _suffix = gate_id} =
               CapabilityGate.request(tool_call, rules, opts(pubsub, dispatch))

      assert %Decision{decision: "gated", gate_id: ^gate_id, classification: "write_prod_high"} =
               AuditTrail.get_by_gate_id(gate_id)
    end

    test "request/3 broadcasts :gate_fired on :write_prod_high", %{pubsub: pubsub, rules: rules} do
      tool_call = rollout_undo_call()
      Phoenix.PubSub.subscribe(pubsub, topic(tool_call))

      assert {:gated, gate_id} =
               CapabilityGate.request(tool_call, rules, opts(pubsub, unexpected_dispatch()))

      assert_receive {:gate_fired, ^gate_id, ^tool_call, :write_prod_high, "rollout undo",
                      %{summary: "rollback bad deploy", evidence_link: "runbook://payments"}}
    end

    test "request/3 with non-SELECT SQL marks row rejected and does not execute", %{
      pubsub: pubsub,
      rules: rules
    } do
      tool_call = tool_call(:query_db, "DELETE FROM deploys")

      assert CapabilityGate.request(tool_call, rules, opts(pubsub, unexpected_dispatch())) ==
               {:error, :not_select}

      assert %Decision{decision: "rejected", classification: "read", result_status: "error"} =
               decision = Repo.get_by(Decision, request_id: tool_call.request_id)

      assert decision.result_summary =~ ":not_select"
    end

    test "request/3 with empty kubectl args marks row rejected and errors", %{
      pubsub: pubsub,
      rules: rules
    } do
      tool_call = tool_call(:kubectl, [])

      assert CapabilityGate.request(tool_call, rules, opts(pubsub, unexpected_dispatch())) ==
               {:error, :empty_args}

      assert %Decision{decision: "rejected", classification: "write_prod_high"} =
               decision = Repo.get_by(Decision, request_id: tool_call.request_id)

      assert decision.result_summary =~ ":empty_args"
    end

    test "request/3 rejects runaway scale replicas without dispatch", %{
      pubsub: pubsub,
      rules: rules
    } do
      tool_call = tool_call(:kubectl, ["scale", "deployment/payments-api", "--replicas=+10000"])

      assert CapabilityGate.request(tool_call, rules, opts(pubsub, unexpected_dispatch())) ==
               {:error, {:forbidden_replicas, "+10000"}}

      assert %Decision{
               decision: "rejected",
               classification: "write_prod_high",
               result_status: "error"
             } = decision = Repo.get_by(Decision, request_id: tool_call.request_id)

      assert decision.result_summary =~ ~s({:forbidden_replicas, "+10000"})
    end

    test "request/3 returns :unknown_tool without writing audit row", %{
      pubsub: pubsub,
      rules: rules
    } do
      tool_call = tool_call(:something_else, %{})

      assert CapabilityGate.request(tool_call, rules, opts(pubsub, unexpected_dispatch())) ==
               {:error, :unknown_tool}

      assert Repo.get_by(Decision, request_id: tool_call.request_id) == nil
    end

    test "request/3 fails closed when policy is missing", %{pubsub: pubsub, rules: rules} do
      rules =
        put_in(rules.capability_classes, Map.delete(rules.capability_classes, :write_prod_low))

      tool_call = tool_call(:kubectl, ["rollout", "restart", "deployment/payments-api"])
      Phoenix.PubSub.subscribe(pubsub, topic(tool_call))

      assert CapabilityGate.request(tool_call, rules, opts(pubsub, unexpected_dispatch())) ==
               {:error, :policy_missing}

      assert Repo.get_by(Decision, request_id: tool_call.request_id) == nil
      assert_receive {:gate_decision, :policy_missing, ^tool_call, :write_prod_low}
    end

    test "request/3 routes :prometheus_query as :read without classification hop", %{
      pubsub: pubsub,
      rules: rules
    } do
      tool_call = tool_call(:prometheus_query, "up{service=\"payments-api\"}")

      assert CapabilityGate.request(tool_call, rules, opts(pubsub, ok_dispatch(:metrics))) ==
               {:ok, :metrics}
    end

    test "request/3 routes :mcp_runbook as :read", %{pubsub: pubsub, rules: rules} do
      tool_call = tool_call(:mcp_runbook, %{"tool_name" => "read_file", "params" => %{}})

      assert CapabilityGate.request(tool_call, rules, opts(pubsub, ok_dispatch(:runbook))) ==
               {:ok, :runbook}
    end
  end

  describe "approve/3 lifecycle" do
    test "approve/3 advances row to executed and returns result", %{pubsub: pubsub, rules: rules} do
      gate_id = request_gated!(pubsub, rules)

      assert CapabilityGate.approve(
               gate_id,
               "operator-1",
               opts(pubsub, ok_dispatch(:rolled_back))
             ) ==
               {:ok, :rolled_back}

      assert %{decision: "executed", operator_ref: "operator-1", result_status: "ok"} =
               AuditTrail.get_by_gate_id(gate_id)
    end

    test "approve/3 sends {:gate_result, ...} to reply_to PID", %{pubsub: pubsub, rules: rules} do
      gate_id = request_gated!(pubsub, rules)

      assert CapabilityGate.approve(
               gate_id,
               "operator-1",
               opts(pubsub, ok_dispatch(:rolled_back), reply_to: self())
             ) == {:ok, :rolled_back}

      assert_receive {:gate_result, ^gate_id, {:ok, :rolled_back}}
    end

    test "approve/3 returns :no_pending_gate for unknown gate_id", %{pubsub: pubsub} do
      assert CapabilityGate.approve(
               "gate_missing",
               "operator-1",
               opts(pubsub, unexpected_dispatch())
             ) ==
               {:error, :no_pending_gate}
    end

    test "approve/3 second call returns :no_pending_gate (idempotent)", %{
      pubsub: pubsub,
      rules: rules
    } do
      gate_id = request_gated!(pubsub, rules)

      assert {:ok, :rolled_back} =
               CapabilityGate.approve(
                 gate_id,
                 "operator-1",
                 opts(pubsub, ok_dispatch(:rolled_back))
               )

      assert CapabilityGate.approve(gate_id, "operator-2", opts(pubsub, unexpected_dispatch())) ==
               {:error, :no_pending_gate}
    end

    test "approve/3 resolves exactly once under concurrent double approval", %{
      pubsub: pubsub,
      rules: rules,
      sandbox_owner: sandbox_owner
    } do
      gate_id = request_gated!(pubsub, rules)
      parent = self()

      dispatch = fn _tool_call ->
        send(parent, :dispatched)
        {:ok, :rolled_back}
      end

      release_ref = make_ref()

      tasks =
        ["operator-1", "operator-2"]
        |> Enum.map(fn operator ->
          Task.async(fn ->
            Sandbox.allow(Repo, sandbox_owner, self())
            send(parent, {:ready, operator})
            assert_receive {^release_ref, :go}, 1_000
            CapabilityGate.approve(gate_id, operator, opts(pubsub, dispatch))
          end)
        end)

      assert_receive {:ready, "operator-1"}
      assert_receive {:ready, "operator-2"}
      Enum.each(tasks, fn task -> send(task.pid, {release_ref, :go}) end)
      results = Task.await_many(tasks, 5_000)

      assert Enum.count(results, &match?({:ok, :rolled_back}, &1)) == 1
      assert Enum.count(results, &match?({:error, :no_pending_gate}, &1)) == 1
      assert_received :dispatched
      refute_received :dispatched
      assert %{decision: "executed"} = AuditTrail.get_by_gate_id(gate_id)
    end

    test "approve/3 returns audit_write_failed when approval claim fails", %{pubsub: pubsub} do
      Phoenix.PubSub.subscribe(pubsub, "alert:alert-claim-fail")

      Pageless.AuditTrailMock
      |> expect(:get_by_gate_id, fn "gate_claim_fail" ->
        decision_fixture(%{gate_id: "gate_claim_fail", alert_id: "alert-claim-fail"})
      end)
      |> expect(:claim_gate_for_approval, fn "gate_claim_fail", "operator-1" ->
        {:error, %Ecto.Changeset{}}
      end)

      assert CapabilityGate.approve(
               "gate_claim_fail",
               "operator-1",
               opts(pubsub, unexpected_dispatch(), repo: Pageless.AuditTrailMock)
             ) == {:error, :audit_write_failed}

      assert_receive {:gate_decision, :audit_failed, "gate_claim_fail", :approve_failed}
    end
  end

  describe "deny/4 lifecycle" do
    test "deny/4 transitions row to denied and stores reason", %{pubsub: pubsub, rules: rules} do
      gate_id = request_gated!(pubsub, rules)

      assert CapabilityGate.deny(
               gate_id,
               "operator-1",
               "too risky",
               opts(pubsub, unexpected_dispatch())
             ) ==
               :ok

      assert %{decision: "denied", operator_ref: "operator-1", denial_reason: "too risky"} =
               AuditTrail.get_by_gate_id(gate_id)
    end

    test "deny/4 broadcasts :gate_decision :denied", %{pubsub: pubsub, rules: rules} do
      gate_id = request_gated!(pubsub, rules)
      Phoenix.PubSub.subscribe(pubsub, "alert:alert-123")

      assert CapabilityGate.deny(
               gate_id,
               "operator-1",
               "unsafe",
               opts(pubsub, unexpected_dispatch())
             ) ==
               :ok

      assert_receive {:gate_decision, :denied, ^gate_id, "operator-1", "unsafe"}
    end

    test "deny/4 sends {:gate_result, ..., {:error, :denied, _}} to reply_to PID", %{
      pubsub: pubsub,
      rules: rules
    } do
      gate_id = request_gated!(pubsub, rules)

      assert CapabilityGate.deny(
               gate_id,
               "operator-1",
               "unsafe",
               opts(pubsub, unexpected_dispatch(), reply_to: self())
             ) == :ok

      assert_receive {:gate_result, ^gate_id, {:error, :denied, "unsafe"}}
    end

    test "deny/4 returns :no_pending_gate for unknown gate_id", %{pubsub: pubsub} do
      assert CapabilityGate.deny(
               "gate_missing",
               "operator-1",
               "unsafe",
               opts(pubsub, unexpected_dispatch())
             ) ==
               {:error, :no_pending_gate}
    end

    test "deny/4 returns audit_write_failed when denial claim fails", %{pubsub: pubsub} do
      Phoenix.PubSub.subscribe(pubsub, "alert:alert-deny-fail")

      Pageless.AuditTrailMock
      |> expect(:get_by_gate_id, fn "gate_deny_fail" ->
        decision_fixture(%{gate_id: "gate_deny_fail", alert_id: "alert-deny-fail"})
      end)
      |> expect(:claim_gate_for_denial, fn "gate_deny_fail", "operator-1", "unsafe" ->
        {:error, %Ecto.Changeset{}}
      end)

      assert CapabilityGate.deny(
               "gate_deny_fail",
               "operator-1",
               "unsafe",
               opts(pubsub, unexpected_dispatch(), repo: Pageless.AuditTrailMock)
             ) == {:error, :audit_write_failed}

      assert_receive {:gate_decision, :audit_failed, "gate_deny_fail", :deny_failed}
    end

    test "approve/3 and deny/4 race resolves one outcome only", %{
      pubsub: pubsub,
      rules: rules,
      sandbox_owner: sandbox_owner
    } do
      gate_id = request_gated!(pubsub, rules)
      parent = self()

      dispatch = fn _tool_call ->
        send(parent, :dispatched)
        {:ok, :rolled_back}
      end

      release_ref = make_ref()

      tasks = [
        Task.async(fn ->
          Sandbox.allow(Repo, sandbox_owner, self())
          send(parent, {:ready, :approve})
          assert_receive {^release_ref, :go}, 1_000
          CapabilityGate.approve(gate_id, "operator-approve", opts(pubsub, dispatch))
        end),
        Task.async(fn ->
          Sandbox.allow(Repo, sandbox_owner, self())
          send(parent, {:ready, :deny})
          assert_receive {^release_ref, :go}, 1_000

          CapabilityGate.deny(
            gate_id,
            "operator-deny",
            "unsafe",
            opts(pubsub, unexpected_dispatch())
          )
        end)
      ]

      assert_receive {:ready, :approve}
      assert_receive {:ready, :deny}
      Enum.each(tasks, fn task -> send(task.pid, {release_ref, :go}) end)
      results = Task.await_many(tasks, 5_000)

      assert Enum.count(results, &(&1 in [{:ok, :rolled_back}, :ok])) == 1
      assert Enum.count(results, &match?({:error, :no_pending_gate}, &1)) == 1

      case AuditTrail.get_by_gate_id(gate_id).decision do
        "executed" -> assert_received :dispatched
        "denied" -> refute_received :dispatched
      end
    end
  end

  describe "audit rows and fail-closed paths" do
    test "request/3 fails closed when audit write fails", %{pubsub: pubsub, rules: rules} do
      tool_call = tool_call(:kubectl, ["rollout", "restart", "deployment/payments-api"])
      Phoenix.PubSub.subscribe(pubsub, topic(tool_call))

      Pageless.AuditTrailMock
      |> expect(:record_decision, fn _attrs -> {:error, %Ecto.Changeset{}} end)

      assert CapabilityGate.request(
               tool_call,
               rules,
               opts(pubsub, unexpected_dispatch(), repo: Pageless.AuditTrailMock)
             ) == {:error, :audit_write_failed}

      assert_receive {:gate_decision, :audit_failed, ^tool_call, :record_decision}
    end

    test "request/3 returns audit_write_failed when rejection audit fails", %{
      pubsub: pubsub,
      rules: rules
    } do
      tool_call = tool_call(:query_db, "DELETE FROM deploys")
      Phoenix.PubSub.subscribe(pubsub, topic(tool_call))

      Pageless.AuditTrailMock
      |> expect(:record_decision, fn _attrs -> {:error, %Ecto.Changeset{}} end)

      assert CapabilityGate.request(
               tool_call,
               rules,
               opts(pubsub, unexpected_dispatch(), repo: Pageless.AuditTrailMock)
             ) == {:error, :audit_write_failed}

      assert_receive {:gate_decision, :audit_failed, ^tool_call, :record_decision}
    end

    test "post-dispatch audit update failure returns audit_write_failed", %{
      pubsub: pubsub,
      rules: rules
    } do
      tool_call = tool_call(:kubectl, ["rollout", "restart", "deployment/payments-api"])
      Phoenix.PubSub.subscribe(pubsub, topic(tool_call))

      Pageless.AuditTrailMock
      |> expect(:record_decision, fn attrs -> {:ok, decision_fixture(attrs)} end)
      |> expect(:update_decision, fn _decision, _attrs -> {:error, %Ecto.Changeset{}} end)

      assert CapabilityGate.request(
               tool_call,
               rules,
               opts(pubsub, ok_dispatch(:restarted),
                 repo: Pageless.AuditTrailMock,
                 reply_to: self()
               )
             ) == {:error, :audit_write_failed}

      assert_receive {:gate_decision, :audit_failed, _gate_id, :update_decision}
      assert_receive {:gate_result, _gate_id, {:error, :audit_write_failed}}
    end

    test "approve/3 post-dispatch audit update failure returns audit_write_failed", %{
      pubsub: pubsub
    } do
      decision = decision_fixture(%{gate_id: "gate_update_fail", alert_id: "alert-update-fail"})
      Phoenix.PubSub.subscribe(pubsub, "alert:alert-update-fail")

      Pageless.AuditTrailMock
      |> expect(:get_by_gate_id, fn "gate_update_fail" -> decision end)
      |> expect(:claim_gate_for_approval, fn "gate_update_fail", "operator-1" ->
        {:ok, %{decision | decision: "approved", operator_ref: "operator-1"}}
      end)
      |> expect(:update_decision, fn _decision, _attrs -> {:error, %Ecto.Changeset{}} end)

      assert CapabilityGate.approve(
               "gate_update_fail",
               "operator-1",
               opts(pubsub, ok_dispatch(:rolled_back),
                 repo: Pageless.AuditTrailMock,
                 reply_to: self()
               )
             ) == {:error, :audit_write_failed}

      assert_receive {:gate_decision, :audit_failed, "gate_update_fail", :update_decision}
      assert_receive {:gate_result, "gate_update_fail", {:error, :audit_write_failed}}
    end

    test "approve/3 preserves legacy pending-gate reasoning context", %{pubsub: pubsub} do
      reasoning_context = %{summary: "manual rollback", evidence_link: "runbook://legacy"}

      decision =
        decision_fixture(%{
          gate_id: "gate_legacy_context",
          alert_id: "alert-legacy-context",
          result_summary: Jason.encode!(%{reasoning_context: reasoning_context})
        })

      Phoenix.PubSub.subscribe(pubsub, "alert:alert-legacy-context")

      expected_call = %ToolCall{
        tool: :kubectl,
        args: ["rollout", "undo", "deployment/payments-api"],
        agent_id: decision.agent_id,
        agent_pid_inspect: decision.agent_pid_inspect,
        alert_id: decision.alert_id,
        request_id: decision.request_id,
        reasoning_context: reasoning_context
      }

      Pageless.AuditTrailMock
      |> expect(:get_by_gate_id, fn "gate_legacy_context" -> decision end)
      |> expect(:claim_gate_for_approval, fn "gate_legacy_context", "operator-1" ->
        {:ok, %{decision | decision: "approved", operator_ref: "operator-1"}}
      end)
      |> expect(:update_decision, fn _decision, attrs ->
        assert %{decision: "executed", result_status: "ok"} = attrs
        {:ok, %{decision | decision: "executed", result_status: "ok"}}
      end)

      assert CapabilityGate.approve(
               "gate_legacy_context",
               "operator-1",
               opts(pubsub, ok_dispatch(:rolled_back), repo: Pageless.AuditTrailMock)
             ) == {:ok, :rolled_back}

      assert_receive {:gate_decision, :executed, "gate_legacy_context", ^expected_call,
                      :rolled_back}
    end

    test "approve/3 preserves maps nested inside list reasoning context", %{pubsub: pubsub} do
      reasoning_context = %{
        summary: "manual rollback",
        evidence: [%{link: "runbook://nested", confidence: "high"}]
      }

      decision =
        decision_fixture(%{
          gate_id: "gate_nested_context",
          alert_id: "alert-nested-context",
          result_summary: Jason.encode!(%{reasoning_context: reasoning_context})
        })

      Phoenix.PubSub.subscribe(pubsub, "alert:alert-nested-context")

      expected_call = %ToolCall{
        tool: :kubectl,
        args: ["rollout", "undo", "deployment/payments-api"],
        agent_id: decision.agent_id,
        agent_pid_inspect: decision.agent_pid_inspect,
        alert_id: decision.alert_id,
        request_id: decision.request_id,
        reasoning_context: reasoning_context
      }

      Pageless.AuditTrailMock
      |> expect(:get_by_gate_id, fn "gate_nested_context" -> decision end)
      |> expect(:claim_gate_for_approval, fn "gate_nested_context", "operator-1" ->
        {:ok, %{decision | decision: "approved", operator_ref: "operator-1"}}
      end)
      |> expect(:update_decision, fn _decision, attrs ->
        assert %{decision: "executed", result_status: "ok"} = attrs
        {:ok, %{decision | decision: "executed", result_status: "ok"}}
      end)

      assert CapabilityGate.approve(
               "gate_nested_context",
               "operator-1",
               opts(pubsub, ok_dispatch(:rolled_back), repo: Pageless.AuditTrailMock)
             ) == {:ok, :rolled_back}

      assert_receive {:gate_decision, :executed, "gate_nested_context", ^expected_call,
                      :rolled_back}
    end

    test "request/3 generates distinct gate_ids under concurrent calls", %{
      pubsub: pubsub,
      rules: rules,
      sandbox_owner: sandbox_owner
    } do
      tasks =
        for suffix <- ["one", "two"] do
          Task.async(fn ->
            Sandbox.allow(Repo, sandbox_owner, self())

            CapabilityGate.request(
              rollout_undo_call("alert-#{suffix}"),
              rules,
              opts(pubsub, unexpected_dispatch())
            )
          end)
        end

      assert [{:gated, first_gate_id}, {:gated, second_gate_id}] = Task.await_many(tasks, 5_000)
      refute first_gate_id == second_gate_id
      assert %Decision{} = AuditTrail.get_by_gate_id(first_gate_id)
      assert %Decision{} = AuditTrail.get_by_gate_id(second_gate_id)
    end

    test "request/3 stores kubectl args as %{argv: [...]} in audit row", %{
      pubsub: pubsub,
      rules: rules
    } do
      args = ["rollout", "undo", "deployment/x"]
      gate_id = request_gated!(pubsub, rules, tool_call(:kubectl, args))

      assert %{args: %{"argv" => ^args}} = AuditTrail.get_by_gate_id(gate_id)
    end

    test "request/3 stores query_db args as sql map", %{pubsub: pubsub, rules: rules} do
      sql = "SELECT * FROM deploys"
      tool_call = tool_call(:query_db, sql)

      assert {:ok, :selected} =
               CapabilityGate.request(tool_call, rules, opts(pubsub, ok_dispatch(:selected)))

      assert %{args: %{"sql" => ^sql}} = Repo.get_by(Decision, request_id: tool_call.request_id)
    end

    test "request/3 stores prometheus_query args as promql map", %{pubsub: pubsub, rules: rules} do
      promql = "up{service=\"payments-api\"}"
      tool_call = tool_call(:prometheus_query, promql)

      assert {:ok, :metrics} =
               CapabilityGate.request(tool_call, rules, opts(pubsub, ok_dispatch(:metrics)))

      assert %{args: %{"promql" => ^promql}} =
               Repo.get_by(Decision, request_id: tool_call.request_id)
    end

    test "request/3 stores mcp_runbook args as MCP map", %{pubsub: pubsub, rules: rules} do
      args = %{"tool_name" => "read_file", "params" => %{"path" => "runbooks/payments-api.md"}}
      tool_call = tool_call(:mcp_runbook, args)

      assert {:ok, :runbook} =
               CapabilityGate.request(tool_call, rules, opts(pubsub, ok_dispatch(:runbook)))

      assert %{args: ^args} = Repo.get_by(Decision, request_id: tool_call.request_id)
    end

    test "request/3 populates extracted_verb on kubectl audit rows", %{
      pubsub: pubsub,
      rules: rules
    } do
      gate_id = request_gated!(pubsub, rules)

      assert %{extracted_verb: "rollout undo"} = AuditTrail.get_by_gate_id(gate_id)
    end

    test "request/3 leaves extracted_verb nil for non-kubectl tools", %{
      pubsub: pubsub,
      rules: rules
    } do
      tool_call = tool_call(:query_db, "SELECT * FROM deploys")

      assert {:ok, :selected} =
               CapabilityGate.request(tool_call, rules, opts(pubsub, ok_dispatch(:selected)))

      assert %{extracted_verb: nil} = Repo.get_by(Decision, request_id: tool_call.request_id)
    end

    test "request/3 retries gate_id collisions and fails closed after three attempts", %{
      pubsub: pubsub,
      rules: rules
    } do
      tool_call = rollout_undo_call()

      Pageless.AuditTrailMock
      |> expect(:record_decision, 3, fn _attrs -> {:error, unique_gate_id_changeset()} end)

      assert CapabilityGate.request(
               tool_call,
               rules,
               opts(pubsub, unexpected_dispatch(), repo: Pageless.AuditTrailMock)
             ) == {:error, :gate_id_collision}
    end

    test "tool_dispatch exceptions fail closed", %{pubsub: pubsub, rules: rules} do
      tool_call = tool_call(:kubectl, ["rollout", "restart", "deployment/payments-api"])
      Phoenix.PubSub.subscribe(pubsub, topic(tool_call))

      dispatch = fn _tool_call -> raise "boom" end

      assert CapabilityGate.request(tool_call, rules, opts(pubsub, dispatch)) ==
               {:error, :tool_dispatch_failed}

      assert %{decision: "execution_failed", result_status: "error"} =
               Repo.get_by(Decision, request_id: tool_call.request_id)

      assert_receive {:gate_decision, :execution_failed, _gate_id, ^tool_call,
                      :tool_dispatch_failed}
    end

    test "approve/3 tool_dispatch exceptions fail closed", %{pubsub: pubsub, rules: rules} do
      gate_id = request_gated!(pubsub, rules)
      Phoenix.PubSub.subscribe(pubsub, "alert:alert-123")
      dispatch = fn _tool_call -> raise "boom" end

      assert CapabilityGate.approve(gate_id, "operator-1", opts(pubsub, dispatch)) ==
               {:error, :tool_dispatch_failed}

      assert %{decision: "execution_failed", result_status: "error"} =
               AuditTrail.get_by_gate_id(gate_id)

      assert_receive {:gate_decision, :execution_failed, ^gate_id, _tool_call,
                      :tool_dispatch_failed}
    end
  end

  describe "system acceptance" do
    @tag :acceptance
    test "operator-visible rollout undo is gated and dispatches only after approval", %{
      pubsub: pubsub,
      rules: rules
    } do
      tool_call = rollout_undo_call()
      Phoenix.PubSub.subscribe(pubsub, topic(tool_call))
      parent = self()

      dispatch = fn dispatched_call ->
        send(parent, {:dispatch, dispatched_call})
        {:ok, :rolled_back}
      end

      assert {:gated, gate_id} = CapabilityGate.request(tool_call, rules, opts(pubsub, dispatch))

      assert_receive {:gate_fired, ^gate_id, ^tool_call, :write_prod_high, "rollout undo",
                      %{summary: "rollback bad deploy", evidence_link: "runbook://payments"}}

      refute_received {:dispatch, _tool_call}

      assert CapabilityGate.approve(gate_id, "operator-1", opts(pubsub, dispatch)) ==
               {:ok, :rolled_back}

      assert_receive {:dispatch, ^tool_call}
      refute_received {:dispatch, _tool_call}
    end
  end

  defp default_rules do
    Rules.load!(Path.expand("../../fixtures/pageless_rules/default.yaml", __DIR__))
  end

  defp opts(pubsub, dispatch, overrides \\ []) do
    [tool_dispatch: dispatch, pubsub: pubsub, repo: AuditTrail]
    |> Keyword.merge(overrides)
  end

  defp ok_dispatch(result), do: fn _tool_call -> {:ok, result} end

  defp unexpected_dispatch, do: fn _tool_call -> flunk("tool_dispatch should not be invoked") end

  defp request_gated!(pubsub, rules, tool_call \\ rollout_undo_call()) do
    assert {:gated, gate_id} =
             CapabilityGate.request(tool_call, rules, opts(pubsub, unexpected_dispatch()))

    gate_id
  end

  defp rollout_undo_call(alert_id \\ "alert-123") do
    tool_call(:kubectl, ["rollout", "undo", "deployment/payments-api", "-n", "prod"], alert_id)
  end

  defp tool_call(tool, args, alert_id \\ "alert-123") do
    struct(ToolCall, %{
      tool: tool,
      args: args,
      agent_id: Ecto.UUID.generate(),
      agent_pid_inspect: inspect(self()),
      alert_id: alert_id,
      request_id: unique("req"),
      reasoning_context: %{summary: "rollback bad deploy", evidence_link: "runbook://payments"}
    })
  end

  defp topic(%{alert_id: alert_id}), do: "alert:#{alert_id}"

  defp decision_fixture(attrs) do
    %Decision{
      id: Ecto.UUID.generate(),
      request_id: Map.get(attrs, :request_id) || Map.get(attrs, "request_id") || unique("req"),
      gate_id: Map.get(attrs, :gate_id) || Map.get(attrs, "gate_id"),
      alert_id: Map.get(attrs, :alert_id) || Map.get(attrs, "alert_id") || "alert-123",
      agent_id: Map.get(attrs, :agent_id) || Map.get(attrs, "agent_id") || Ecto.UUID.generate(),
      agent_pid_inspect:
        Map.get(attrs, :agent_pid_inspect) || Map.get(attrs, "agent_pid_inspect") ||
          inspect(self()),
      tool: Map.get(attrs, :tool) || Map.get(attrs, "tool") || "kubectl",
      args:
        Map.get(attrs, :args) || Map.get(attrs, "args") ||
          %{
            "argv" => ["rollout", "undo", "deployment/payments-api"]
          },
      extracted_verb:
        Map.get(attrs, :extracted_verb) || Map.get(attrs, "extracted_verb") || "rollout undo",
      classification:
        Map.get(attrs, :classification) || Map.get(attrs, "classification") || "write_prod_high",
      decision: Map.get(attrs, :decision) || Map.get(attrs, "decision") || "gated",
      result_summary: Map.get(attrs, :result_summary) || Map.get(attrs, "result_summary")
    }
  end

  defp unique(prefix), do: "#{prefix}_#{System.unique_integer([:positive])}"

  defp unique_atom(prefix), do: String.to_atom(unique(prefix))

  defp unique_gate_id_changeset do
    %Decision{}
    |> Ecto.Changeset.change(gate_id: "gate_duplicate")
    |> Ecto.Changeset.add_error(:gate_id, "has already been taken", constraint: :unique)
  end
end
