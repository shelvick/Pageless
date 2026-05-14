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

defmodule Pageless.Proc.InvestigatorTest do
  @moduledoc "Tests profile-scoped Investigator reasoning and terminal paths."

  use Pageless.DataCase, async: true

  import Hammox

  alias Pageless.AlertEnvelope
  alias Pageless.Config.Rules
  alias Pageless.Data.AgentState
  alias Pageless.Proc.Investigator
  alias Pageless.Proc.Investigator.Profile
  alias Pageless.Proc.InvestigatorTest.{ForbiddenGate, ReadGate}
  alias Pageless.PubSubHelpers
  alias Pageless.Svc.GeminiClient.Chunk
  alias Pageless.Svc.GeminiClient.FunctionCall

  setup :verify_on_exit!

  setup do
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

      stub_two_turn_metrics_stream()

      %{pid: pid, agent_id: agent_id} =
        start_investigator(broker, sandbox_owner, profile,
          gate_module: ReadGate,
          tool_dispatch: fn _call -> {:ok, :unused_by_stub_gate} end
        )

      :ok = Investigator.kick_off(pid)
      monitor_ref = Process.monitor(pid)

      assert_receive {:reasoning_line, ^agent_id, line}
      assert line =~ "Checking Prometheus"

      assert_receive {:tool_call, ^agent_id, :prometheus_query, %{"promql" => promql}, result,
                      :read}

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

  defp start_investigator(broker, sandbox_owner, profile, opts) do
    assert {:ok, pid} =
             Investigator.start_link(
               alert_id: "alert-investigator",
               envelope: envelope(),
               profile: profile,
               pubsub: broker,
               gemini_client: Pageless.Svc.GeminiClient.Mock,
               sandbox_owner: sandbox_owner,
               audit_repo: Pageless.Repo,
               parent: self(),
               rules: rules(),
               gate_module: Keyword.fetch!(opts, :gate_module),
               gate_repo: Pageless.AuditTrail,
               tool_dispatch: Keyword.fetch!(opts, :tool_dispatch)
             )

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

  defp tool_scope(overrides) do
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

  defp envelope do
    struct!(AlertEnvelope, %{
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
    })
  end
end
