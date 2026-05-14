defmodule Pageless.Proc.RemediatorTest.EscalatorProbe do
  @moduledoc "Escalator test double that keeps start opts queryable by PID."

  use GenServer

  @doc "Starts a probe escalator process with the provided opts as state."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Returns the opts used to start the probe escalator."
  @spec opts(pid()) :: keyword()
  def opts(pid), do: GenServer.call(pid, :opts)

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def handle_call(:opts, _from, opts), do: {:reply, opts, opts}
end

defmodule Pageless.Proc.RemediatorTest.ForbiddenGate do
  @moduledoc "Gate double that fails if the Remediator calls it."

  @doc "Raises because this path must stop before gate dispatch."
  @spec request(term(), term(), keyword()) :: no_return()
  def request(_tool_call, _rules, _opts), do: raise("gate must not be called")
end

defmodule Pageless.Proc.RemediatorTest.PolicyDeniedGate do
  @moduledoc "Gate double that deterministically rejects a proposed action."

  @doc "Returns a policy-denied gate result."
  @spec request(term(), term(), keyword()) :: {:error, :policy_denied}
  def request(_tool_call, _rules, _opts), do: {:error, :policy_denied}
end

defmodule Pageless.Proc.RemediatorTest do
  @moduledoc "Tests the Remediator proposal, gate, execution, and escalation lifecycle."

  use Pageless.DataCase, async: true

  import Hammox

  alias Pageless.AlertEnvelope
  alias Pageless.Config.Rules
  alias Pageless.Data.AgentState
  alias Pageless.Governance.CapabilityGate
  alias Pageless.Proc.Remediator
  alias Pageless.Proc.RemediatorTest.EscalatorProbe
  alias Pageless.PubSubHelpers
  alias Pageless.Sup.Alert
  alias Pageless.SupHelpers
  alias Pageless.Svc.GeminiClient.FunctionCall
  alias Pageless.Svc.GeminiClient.Response

  setup :verify_on_exit!

  setup do
    broker = PubSubHelpers.start_isolated_pubsub()
    :ok = PubSubHelpers.subscribe(broker, "alert:alert-remediator")
    %{pubsub: broker}
  end

  describe "setup" do
    test "spawns with a state handshake, audit row, and PubSub event", %{
      pubsub: broker,
      sandbox_owner: sandbox_owner
    } do
      %{pid: pid, agent_id: agent_id} = start_remediator(broker, sandbox_owner)

      assert Process.alive?(pid)
      assert agent_id =~ ~r/^remediator-\d+$/
      assert_receive {:remediator_spawned, ^agent_id, "alert-remediator"}

      [spawned] = AgentState.history(Pageless.Repo, agent_id, event_type: :spawned)
      assert spawned.agent_type == :remediator
      assert spawned.payload["envelope_summary"]["alert_id"] == "alert-remediator"
      assert spawned.payload["envelope_summary"]["source"] == "pagerduty"
      assert spawned.payload["findings_summary"]["count"] == 2
      assert spawned.payload["findings_summary"]["hypothesis"] =~ "bad deploy"
    end
  end

  describe "gated B5 money beat" do
    @tag :acceptance
    test "rollout undo waits for operator approval, executes once, and completes", %{
      pubsub: broker,
      sandbox_owner: sandbox_owner
    } do
      stub_proposal_from_gemini(rollout_undo_args())
      parent = self()

      dispatch = fn tool_call ->
        send(parent, {:dispatch, tool_call})
        {:ok, %{stdout: "deployment.apps/payments-api rolled back", exit_code: 0}}
      end

      %{pid: pid, agent_id: agent_id} =
        start_remediator(broker, sandbox_owner, tool_dispatch: dispatch)

      :ok = Remediator.kick_off(pid)
      monitor_ref = Process.monitor(pid)

      assert_receive {:remediator_reasoning, ^agent_id, rationale}
      assert rationale =~ "Restart loops back"

      assert_receive {:gate_fired, gate_id, tool_call, :write_prod_high, "rollout undo", context}
      assert tool_call.args == rollout_undo_args()
      assert context.summary =~ "rollback restores"
      refute_received {:dispatch, _tool_call}

      assert_receive {:remediator_action_proposed, ^agent_id, "alert-remediator", proposed}
      assert proposed.action == :rollout_undo
      assert proposed.gate_id == gate_id
      assert length(proposed.considered_alternatives) >= 1

      assert CapabilityGate.approve(gate_id, "operator-test",
               tool_dispatch: dispatch,
               pubsub: broker,
               repo: Pageless.AuditTrail,
               reply_to: pid
             ) == {:ok, %{stdout: "deployment.apps/payments-api rolled back", exit_code: 0}}

      assert_receive {:gate_decision, :approved, ^gate_id, "operator-test"}
      assert_receive {:dispatch, dispatched_call}
      assert dispatched_call.args == rollout_undo_args()
      refute_received {:dispatch, _tool_call}

      assert_receive {:remediator_action_executed, ^agent_id, "alert-remediator", executed}
      assert executed.action == :rollout_undo
      assert executed.gate_id == gate_id
      assert executed.result.exit_code == 0

      assert_receive {:remediator_complete, "alert-remediator", ^agent_id,
                      %{outcome: :gated_then_executed, action: :rollout_undo, gate_id: ^gate_id}}

      assert_receive {:DOWN, ^monitor_ref, :process, ^pid, reason}
      assert clean_exit?(reason)
      refute Process.alive?(pid)

      rows = AgentState.history(Pageless.Repo, agent_id)

      assert Enum.map(rows, & &1.event_type) == [
               :spawned,
               :reasoning_line,
               :findings,
               :tool_call,
               :final_state
             ]

      assert Enum.at(rows, 3).payload["gate_id"] == gate_id
      assert Enum.at(rows, 3).payload["result"]["kind"] == "ok"
      assert List.last(rows).payload["outcome"] == "gated_then_executed"
    end
  end

  describe "auto-fire path" do
    test "rollout restart executes immediately without firing an approval gate", %{
      pubsub: broker,
      sandbox_owner: sandbox_owner
    } do
      stub_proposal_from_gemini(rollout_restart_args(),
        action: "rollout_restart",
        classification_hint: "write_prod_low",
        rationale: "Restart refreshes pods without changing prod data."
      )

      dispatch = fn tool_call ->
        send(self(), {:dispatch, tool_call})
        {:ok, %{stdout: "deployment.apps/payments-api restarted", exit_code: 0}}
      end

      %{pid: pid, agent_id: agent_id} =
        start_remediator(broker, sandbox_owner, tool_dispatch: dispatch)

      :ok = Remediator.kick_off(pid)
      monitor_ref = Process.monitor(pid)

      assert_receive {:remediator_action_proposed, ^agent_id, "alert-remediator", %{gate_id: nil}}
      assert_receive {:remediator_action_executed, ^agent_id, "alert-remediator", executed}
      assert executed.action == :rollout_restart
      assert executed.gate_id == nil

      assert_receive {:remediator_complete, "alert-remediator", ^agent_id,
                      %{outcome: :auto_fired, gate_id: nil}}

      assert_receive {:DOWN, ^monitor_ref, :process, ^pid, reason}
      assert clean_exit?(reason)

      rows = AgentState.history(Pageless.Repo, agent_id)
      assert List.last(rows).payload["outcome"] == "auto_fired"
    end
  end

  describe "escalation paths" do
    test "denied gated rollback escalates without dispatching kubectl", %{
      pubsub: broker,
      sandbox_owner: sandbox_owner
    } do
      stub_proposal_from_gemini(rollout_undo_args())

      forbidden_dispatch = fn tool_call ->
        send(self(), {:unexpected_dispatch, tool_call})
        {:ok, :unexpected}
      end

      %{pid: pid, agent_id: agent_id} =
        start_remediator(broker, sandbox_owner, tool_dispatch: forbidden_dispatch)

      :ok = Remediator.kick_off(pid)
      monitor_ref = Process.monitor(pid)

      assert_receive {:gate_fired, gate_id, _tool_call, :write_prod_high, "rollout undo",
                      _context}

      assert_receive {:remediator_action_proposed, ^agent_id, "alert-remediator",
                      %{gate_id: ^gate_id}}

      assert CapabilityGate.deny(
               gate_id,
               "operator-test",
               "Denied: prefer to investigate further first",
               tool_dispatch: forbidden_dispatch,
               pubsub: broker,
               repo: Pageless.AuditTrail,
               reply_to: pid
             ) == :ok

      refute_received {:unexpected_dispatch, _tool_call}

      assert_receive {:remediator_action_failed, ^agent_id, "alert-remediator", failed}
      assert failed.reason == {:denied, "Denied: prefer to investigate further first"}
      assert failed.gate_id == gate_id

      assert_receive {:remediator_escalating, ^agent_id, "alert-remediator", escalator_pid,
                      {:denied, "Denied: prefer to investigate further first"}}

      assert Keyword.fetch!(EscalatorProbe.opts(escalator_pid), :denial_reason) ==
               "Denied: prefer to investigate further first"

      assert_receive {:remediator_complete, "alert-remediator", ^agent_id,
                      %{outcome: :denied_then_escalated, gate_id: ^gate_id}}

      assert_receive {:DOWN, ^monitor_ref, :process, ^pid, reason}
      assert clean_exit?(reason)
    end

    test "Gemini errors escalate before constructing a gate request", %{
      pubsub: broker,
      sandbox_owner: sandbox_owner
    } do
      stub(Pageless.Svc.GeminiClient.Mock, :generate, fn _opts -> {:error, :gemini_timeout} end)

      %{pid: pid, agent_id: agent_id} =
        start_remediator(broker, sandbox_owner,
          gate_module: Pageless.Proc.RemediatorTest.ForbiddenGate,
          tool_dispatch: forbidden_dispatch()
        )

      :ok = Remediator.kick_off(pid)
      monitor_ref = Process.monitor(pid)

      assert_receive {:remediator_action_failed, ^agent_id, "alert-remediator", failed}
      assert failed.reason == :gemini_timeout
      assert failed.action == nil

      assert_receive {:remediator_escalating, ^agent_id, "alert-remediator", escalator_pid,
                      :gemini_timeout}

      assert Keyword.fetch!(EscalatorProbe.opts(escalator_pid), :failure_reason) ==
               :gemini_timeout

      assert_receive {:remediator_complete, "alert-remediator", ^agent_id,
                      %{outcome: :failed_then_escalated, action: nil, reason: :gemini_timeout}}

      assert_receive {:DOWN, ^monitor_ref, :process, ^pid, reason}
      assert clean_exit?(reason)

      rows = AgentState.history(Pageless.Repo, agent_id)
      assert Enum.find(rows, &(&1.event_type == :tool_error)).payload["tool"] == "gemini.generate"

      assert Enum.find(rows, &(&1.event_type == :tool_error)).payload["reason"] ==
               "gemini_timeout"
    end

    test "missing Gemini function call escalates without synthesizing remediation", %{
      pubsub: broker,
      sandbox_owner: sandbox_owner
    } do
      stub(Pageless.Svc.GeminiClient.Mock, :generate, fn _opts ->
        {:ok, struct(Response, text: "I don't know", function_calls: [])}
      end)

      %{pid: pid, agent_id: agent_id} =
        start_remediator(broker, sandbox_owner,
          gate_module: Pageless.Proc.RemediatorTest.ForbiddenGate,
          tool_dispatch: forbidden_dispatch()
        )

      :ok = Remediator.kick_off(pid)
      monitor_ref = Process.monitor(pid)

      assert_receive {:remediator_action_failed, ^agent_id, "alert-remediator", failed}
      assert failed.reason == :no_function_call
      assert failed.action == nil
      refute_received {:remediator_action_proposed, ^agent_id, "alert-remediator", _proposal}
      refute_received {:remediator_action_executed, ^agent_id, "alert-remediator", _executed}

      assert_receive {:remediator_escalating, ^agent_id, "alert-remediator", _escalator_pid,
                      :no_function_call}

      assert_receive {:remediator_complete, "alert-remediator", ^agent_id,
                      %{outcome: :failed_then_escalated, action: nil, reason: :no_function_call}}

      assert_receive {:DOWN, ^monitor_ref, :process, ^pid, reason}
      assert clean_exit?(reason)

      rows = AgentState.history(Pageless.Repo, agent_id)

      assert Enum.find(rows, &(&1.event_type == :tool_error)).payload["reason"] ==
               "no_function_call"

      refute Enum.any?(rows, &(&1.event_type == :tool_call))
    end

    test "gate-side rejection escalates after persisting the proposal", %{
      pubsub: broker,
      sandbox_owner: sandbox_owner
    } do
      stub_proposal_from_gemini(rollout_undo_args())

      %{pid: pid, agent_id: agent_id} =
        start_remediator(broker, sandbox_owner,
          gate_module: Pageless.Proc.RemediatorTest.PolicyDeniedGate,
          tool_dispatch: forbidden_dispatch()
        )

      :ok = Remediator.kick_off(pid)
      monitor_ref = Process.monitor(pid)

      assert_receive {:remediator_action_proposed, ^agent_id, "alert-remediator", proposed}
      assert proposed.action == :rollout_undo
      assert proposed.gate_id == nil

      assert_receive {:remediator_action_failed, ^agent_id, "alert-remediator", failed}
      assert failed.reason == :policy_denied
      assert failed.gate_id == nil

      assert_receive {:remediator_escalating, ^agent_id, "alert-remediator", _escalator_pid,
                      :policy_denied}

      assert_receive {:remediator_complete, "alert-remediator", ^agent_id,
                      %{outcome: :failed_then_escalated, reason: :policy_denied}}

      assert_receive {:DOWN, ^monitor_ref, :process, ^pid, reason}
      assert clean_exit?(reason)

      rows = AgentState.history(Pageless.Repo, agent_id)
      assert Enum.any?(rows, &(&1.event_type == :findings))
      assert Enum.find(rows, &(&1.event_type == :tool_error)).payload["tool"] == "gate.request"
      assert List.last(rows).payload["outcome"] == "failed_then_escalated"
    end
  end

  defp stub_proposal_from_gemini(argv, overrides \\ []) do
    args =
      %{
        "action" => Keyword.get(overrides, :action, "rollout_undo"),
        "args" => argv,
        "classification_hint" => Keyword.get(overrides, :classification_hint, "write_prod_high"),
        "rationale" =>
          Keyword.get(
            overrides,
            :rationale,
            "Deploy v2.4.1 at 03:43:58 caused errors at 03:44:12. Restart loops back into bad code; rollback restores v2.4.0."
          ),
        "considered_alternatives" => [
          %{
            "action" => "rollout_restart",
            "reason_rejected" => "Restart loops back into the same broken deploy"
          }
        ]
      }

    stub(Pageless.Svc.GeminiClient.Mock, :generate, fn opts ->
      assert Keyword.fetch!(opts, :model) == :pro
      assert Keyword.fetch!(opts, :temperature) == 0.0
      assert Keyword.fetch!(opts, :tool_choice) == {:specific, "propose_action"}
      assert Keyword.fetch!(opts, :system_instruction) =~ "incident remediator"
      assert Keyword.fetch!(opts, :system_instruction) =~ "considered_alternatives"
      assert Keyword.fetch!(opts, :prompt) =~ "alert-remediator"
      assert Keyword.fetch!(opts, :prompt) =~ "bad deploy"

      [tool] = Keyword.fetch!(opts, :tools)
      [declaration] = Map.fetch!(tool, :function_declarations)
      assert declaration.name == "propose_action"

      assert declaration.parameters.required == [
               "action",
               "args",
               "classification_hint",
               "rationale",
               "considered_alternatives"
             ]

      assert declaration.parameters.properties.args.minItems == 1
      assert declaration.parameters.properties.considered_alternatives.minItems == 1

      {:ok,
       struct(Response,
         text: args["rationale"],
         function_calls: [struct(FunctionCall, name: "propose_action", args: args)]
       )}
    end)
  end

  defp start_remediator(broker, sandbox_owner, opts \\ []) do
    %{alert: alert} =
      SupHelpers.start_isolated_alert(
        envelope: envelope(),
        pubsub: broker,
        sandbox_owner: sandbox_owner,
        audit_repo: Pageless.Repo,
        gemini_client: Pageless.Svc.GeminiClient.Mock,
        parent: self()
      )

    agent_opts =
      [
        findings: findings(),
        rules: rules(),
        gate_module: Keyword.get(opts, :gate_module, CapabilityGate),
        escalator_module: EscalatorProbe,
        tool_dispatch: Keyword.get(opts, :tool_dispatch, ok_dispatch())
      ]
      |> Keyword.merge(Keyword.drop(opts, [:gate_module, :tool_dispatch]))

    assert {:ok, pid} = Alert.start_agent(alert, Remediator, agent_opts)
    assert {:ok, state} = GenServer.call(pid, :get_state)
    %{pid: pid, agent_id: state.agent_id}
  end

  defp ok_dispatch do
    fn tool_call -> {:ok, %{stdout: Enum.join(tool_call.args, " "), exit_code: 0}} end
  end

  defp forbidden_dispatch do
    fn tool_call ->
      send(self(), {:unexpected_dispatch, tool_call})
      {:error, :unexpected_dispatch}
    end
  end

  defp clean_exit?(reason) when reason in [:normal, :noproc, :shutdown], do: true
  defp clean_exit?({:shutdown, _details}), do: true
  defp clean_exit?(_reason), do: false

  defp rules do
    struct!(Rules, %{
      capability_classes: %{
        read: %{auto: true, audit: true, gated: false},
        write_dev: %{auto: true, audit: true, gated: false},
        write_prod_low: %{auto: true, audit: true, gated: false},
        write_prod_high: %{auto: false, audit: true, gated: true}
      },
      kubectl_verbs: %{
        read: ["get", "describe", "logs"],
        write_dev: [],
        write_prod_low: ["rollout restart"],
        write_prod_high: ["rollout undo"]
      },
      function_blocklist: []
    })
  end

  defp rollout_undo_args, do: ["rollout", "undo", "deployment/payments-api", "-n", "prod"]
  defp rollout_restart_args, do: ["rollout", "restart", "deployment/payments-api", "-n", "prod"]

  defp findings do
    [
      %{
        profile: :deploys,
        hypothesis: "bad deploy v2.4.1 introduced the outage",
        evidence: [%{kind: :deploy, version: "v2.4.1", deployed_at: "03:43:58Z"}]
      },
      %{
        profile: :logs,
        hypothesis: "bad deploy causes crash loop in payments-api",
        evidence: [%{kind: :log, text: "errors begin at 03:44:12Z"}]
      }
    ]
  end

  defp envelope do
    struct!(AlertEnvelope, %{
      alert_id: "alert-remediator",
      source: :pagerduty,
      source_ref: "pd-dedup-remediator",
      fingerprint: "fingerprint-remediator",
      received_at: DateTime.utc_now(),
      started_at: DateTime.utc_now(),
      status: :firing,
      severity: :critical,
      alert_class: :service_down_with_recent_deploy,
      title: "payments-api down after deploy",
      service: "payments-api",
      labels: %{"service" => "payments-api", "alertname" => "PaymentsAPIDown"},
      annotations: %{"runbook" => "https://runbooks.example/payments"},
      payload_raw: %{"fixture" => true}
    })
  end
end
