defmodule Pageless.Proc.InvestigatorTest.ForbiddenGate do
  @moduledoc "Gate double that fails if the Investigator unexpectedly dispatches a tool."

  @doc "Raises because this path must not reach the gate."
  @spec request(term(), term(), keyword()) :: no_return()
  def request(_tool_call, _rules, _opts), do: raise("gate must not be called")
end

defmodule Pageless.Proc.InvestigatorTest.ReadGate do
  @moduledoc "Gate double that validates request/3 wiring and returns a read result."

  alias Pageless.Config.Rules
  alias Pageless.Governance.ToolCall

  @doc "Validates the gate request contract and returns a deterministic tool result."
  @spec request(ToolCall.t(), Rules.t(), keyword()) :: {:ok, map()}
  def request(%ToolCall{} = tool_call, %Rules{}, opts) do
    Enum.each([:tool_dispatch, :pubsub, :repo, :reply_to], fn key ->
      Keyword.fetch!(opts, key)
    end)

    unless is_pid(Keyword.fetch!(opts, :reply_to)) do
      raise "reply_to must be the investigator pid"
    end

    {:ok,
     %{
       tool: tool_call.tool,
       args: tool_call.args,
       classification: :read,
       output: "gate-result-for-#{tool_call.tool}"
     }}
  end
end

defmodule Pageless.Proc.InvestigatorTest.ProbeGate do
  @moduledoc "Gate double that notifies the test when an unexpected pre-gate dispatch occurs."

  alias Pageless.Config.Rules
  alias Pageless.Governance.ToolCall

  @doc "Records gate dispatches through the injected repo option."
  @spec request(ToolCall.t(), Rules.t(), keyword()) :: {:ok, map()}
  def request(%ToolCall{} = tool_call, %Rules{}, opts) do
    test_pid = Keyword.fetch!(opts, :repo)
    send(test_pid, {:gate_called, tool_call})
    {:ok, %{classification: :read, output: "probe-result"}}
  end
end

defmodule Pageless.Proc.InvestigatorTest.BudgetRecordingGate do
  @moduledoc "Gate double that records the alert budget counter at dispatch time."

  alias Pageless.Config.Rules
  alias Pageless.Governance.ToolCall
  alias Pageless.Sup.Alert.State

  @doc "Sends the observed budget count to the test process."
  @spec request(ToolCall.t(), Rules.t(), keyword()) :: {:ok, map()}
  def request(%ToolCall{} = tool_call, %Rules{}, opts) do
    {test_pid, alert_state_pid} = Keyword.fetch!(opts, :repo)
    {:ok, state} = State.get(alert_state_pid)
    send(test_pid, {:gate_observed_budget, state.tool_call_count, tool_call})
    {:ok, %{classification: :read, output: "budget-recorded"}}
  end
end

defmodule Pageless.Proc.InvestigatorTest do
  @moduledoc "Tests profile-scoped Investigator reasoning and terminal paths."

  use Pageless.DataCase, async: true

  import Ecto.Query
  import ExUnit.CaptureLog
  import Hammox

  alias Pageless.AlertEnvelope
  alias Pageless.Config.Rules
  alias Pageless.Data.AgentState
  alias Pageless.Proc.Investigator
  alias Pageless.Proc.Investigator.ProfileScope
  alias Pageless.Proc.Investigator.Profile

  alias Pageless.Proc.InvestigatorTest.{
    BudgetRecordingGate,
    ForbiddenGate,
    ProbeGate,
    ReadGate
  }

  alias Pageless.Sup.Alert.State
  alias Pageless.PubSubHelpers
  alias Pageless.Svc.GeminiClient.Chunk
  alias Pageless.Svc.GeminiClient.FunctionCall

  setup :verify_on_exit!

  setup %{sandbox_owner: sandbox_owner} do
    Ecto.Adapters.SQL.Sandbox.allow(Pageless.Repo, sandbox_owner, self())

    broker = PubSubHelpers.start_isolated_pubsub()
    :ok = PubSubHelpers.subscribe(broker, "alert:alert-investigator")
    %{pubsub: broker}
  end

  describe "tool function declarations" do
    test "tool behaviours expose function schema callbacks" do
      assert {:function_call_definition, 0} in Pageless.Tools.Kubectl.Behaviour.behaviour_info(
               :callbacks
             )

      assert {:function_call_definition, 0} in Pageless.Tools.PrometheusQuery.Behaviour.behaviour_info(
               :callbacks
             )

      assert {:function_call_definition, 0} in Pageless.Tools.QueryDB.Behaviour.behaviour_info(
               :callbacks
             )

      assert {:function_call_definition, 0} in Pageless.Tools.MCPRunbook.Behaviour.behaviour_info(
               :callbacks
             )
    end
  end

  describe "Profile.from_yaml/2" do
    test "loads a valid yaml fragment and renders the prompt template" do
      {:ok, profile} = Profile.from_yaml(:logs, profile_yaml(:logs))

      assert profile.__struct__ == Profile
      assert profile.name == :logs
      assert profile.label == "Investigator: logs"
      assert profile.prompt_template =~ "Investigate <%= @service %> as logs"
      assert profile.tool_scope.kubectl == %{verbs: ["logs"]}
      assert profile.tool_scope.prometheus_query == false
      assert profile.step_limit == 3
      assert profile.reasoning_visibility == :stream
    end

    test "rejects yaml fragments missing required fields" do
      yaml = Map.delete(profile_yaml(:metrics), "prompt_template_path")

      assert Profile.from_yaml(:metrics, yaml) ==
               {:error, {:invalid_profile, :prompt_template_path}}
    end

    test "builds Gemini schemas with only the profile-scoped tools" do
      cases = [
        {:logs, %{"tool_scope" => tool_scope(kubectl: %{"verbs" => ["logs"]})}, ["kubectl"]},
        {:metrics, %{"tool_scope" => tool_scope(prometheus_query: true)}, ["prometheus_query"]},
        {:deploys,
         %{
           "tool_scope" =>
             tool_scope(
               kubectl: %{"verbs" => ["get", "describe"]},
               query_db: %{"tables" => ["deploys"]}
             )
         }, ["kubectl", "query_db"]},
        {:pool_state,
         %{
           "tool_scope" =>
             tool_scope(
               query_db: %{"tables" => ["pg_stat_activity", "pg_stat_locks"]},
               mcp_runbook: true
             )
         }, ["mcp_runbook", "query_db"]},
        {:generic,
         %{
           "tool_scope" =>
             tool_scope(
               kubectl: %{"verbs" => :all},
               prometheus_query: true,
               query_db: %{"tables" => :all},
               mcp_runbook: true
             )
         }, ["kubectl", "mcp_runbook", "prometheus_query", "query_db"]}
      ]

      for {name, overrides, expected_names} <- cases do
        {:ok, profile} = Profile.from_yaml(name, Map.merge(profile_yaml(name), overrides))

        schema = Profile.build_gemini_function_schema(profile, tool_modules())
        assert schema |> Enum.map(& &1["name"]) |> Enum.sort() == Enum.sort(expected_names)
      end
    end
  end

  describe "shipping pageless.yaml profiles" do
    test "contains the five demo investigator profiles consumed by B4" do
      rules = Rules.load!(Path.expand("../../../priv/pageless.yaml", __DIR__))

      assert rules.investigator_profiles |> Map.keys() |> Enum.sort() ==
               ~w(deploys generic logs metrics pool_state)

      for name <- [:logs, :metrics, :deploys, :pool_state, :generic] do
        yaml = Map.fetch!(rules.investigator_profiles, Atom.to_string(name))
        assert {:ok, _profile} = Profile.from_yaml(name, yaml)
      end
    end
  end

  describe "profile scope guard" do
    test "disabled tools reject with profile_violation pre-gate", %{
      pubsub: broker,
      sandbox_owner: sandbox_owner
    } do
      profile = profile!(:logs, %{"tool_scope" => tool_scope(prometheus_query: false)})
      state_pid = start_alert_state(broker, tool_call_budget: 3)
      stub_single_function_call("prometheus_query", %{"promql" => "up"})

      %{pid: pid, agent_id: agent_id} =
        start_investigator(broker, sandbox_owner, profile,
          alert_state_pid: state_pid,
          gate_module: ProbeGate,
          tool_dispatch: fn _call -> {:error, :unexpected_dispatch} end,
          audit_repo: Pageless.Repo
        )

      :ok = Investigator.kick_off(pid)

      assert_receive {:profile_violation, ^agent_id, :prometheus_query,
                      {:out_of_scope_tool, :prometheus_query}}

      refute_receive {:gate_called, _tool_call}
      assert_profile_violation_row(:prometheus_query, "out_of_scope_tool")
      assert {:ok, %{tool_call_count: 0}} = State.get(state_pid)
    end

    test "kubectl verb outside profile rejects pre-gate", %{
      pubsub: broker,
      sandbox_owner: sandbox_owner
    } do
      profile = profile!(:logs, %{"tool_scope" => tool_scope(kubectl: %{"verbs" => ["logs"]})})
      state_pid = start_alert_state(broker, tool_call_budget: 3)
      stub_single_function_call("kubectl", %{"args" => ["get", "configmaps"]})

      %{pid: pid} =
        start_investigator(broker, sandbox_owner, profile,
          alert_state_pid: state_pid,
          gate_module: ProbeGate,
          tool_dispatch: fn _call -> {:error, :unexpected_dispatch} end,
          audit_repo: Pageless.Repo
        )

      :ok = Investigator.kick_off(pid)

      assert_receive {:profile_violation, _agent_id, :kubectl, {:verb_not_in_profile, "get"}}
      refute_receive {:gate_called, _tool_call}
      assert_profile_violation_row(:kubectl, "verb_not_in_profile")
    end

    test "query_db table outside profile allowlist rejects pre-gate", %{
      pubsub: broker,
      sandbox_owner: sandbox_owner
    } do
      profile =
        profile!(:deploys, %{"tool_scope" => tool_scope(query_db: %{"tables" => ["deploys"]})})

      state_pid = start_alert_state(broker, tool_call_budget: 3)
      stub_single_function_call("query_db", %{"sql" => "SELECT * FROM audit_trail_decisions"})

      %{pid: pid} =
        start_investigator(broker, sandbox_owner, profile,
          alert_state_pid: state_pid,
          gate_module: ProbeGate,
          tool_dispatch: fn _call -> {:error, :unexpected_dispatch} end,
          audit_repo: Pageless.Repo
        )

      :ok = Investigator.kick_off(pid)

      assert_receive {:profile_violation, _agent_id, :query_db,
                      {:table_not_in_profile_allowlist, "audit_trail_decisions"}}

      refute_receive {:gate_called, _tool_call}
      assert_profile_violation_row(:query_db, "table_not_in_profile_allowlist")
    end

    test "CTE-laundered SQL blocked by profile pre-gate guard", %{
      pubsub: broker,
      sandbox_owner: sandbox_owner
    } do
      profile =
        profile!(:deploys, %{"tool_scope" => tool_scope(query_db: %{"tables" => ["deploys"]})})

      state_pid = start_alert_state(broker, tool_call_budget: 3)

      sql = "WITH ok AS (SELECT * FROM audit_trail_decisions) SELECT * FROM ok"
      stub_single_function_call("query_db", %{"sql" => sql})

      %{pid: pid} =
        start_investigator(broker, sandbox_owner, profile,
          alert_state_pid: state_pid,
          gate_module: ProbeGate,
          tool_dispatch: fn _call -> {:error, :unexpected_dispatch} end,
          audit_repo: Pageless.Repo
        )

      :ok = Investigator.kick_off(pid)

      assert_receive {:profile_violation, _agent_id, :query_db,
                      {:table_not_in_profile_allowlist, "audit_trail_decisions"}}

      refute_receive {:gate_called, _tool_call}
      assert_profile_violation_row(:query_db, "audit_trail_decisions")
    end

    test "profile_violation ignores matching gemini_done without feedback", %{
      pubsub: broker,
      sandbox_owner: sandbox_owner
    } do
      profile = profile!(:logs, %{"tool_scope" => tool_scope(kubectl: %{"verbs" => ["logs"]})})
      state_pid = start_alert_state(broker, tool_call_budget: 3)
      stub_single_function_call_then_done("kubectl", %{"args" => ["get", "configmaps"]})

      %{pid: pid} =
        start_investigator(broker, sandbox_owner, profile,
          alert_state_pid: state_pid,
          gate_module: ProbeGate,
          tool_dispatch: fn _call -> {:error, :unexpected_dispatch} end,
          audit_repo: Pageless.Repo
        )

      :ok = Investigator.kick_off(pid)
      assert_receive {:gemini_started, _initial_prompt}
      assert_receive {:profile_violation, _agent_id, :kubectl, {:verb_not_in_profile, "get"}}
      assert_receive {:gemini_done_sent, _ref}
      assert {:ok, state} = GenServer.call(pid, :get_state)

      refute state.prompt =~ "Tool kubectl result"
      refute state.prompt =~ "profile_violation"
      refute state.prompt =~ "verb_not_in_profile"
      refute_receive {:gemini_started, _prompt}

      refute_receive {:investigation_findings, "alert-investigator", :logs,
                      %{status: :no_findings}}
    end

    test "tool dispatch claims budget before gate request", %{
      pubsub: broker,
      sandbox_owner: sandbox_owner
    } do
      profile = profile!(:metrics, %{"tool_scope" => tool_scope(prometheus_query: true)})
      state_pid = start_alert_state(broker, tool_call_budget: 3)
      stub_single_function_call("prometheus_query", %{"promql" => "up"})

      %{pid: pid} =
        start_investigator(broker, sandbox_owner, profile,
          alert_state_pid: state_pid,
          gate_module: BudgetRecordingGate,
          gate_repo: {self(), state_pid},
          tool_dispatch: fn _call -> {:ok, :unused} end,
          audit_repo: Pageless.Repo
        )

      :ok = Investigator.kick_off(pid)

      assert_receive {:gate_observed_budget, 1, tool_call}
      assert tool_call.tool == :prometheus_query

      assert_receive {:tool_call, _agent_id, "alert-investigator", :prometheus_query, _args,
                      _result, :read}
    end

    test "missing alert_state_pid fails closed before gate request", %{
      pubsub: broker,
      sandbox_owner: sandbox_owner
    } do
      profile = profile!(:metrics, %{"tool_scope" => tool_scope(prometheus_query: true)})
      stub_single_function_call("prometheus_query", %{"promql" => "up"})

      expect(Pageless.AuditTrailMock, :record_decision, fn attrs ->
        assert attrs.tool == "prometheus_query"
        assert attrs.decision == "budget_exhausted"
        assert attrs.result_summary == ":budget_exhausted"
        {:ok, audit_decision(attrs)}
      end)

      %{pid: pid, agent_id: agent_id} =
        start_investigator(broker, sandbox_owner, profile,
          gate_module: ProbeGate,
          gate_repo: Pageless.AuditTrailMock,
          tool_dispatch: fn _call -> {:error, :unexpected_dispatch} end,
          audit_repo: Pageless.Repo
        )

      monitor_ref = Process.monitor(pid)

      capture_log(fn ->
        :ok = Investigator.kick_off(pid)
        assert_receive {:budget_exhausted, ^agent_id, :prometheus_query}
      end)

      refute_receive {:gate_called, _tool_call}
      assert_receive {:DOWN, ^monitor_ref, :process, ^pid, reason}
      assert clean_exit?(reason)
    end

    test "budget_exhausted terminates investigator through injected audit repo", %{
      pubsub: broker,
      sandbox_owner: sandbox_owner
    } do
      profile = profile!(:metrics, %{"tool_scope" => tool_scope(prometheus_query: true)})
      state_pid = start_alert_state(broker, tool_call_budget: 1)
      assert :ok = State.inc_tool_call(state_pid)
      stub_single_function_call("prometheus_query", %{"promql" => "up"})

      expect(Pageless.AuditTrailMock, :record_decision, fn attrs ->
        assert attrs.tool == "prometheus_query"
        assert attrs.decision == "budget_exhausted"
        assert attrs.result_summary == ":budget_exhausted"
        assert Ecto.UUID.cast(attrs.agent_id) == {:ok, attrs.agent_id}
        {:ok, audit_decision(attrs)}
      end)

      %{pid: pid, agent_id: agent_id} =
        start_investigator(broker, sandbox_owner, profile,
          alert_state_pid: state_pid,
          gate_module: ProbeGate,
          gate_repo: Pageless.AuditTrailMock,
          tool_dispatch: fn _call -> {:error, :unexpected_dispatch} end,
          audit_repo: Pageless.Repo
        )

      monitor_ref = Process.monitor(pid)
      :ok = Investigator.kick_off(pid)

      assert_receive {:budget_exhausted, ^agent_id, :prometheus_query}
      refute_receive {:gate_called, _tool_call}
      assert_receive {:DOWN, ^monitor_ref, :process, ^pid, reason}
      assert clean_exit?(reason)
    end

    test "profile_violation does not consume tool-call budget", %{
      pubsub: broker,
      sandbox_owner: sandbox_owner
    } do
      profile = profile!(:logs, %{"tool_scope" => tool_scope(kubectl: %{"verbs" => ["logs"]})})
      state_pid = start_alert_state(broker, tool_call_budget: 3)
      stub_single_function_call("kubectl", %{"args" => ["get", "configmaps"]})

      %{pid: pid} =
        start_investigator(broker, sandbox_owner, profile,
          alert_state_pid: state_pid,
          gate_module: ProbeGate,
          tool_dispatch: fn _call -> {:error, :unexpected_dispatch} end,
          audit_repo: Pageless.Repo
        )

      :ok = Investigator.kick_off(pid)
      assert_receive {:profile_violation, _agent_id, :kubectl, {:verb_not_in_profile, "get"}}
      assert {:ok, %{tool_call_count: 0}} = State.get(state_pid)
    end

    test ":all kubectl verbs scope permits any verb pre-gate", %{
      pubsub: broker,
      sandbox_owner: sandbox_owner
    } do
      profile = profile!(:generic, %{"tool_scope" => tool_scope(kubectl: %{"verbs" => :all})})
      state_pid = start_alert_state(broker, tool_call_budget: 3)

      stub_single_function_call("kubectl", %{"args" => ["describe", "configmaps", "payments-api"]})

      %{pid: pid} =
        start_investigator(broker, sandbox_owner, profile,
          alert_state_pid: state_pid,
          gate_module: ProbeGate,
          gate_repo: self(),
          tool_dispatch: fn _call -> {:ok, :unused} end,
          audit_repo: Pageless.Repo
        )

      :ok = Investigator.kick_off(pid)

      assert_receive {:gate_called, tool_call}
      assert tool_call.tool == :kubectl
      assert {:ok, %{tool_call_count: 1}} = State.get(state_pid)
      stop_investigator(pid)
    end

    test "hallucinated function name rejected through injected audit repo", %{
      pubsub: broker,
      sandbox_owner: sandbox_owner
    } do
      profile = profile!(:metrics, %{"tool_scope" => tool_scope(prometheus_query: true)})
      state_pid = start_alert_state(broker, tool_call_budget: 3)
      stub_single_function_call("steal_secrets", %{"kind" => "prompt"})

      expect(Pageless.AuditTrailMock, :record_decision, fn attrs ->
        assert attrs.tool == "unknown"
        assert attrs.decision == "profile_violation"

        assert attrs.args == %{
                 "function_name" => "steal_secrets",
                 "raw_args" => %{"kind" => "prompt"}
               }

        assert attrs.result_summary =~ "steal_secrets"
        assert Ecto.UUID.cast(attrs.agent_id) == {:ok, attrs.agent_id}
        {:ok, audit_decision(attrs)}
      end)

      %{pid: pid, agent_id: agent_id} =
        start_investigator(broker, sandbox_owner, profile,
          alert_state_pid: state_pid,
          gate_module: ProbeGate,
          gate_repo: Pageless.AuditTrailMock,
          tool_dispatch: fn _call -> {:error, :unexpected_dispatch} end,
          audit_repo: Pageless.Repo
        )

      :ok = Investigator.kick_off(pid)

      assert_receive {:profile_violation, ^agent_id, :unknown,
                      {:out_of_scope_tool, "steal_secrets"}}

      refute_receive {:gate_called, _tool_call}
      assert {:ok, %{tool_call_count: 0}} = State.get(state_pid)

      refute latest_audit_decision("profile_violation")
    end

    test "query_db table scope matches case-insensitively", %{
      pubsub: broker,
      sandbox_owner: sandbox_owner
    } do
      profile =
        profile!(:deploys, %{"tool_scope" => tool_scope(query_db: %{"tables" => ["deploys"]})})

      state_pid = start_alert_state(broker, tool_call_budget: 3)
      stub_single_function_call("query_db", %{"sql" => "SELECT * FROM Deploys"})

      %{pid: pid} =
        start_investigator(broker, sandbox_owner, profile,
          alert_state_pid: state_pid,
          gate_module: ProbeGate,
          gate_repo: self(),
          tool_dispatch: fn _call -> {:ok, :unused} end,
          audit_repo: Pageless.Repo
        )

      :ok = Investigator.kick_off(pid)

      assert_receive {:gate_called, tool_call}
      assert tool_call.tool == :query_db
      assert {:ok, %{tool_call_count: 1}} = State.get(state_pid)
      stop_investigator(pid)
    end

    test "profile scope helper pure function unit coverage" do
      all_scope =
        tool_scope(
          kubectl: %{"verbs" => :all},
          prometheus_query: true,
          query_db: %{"tables" => :all},
          mcp_runbook: true
        )

      narrow_scope =
        tool_scope(kubectl: %{"verbs" => ["logs"]}, query_db: %{"tables" => ["deploys"]})

      all_profile = profile!(:generic, %{"tool_scope" => all_scope})
      narrow_profile = profile!(:logs, %{"tool_scope" => narrow_scope})
      disabled_profile = profile!(:metrics, %{"tool_scope" => tool_scope()})

      assert :ok =
               ProfileScope.allowed?(all_profile, :kubectl, [
                 "delete",
                 "pod",
                 "x"
               ])

      assert :ok =
               ProfileScope.allowed?(
                 all_profile,
                 :query_db,
                 "SELECT * FROM any_table"
               )

      assert :ok = ProfileScope.allowed?(all_profile, :prometheus_query, "up")

      assert :ok =
               ProfileScope.allowed?(all_profile, :mcp_runbook, %{
                 "tool_name" => "read"
               })

      assert :ok =
               ProfileScope.allowed?(narrow_profile, :kubectl, [
                 "logs",
                 "pod/payments"
               ])

      assert :ok =
               ProfileScope.allowed?(
                 narrow_profile,
                 :query_db,
                 "SELECT * FROM Deploys"
               )

      assert {:error, {:out_of_scope_tool, :kubectl}} =
               ProfileScope.allowed?(disabled_profile, :kubectl, [
                 "get",
                 "pods"
               ])

      assert {:error, {:out_of_scope_tool, :prometheus_query}} =
               ProfileScope.allowed?(disabled_profile, :prometheus_query, "up")

      assert {:error, {:out_of_scope_tool, :query_db}} =
               ProfileScope.allowed?(
                 disabled_profile,
                 :query_db,
                 "SELECT * FROM deploys"
               )

      assert {:error, {:out_of_scope_tool, :mcp_runbook}} =
               ProfileScope.allowed?(disabled_profile, :mcp_runbook, %{})

      assert {:error, {:verb_not_in_profile, "get"}} =
               ProfileScope.allowed?(narrow_profile, :kubectl, ["get", "pods"])

      assert {:error, {:table_not_in_profile_allowlist, "audit_trail_decisions"}} =
               ProfileScope.allowed?(
                 narrow_profile,
                 :query_db,
                 "SELECT * FROM audit_trail_decisions"
               )

      assert {:error, {:out_of_scope_tool, :unknown_tool}} =
               ProfileScope.allowed?(all_profile, :unknown_tool, %{})
    end

    test "malformed kubectl function-call args reject through profile_violation path", %{
      pubsub: broker,
      sandbox_owner: sandbox_owner
    } do
      profile = profile!(:logs, %{"tool_scope" => tool_scope(kubectl: %{"verbs" => ["logs"]})})
      state_pid = start_alert_state(broker, tool_call_budget: 3)
      stub_single_function_call("kubectl", %{"args" => ["logs", :not_binary]})

      %{pid: pid} =
        start_investigator(broker, sandbox_owner, profile,
          alert_state_pid: state_pid,
          gate_module: ProbeGate,
          tool_dispatch: fn _call -> {:error, :unexpected_dispatch} end,
          audit_repo: Pageless.Repo
        )

      :ok = Investigator.kick_off(pid)

      assert_receive {:profile_violation, _agent_id, :kubectl, {:malformed_tool_args, :kubectl}}

      refute_receive {:gate_called, _tool_call}
      assert row = latest_audit_decision("profile_violation")
      assert row.tool == "kubectl"
      assert row.classification == "write_prod_high"
      assert %{"raw_args" => %{"args" => ["logs", serialized_arg]}} = row.args
      assert serialized_arg in [":not_binary", "not_binary"]
      assert row.result_summary =~ "malformed_tool_args"
      assert {:ok, %{tool_call_count: 0}} = State.get(state_pid)
    end

    test "malformed query_db function-call args reject through profile_violation path", %{
      pubsub: broker,
      sandbox_owner: sandbox_owner
    } do
      profile =
        profile!(:deploys, %{"tool_scope" => tool_scope(query_db: %{"tables" => ["deploys"]})})

      state_pid = start_alert_state(broker, tool_call_budget: 3)
      stub_single_function_call("query_db", %{"sql" => ["SELECT * FROM deploys"]})

      %{pid: pid} =
        start_investigator(broker, sandbox_owner, profile,
          alert_state_pid: state_pid,
          gate_module: ProbeGate,
          tool_dispatch: fn _call -> {:error, :unexpected_dispatch} end,
          audit_repo: Pageless.Repo
        )

      :ok = Investigator.kick_off(pid)

      assert_receive {:profile_violation, _agent_id, :query_db, {:malformed_tool_args, :query_db}}

      refute_receive {:gate_called, _tool_call}
      assert row = latest_audit_decision("profile_violation")
      assert row.tool == "query_db"
      assert row.classification == "read"
      assert row.args == %{"raw_args" => %{"sql" => ["SELECT * FROM deploys"]}}
      assert row.result_summary =~ "malformed_tool_args"
      assert {:ok, %{tool_call_count: 0}} = State.get(state_pid)
    end

    test "unparseable SQL rejects as table_not_in_profile_allowlist" do
      profile =
        profile!(:deploys, %{"tool_scope" => tool_scope(query_db: %{"tables" => ["deploys"]})})

      assert {:error, {:table_not_in_profile_allowlist, "<unparseable>"}} =
               ProfileScope.allowed?(profile, :query_db, "not valid sql")
    end

    test "best_effort_classify returns forensic classification strings", %{
      pubsub: broker,
      sandbox_owner: sandbox_owner
    } do
      profile = profile!(:logs, %{"tool_scope" => tool_scope(kubectl: %{"verbs" => ["logs"]})})
      state_pid = start_alert_state(broker, tool_call_budget: 3)
      stub_single_function_call("kubectl", %{"args" => ["delete", "pods", "payments-api"]})

      %{pid: pid} =
        start_investigator(broker, sandbox_owner, profile,
          alert_state_pid: state_pid,
          gate_module: ProbeGate,
          tool_dispatch: fn _call -> {:error, :unexpected_dispatch} end,
          audit_repo: Pageless.Repo
        )

      :ok = Investigator.kick_off(pid)
      assert_receive {:profile_violation, _agent_id, :kubectl, {:verb_not_in_profile, "delete"}}
      assert row = latest_audit_decision("profile_violation")
      assert row.classification == "write_prod_high"
      stop_investigator(pid)
    end

    test "encode_args uses audit-trail tool shapes", %{
      pubsub: broker,
      sandbox_owner: sandbox_owner
    } do
      cases = [
        {:kubectl, "kubectl", %{"args" => ["get", "pods"]}, %{"argv" => ["get", "pods"]}},
        {:prometheus_query, "prometheus_query", %{"promql" => "up"}, %{"promql" => "up"}},
        {:query_db, "query_db", %{"sql" => "SELECT * FROM deploys"},
         %{"sql" => "SELECT * FROM deploys"}},
        {:mcp_runbook, "mcp_runbook",
         %{"tool_name" => "read_runbook", "params" => %{"path" => "x"}},
         %{"tool_name" => "read_runbook", "params" => %{"path" => "x"}}}
      ]

      for {tool, function_name, call_args, expected_args} <- cases do
        alert_id = "alert-encode-args-#{System.unique_integer([:positive])}"
        :ok = PubSubHelpers.subscribe(broker, "alert:#{alert_id}")
        profile = profile!(:disabled, %{"tool_scope" => tool_scope()})
        state_pid = start_alert_state(broker, tool_call_budget: 3)
        stub_single_function_call(function_name, call_args)

        %{pid: pid} =
          start_investigator(broker, sandbox_owner, profile,
            alert_id: alert_id,
            alert_state_pid: state_pid,
            gate_module: ProbeGate,
            tool_dispatch: fn _call -> {:error, :unexpected_dispatch} end
          )

        :ok = Investigator.kick_off(pid)
        assert_receive {:profile_violation, _agent_id, ^tool, {:out_of_scope_tool, ^tool}}
        assert row = latest_audit_decision("profile_violation", alert_id)
        assert row.tool == Atom.to_string(tool)
        assert row.args == expected_args
      end
    end
  end

  describe "reasoning loop" do
    @tag :acceptance
    test "two-turn Gemini stream calls a scoped tool through the gate and returns findings", %{
      pubsub: broker,
      sandbox_owner: sandbox_owner
    } do
      profile =
        profile!(:metrics, %{
          "tool_scope" => tool_scope(prometheus_query: true),
          "step_limit" => 3
        })

      state_pid = start_alert_state(broker, tool_call_budget: 3)
      stub_two_turn_metrics_stream()

      %{pid: pid, agent_id: agent_id} =
        start_investigator(broker, sandbox_owner, profile,
          alert_state_pid: state_pid,
          gate_module: ReadGate,
          tool_dispatch: fn _call -> {:ok, :unused_by_stub_gate} end
        )

      :ok = Investigator.kick_off(pid)
      monitor_ref = Process.monitor(pid)

      assert_receive {:reasoning_line, ^agent_id, "alert-investigator", line}
      assert line =~ "Checking Prometheus"

      assert_receive {:tool_call, ^agent_id, "alert-investigator", :prometheus_query,
                      %{"promql" => promql}, result, :read}

      assert promql =~ "payments-api"
      assert result.output == "gate-result-for-prometheus_query"

      assert_receive {:investigation_complete, "alert-investigator", :metrics, findings}
      assert findings.hypothesis =~ "payments-api errors spiked"
      assert findings.confidence > 0.8

      assert_receive {:investigation_findings, "alert-investigator", :metrics, parent_findings}
      assert parent_findings.hypothesis == findings.hypothesis

      assert_receive {:DOWN, ^monitor_ref, :process, ^pid, reason}
      assert clean_exit?(reason)

      rows = AgentState.history(Pageless.Repo, agent_id)
      assert Enum.any?(rows, &(&1.event_type == :reasoning_line))
      assert Enum.any?(rows, &(&1.event_type == :tool_call))
      assert Enum.any?(rows, &(&1.event_type == :findings))
      assert List.last(rows).event_type == :final_state
    end

    test "step limit returns a no_findings result to the parent", %{
      pubsub: broker,
      sandbox_owner: sandbox_owner
    } do
      profile = profile!(:logs, %{"step_limit" => 1})
      stub_no_findings_stream()

      %{pid: pid} =
        start_investigator(broker, sandbox_owner, profile,
          gate_module: ForbiddenGate,
          tool_dispatch: fn _call -> {:error, :unexpected_dispatch} end
        )

      :ok = Investigator.kick_off(pid)
      monitor_ref = Process.monitor(pid)

      assert_receive {:investigation_findings, "alert-investigator", :logs,
                      %{status: :no_findings, reason: :step_limit}}

      assert_receive {:DOWN, ^monitor_ref, :process, ^pid, reason}
      assert clean_exit?(reason)
    end

    test "gemini_error emits investigation_failed and reports failure findings to parent", %{
      pubsub: broker,
      sandbox_owner: sandbox_owner
    } do
      profile = profile!(:metrics)
      stub_gemini_error_stream(:rate_limited)

      %{pid: pid} =
        start_investigator(broker, sandbox_owner, profile,
          gate_module: ForbiddenGate,
          tool_dispatch: fn _call -> {:error, :unexpected_dispatch} end
        )

      :ok = Investigator.kick_off(pid)
      monitor_ref = Process.monitor(pid)

      assert_receive {:investigation_failed, "alert-investigator", :metrics, :gemini_unavailable}

      assert_receive {:investigation_findings, "alert-investigator", :metrics,
                      %{status: :failed, reason: :rate_limited}}

      assert_receive {:DOWN, ^monitor_ref, :process, ^pid, reason}
      assert clean_exit?(reason)
    end
  end

  defp stub_two_turn_metrics_stream do
    stub(Pageless.Svc.GeminiClient.Mock, :start_stream, fn opts ->
      caller = Keyword.get(opts, :caller, self())
      ref = make_ref()
      prompt = Keyword.fetch!(opts, :prompt)

      if prompt_contains?(prompt, "gate-result-for-prometheus_query") do
        findings = %{
          hypothesis: "payments-api errors spiked after deploy v2.4.1",
          confidence: 0.91,
          evidence: ["Prometheus shows 5xx spike for payments-api"]
        }

        send(
          caller,
          {:gemini_chunk, ref,
           struct(Chunk, type: :text, text: Jason.encode!(findings), ref: ref)}
        )

        send(caller, {:gemini_done, ref, %{finish_reason: :stop}})
      else
        [declaration] = Keyword.fetch!(opts, :tools)
        assert declaration["name"] == "prometheus_query"

        call =
          struct(FunctionCall,
            name: "prometheus_query",
            args: %{
              "promql" =>
                "rate(http_requests_total{service=\"payments-api\",status=~\"5..\"}[1m])"
            },
            id: "call-prom-1"
          )

        send(
          caller,
          {:gemini_chunk, ref,
           struct(Chunk, type: :text, text: "Checking Prometheus for payments-api 5xx", ref: ref)}
        )

        send(
          caller,
          {:gemini_chunk, ref, struct(Chunk, type: :function_call, function_call: call, ref: ref)}
        )

        send(caller, {:gemini_done, ref, %{finish_reason: :tool_calls}})
      end

      {:ok, ref}
    end)
  end

  defp stub_no_findings_stream do
    stub(Pageless.Svc.GeminiClient.Mock, :start_stream, fn opts ->
      caller = Keyword.get(opts, :caller, self())
      ref = make_ref()

      send(
        caller,
        {:gemini_chunk, ref,
         struct(Chunk, type: :text, text: "No conclusive evidence yet", ref: ref)}
      )

      send(caller, {:gemini_done, ref, %{finish_reason: :stop}})

      {:ok, ref}
    end)
  end

  defp stub_gemini_error_stream(reason) do
    stub(Pageless.Svc.GeminiClient.Mock, :start_stream, fn opts ->
      caller = Keyword.get(opts, :caller, self())
      ref = make_ref()

      send(caller, {:gemini_error, ref, reason})
      {:ok, ref}
    end)
  end

  defp stub_single_function_call(name, args) do
    stub_function_call(name, args, done_after_call?: false)
  end

  defp stub_single_function_call_then_done(name, args) do
    stub_function_call(name, args, done_after_call?: true)
  end

  defp stub_function_call(name, args, stub_opts) do
    test_pid = self()
    done_after_call? = Keyword.fetch!(stub_opts, :done_after_call?)
    call_counter = :counters.new(1, [])

    stub(Pageless.Svc.GeminiClient.Mock, :start_stream, fn stream_opts ->
      caller = Keyword.get(stream_opts, :caller, self())
      ref = make_ref()
      send(test_pid, {:gemini_started, Keyword.fetch!(stream_opts, :prompt)})

      :counters.add(call_counter, 1, 1)

      case :counters.get(call_counter, 1) do
        1 ->
          call = struct(FunctionCall, name: name, args: args, id: "call-#{name}")

          send(
            caller,
            {:gemini_chunk, ref,
             struct(Chunk, type: :function_call, function_call: call, ref: ref)}
          )

          if done_after_call? do
            send(caller, {:gemini_done, ref, %{finish_reason: :tool_calls}})
            send(test_pid, {:gemini_done_sent, ref})
          end

        _other ->
          send(caller, {:gemini_done, ref, %{finish_reason: :stop}})
      end

      {:ok, ref}
    end)
  end

  defp start_investigator(broker, sandbox_owner, profile, opts) do
    alert_id = Keyword.get(opts, :alert_id, "alert-investigator")

    base_opts =
      [
        alert_id: alert_id,
        envelope: envelope(alert_id: alert_id),
        profile: profile,
        pubsub: broker,
        gemini_client: Pageless.Svc.GeminiClient.Mock,
        sandbox_owner: sandbox_owner,
        audit_repo: Keyword.get(opts, :audit_repo, Pageless.Repo),
        parent: self(),
        rules: rules(),
        gate_module: Keyword.fetch!(opts, :gate_module),
        gate_repo: Keyword.get(opts, :gate_repo, Pageless.AuditTrail),
        tool_dispatch: Keyword.fetch!(opts, :tool_dispatch)
      ]

    investigator_opts =
      case Keyword.fetch(opts, :alert_state_pid) do
        {:ok, alert_state_pid} -> Keyword.put(base_opts, :alert_state_pid, alert_state_pid)
        :error -> base_opts
      end

    assert {:ok, pid} = Investigator.start_link(investigator_opts)

    assert {:ok, state} = GenServer.call(pid, :get_state)

    on_exit(fn ->
      if Process.alive?(pid) do
        try do
          GenServer.stop(pid, :normal, :infinity)
        catch
          :exit, _reason -> :ok
        end
      end
    end)

    %{pid: pid, agent_id: state.agent_id}
  end

  defp start_alert_state(broker, opts) do
    defaults = [
      envelope: envelope(alert_id: "alert-state-#{System.unique_integer([:positive])}"),
      pubsub: broker
    ]

    start_supervised!({State, Keyword.merge(defaults, opts)})
  end

  defp assert_profile_violation_row(tool, summary_fragment) do
    assert row = latest_audit_decision("profile_violation")
    assert row.tool == Atom.to_string(tool)
    assert row.decision == "profile_violation"
    assert row.result_status == "error"
    assert row.result_summary =~ summary_fragment
  end

  defp audit_decision(attrs) do
    struct(Pageless.AuditTrail.Decision, Map.put(attrs, :id, Ecto.UUID.generate()))
  end

  defp latest_audit_decision(decision, alert_id \\ "alert-investigator") do
    Pageless.AuditTrail.Decision
    |> where([row], row.alert_id == ^alert_id and row.decision == ^decision)
    |> order_by([row], desc: row.inserted_at)
    |> limit(1)
    |> Pageless.Repo.one()
  end

  defp profile!(name, overrides \\ %{}) do
    assert {:ok, profile} = Profile.from_yaml(name, Map.merge(profile_yaml(name), overrides))
    profile
  end

  defp profile_yaml(name) do
    %{
      "label" => "Investigator: #{name}",
      "prompt_template_path" => prompt_path(name),
      "tool_scope" => tool_scope(kubectl: %{"verbs" => ["logs"]}),
      "output_schema" => finding_schema(),
      "step_limit" => 3,
      "reasoning_visibility" => "stream"
    }
  end

  defp prompt_path(name) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "pageless-investigator-test-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    path = Path.join(dir, "#{name}.eex")
    File.write!(path, "Investigate <%= @service %> as #{name}")
    path
  end

  defp tool_scope(overrides \\ []) do
    defaults = %{
      "kubectl" => nil,
      "prometheus_query" => false,
      "query_db" => nil,
      "mcp_runbook" => false
    }

    Enum.reduce(overrides, defaults, fn {key, value}, acc ->
      Map.put(acc, Atom.to_string(key), value)
    end)
  end

  defp finding_schema do
    %{
      "type" => "object",
      "required" => ["hypothesis", "confidence", "evidence"],
      "properties" => %{
        "hypothesis" => %{"type" => "string"},
        "confidence" => %{"type" => "number", "minimum" => 0, "maximum" => 1},
        "evidence" => %{"type" => "array", "items" => %{"type" => "string"}}
      }
    }
  end

  defp tool_modules do
    %{
      kubectl: Pageless.Tools.Kubectl,
      prometheus_query: Pageless.Tools.PrometheusQuery,
      query_db: Pageless.Tools.QueryDB,
      mcp_runbook: Pageless.Tools.MCPRunbook
    }
  end

  defp prompt_contains?(prompt, text) when is_binary(prompt), do: String.contains?(prompt, text)
  defp prompt_contains?(prompt, text), do: prompt |> inspect() |> String.contains?(text)

  defp clean_exit?(reason) when reason in [:normal, :noproc, :shutdown], do: true
  defp clean_exit?({:shutdown, _details}), do: true
  defp clean_exit?(_reason), do: false

  defp stop_investigator(pid) do
    if Process.alive?(pid) do
      try do
        GenServer.stop(pid, :normal, :infinity)
      catch
        :exit, _reason -> :ok
      end
    end
  end

  defp rules do
    %Rules{
      capability_classes: %{
        read: %{auto: true, audit: true, gated: false},
        write_dev: %{auto: true, audit: true, gated: false},
        write_prod_low: %{auto: true, audit: true, gated: false},
        write_prod_high: %{auto: false, audit: true, gated: true}
      },
      kubectl_verbs: %{
        read: ["get", "describe", "logs"],
        write_dev: [],
        write_prod_low: [],
        write_prod_high: []
      },
      function_blocklist: ["pg_terminate_backend"]
    }
  end

  defp envelope(overrides) do
    defaults = %{
      alert_id: "alert-investigator",
      source: :pagerduty,
      source_ref: "pd-dedup-investigator",
      fingerprint: "fingerprint-investigator",
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
    }

    struct!(AlertEnvelope, Map.merge(defaults, Map.new(overrides)))
  end
end
