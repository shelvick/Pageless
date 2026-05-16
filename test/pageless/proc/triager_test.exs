defmodule Pageless.Proc.TriagerTest.InvestigatorProbe do
  @moduledoc "Investigator test double that keeps its start opts queryable by PID."

  use GenServer

  @doc "Starts a probe investigator process with the provided opts as state."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Returns the opts used to start the probe investigator."
  @spec opts(pid()) :: keyword()
  def opts(pid), do: GenServer.call(pid, :opts)

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def handle_call(:opts, _from, opts), do: {:reply, opts, opts}
end

defmodule Pageless.Proc.TriagerTest.PartialFailureInvestigator do
  @moduledoc "Investigator test double that fails only for the metrics profile."

  @doc "Starts a probe investigator unless the requested profile is :metrics."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    case Keyword.fetch!(opts, :profile) do
      :metrics -> {:error, :spawn_blocked}
      _profile -> Pageless.Proc.TriagerTest.InvestigatorProbe.start_link(opts)
    end
  end
end

defmodule Pageless.Proc.TriagerTest.ForbiddenInvestigator do
  @moduledoc "Investigator test double that fails if dispatch is attempted."

  @doc "Raises because failure paths must not dispatch investigators."
  @spec start_link(keyword()) :: no_return()
  def start_link(_opts), do: raise("investigator dispatch must not be attempted")
end

defmodule Pageless.Proc.TriagerTest do
  @moduledoc "Tests the Triager agent lifecycle, classification, and dispatch side effects."

  use Pageless.DataCase, async: true

  import Hammox

  alias Pageless.AlertEnvelope
  alias Pageless.Config.Rules
  alias Pageless.Data.AgentState
  alias Pageless.Proc.Triager
  alias Pageless.Proc.TriagerTest.InvestigatorProbe
  alias Pageless.PubSubHelpers
  alias Pageless.Sup.Alert
  alias Pageless.SupHelpers
  alias Pageless.Svc.GeminiClient.FunctionCall
  alias Pageless.Svc.GeminiClient.Response

  setup :verify_on_exit!

  setup do
    broker = PubSubHelpers.start_isolated_pubsub()
    :ok = PubSubHelpers.subscribe(broker, "alert:alert-triager")
    %{pubsub: broker}
  end

  describe "setup" do
    test "spawns with a state handshake, audit row, and PubSub event", %{
      pubsub: broker,
      sandbox_owner: sandbox_owner
    } do
      %{pid: pid, agent_id: agent_id} = start_triager(broker, sandbox_owner)

      assert Process.alive?(pid)
      assert agent_id =~ ~r/^triager-\d+$/
      assert_receive {:triager_spawned, ^agent_id, "alert-triager"}

      [spawned] = AgentState.history(Pageless.Repo, agent_id, event_type: :spawned)
      assert spawned.agent_type == :triager
      assert spawned.payload["envelope_summary"]["alert_id"] == "alert-triager"
      assert spawned.payload["envelope_summary"]["source"] == "pagerduty"
      assert spawned.payload["envelope_summary"]["service"] == "payments-api"
    end
  end

  describe "successful dispatch" do
    test "calls Gemini with the real classify function shape and dispatches S1 fan-out", %{
      pubsub: broker,
      sandbox_owner: sandbox_owner
    } do
      expect_classification_from_gemini(%{
        "class" => "service_down_with_recent_deploy",
        "confidence" => 0.91,
        "rationale" => "Deploy at 03:43:58; errors at 03:44:12."
      })

      %{pid: pid, agent_id: agent_id} = start_triager(broker, sandbox_owner)
      :ok = Triager.kick_off(pid)
      monitor_ref = Process.monitor(pid)

      assert_receive {:triager_reasoning, ^agent_id, "alert-triager",
                      "Deploy at 03:43:58; errors at 03:44:12."}

      assert_receive {:triager_classified, ^agent_id, "alert-triager", classified}
      assert classified.class == :service_down_with_recent_deploy
      assert classified.confidence == 0.91
      assert classified.topology == :fan_out
      assert classified.profiles == [:logs, :metrics, :deploys]

      assert_receive {:triager_dispatched, ^agent_id, "alert-triager", dispatched}
      assert length(dispatched) == 3
      assert Enum.map(dispatched, & &1.profile) == [:logs, :metrics, :deploys]
      assert Enum.all?(dispatched, &(&1.chain_position == 0))

      for %{pid: investigator_pid, profile: profile} <- dispatched do
        opts = InvestigatorProbe.opts(investigator_pid)
        assert Keyword.fetch!(opts, :profile) == profile
        assert Keyword.fetch!(opts, :chain_position) == 0
        assert Keyword.fetch!(opts, :topology) == :fan_out
        assert Keyword.fetch!(opts, :parent) == pid
      end

      assert_receive {:triager_complete, "alert-triager", ^agent_id,
                      %{
                        outcome: :dispatched,
                        class: :service_down_with_recent_deploy,
                        dispatched: 3
                      }}

      assert_receive {:DOWN, ^monitor_ref, :process, ^pid, reason}
      assert clean_exit?(reason)

      rows = AgentState.history(Pageless.Repo, agent_id)

      assert Enum.map(rows, & &1.event_type) == [
               :spawned,
               :reasoning_line,
               :findings,
               :tool_call,
               :tool_call,
               :tool_call,
               :final_state
             ]

      findings = Enum.find(rows, &(&1.event_type == :findings))
      assert findings.payload["class"] == "service_down_with_recent_deploy"
      assert findings.payload["topology"] == "fan_out"
      assert findings.payload["profiles"] == ["logs", "metrics", "deploys"]

      tool_calls = Enum.filter(rows, &(&1.event_type == :tool_call))

      assert Enum.map(tool_calls, & &1.payload["args"]["profile"]) == [
               "logs",
               "metrics",
               "deploys"
             ]

      assert Enum.all?(tool_calls, &(&1.payload["classification"] == "read"))
      assert List.last(rows).payload["outcome"] == "dispatched"
      assert List.last(rows).payload["dispatched_count"] == 3
    end

    test "dispatches S2 chain topology with ordered chain positions", %{
      pubsub: broker,
      sandbox_owner: sandbox_owner
    } do
      expect_classification_from_gemini(%{
        "class" => "latency_creep",
        "confidence" => 0.82,
        "rationale" => "Latency is rising across database-backed endpoints."
      })

      %{pid: pid, agent_id: agent_id} = start_triager(broker, sandbox_owner)
      :ok = Triager.kick_off(pid)
      monitor_ref = Process.monitor(pid)

      assert_receive {:triager_classified, ^agent_id, "alert-triager", classified}, 1_000
      assert classified.class == :latency_creep
      assert classified.topology == :chain
      assert classified.profiles == [:metrics, :db_load, :pool_state]

      assert_receive {:triager_dispatched, ^agent_id, "alert-triager", dispatched}, 1_000
      assert Enum.map(dispatched, & &1.profile) == [:metrics, :db_load, :pool_state]
      assert Enum.map(dispatched, & &1.chain_position) == [1, 2, 3]

      for %{pid: investigator_pid, chain_position: chain_position} <- dispatched do
        opts = InvestigatorProbe.opts(investigator_pid)
        assert Keyword.fetch!(opts, :topology) == :chain
        assert Keyword.fetch!(opts, :chain_position) == chain_position
        assert Keyword.fetch!(opts, :parent) == pid
      end

      assert_receive {:DOWN, ^monitor_ref, :process, ^pid, reason}
      assert clean_exit?(reason)
    end

    test "dispatches S3 single topology to one pool-state investigator", %{
      pubsub: broker,
      sandbox_owner: sandbox_owner
    } do
      expect_classification_from_gemini(%{
        "class" => "db_pool_exhaustion",
        "confidence" => 0.88,
        "rationale" => "Database pool saturation is the dominant signal."
      })

      %{pid: pid, agent_id: agent_id} = start_triager(broker, sandbox_owner)
      :ok = Triager.kick_off(pid)
      monitor_ref = Process.monitor(pid)

      assert_receive {:triager_classified, ^agent_id, "alert-triager", classified}
      assert classified.class == :db_pool_exhaustion
      assert classified.topology == :single
      assert classified.profiles == [:pool_state]

      assert_receive {:triager_dispatched, ^agent_id, "alert-triager", [dispatched]}
      assert dispatched.profile == :pool_state
      assert dispatched.chain_position == 0

      opts = InvestigatorProbe.opts(dispatched.pid)
      assert Keyword.fetch!(opts, :profile) == :pool_state
      assert Keyword.fetch!(opts, :chain_position) == 0
      assert Keyword.fetch!(opts, :topology) == :single

      assert_receive {:triager_complete, "alert-triager", ^agent_id,
                      %{outcome: :dispatched, class: :db_pool_exhaustion, dispatched: 1}}

      assert_receive {:DOWN, ^monitor_ref, :process, ^pid, reason}
      assert clean_exit?(reason)
    end
  end

  describe "fallbacks and failure paths" do
    test "routes an unknown Gemini class through the unknown fallback", %{
      pubsub: broker,
      sandbox_owner: sandbox_owner
    } do
      expect_classification_from_gemini(%{
        "class" => "totally_unknown_alert_class_string",
        "confidence" => 0.2,
        "rationale" => "The class is not in the routing table."
      })

      %{pid: pid, agent_id: agent_id} = start_triager(broker, sandbox_owner)
      :ok = Triager.kick_off(pid)
      monitor_ref = Process.monitor(pid)

      assert_receive {:triager_classified, ^agent_id, "alert-triager", classified}
      assert classified.class == :unknown
      assert classified.topology == :single
      assert classified.profiles == [:generic]

      assert_receive {:triager_dispatched, ^agent_id, "alert-triager", [dispatched]}
      assert dispatched.profile == :generic
      assert dispatched.chain_position == 0

      assert_receive {:DOWN, ^monitor_ref, :process, ^pid, reason}
      assert clean_exit?(reason)
    end

    test "falls back to unknown when Gemini emits no function call", %{
      pubsub: broker,
      sandbox_owner: sandbox_owner
    } do
      expect(Pageless.Svc.GeminiClient.Mock, :generate, fn _opts ->
        {:ok, struct(Response, text: "I don't know", function_calls: [])}
      end)

      %{pid: pid, agent_id: agent_id} = start_triager(broker, sandbox_owner)
      :ok = Triager.kick_off(pid)
      monitor_ref = Process.monitor(pid)

      assert_receive {:triager_reasoning, ^agent_id, "alert-triager", rationale}
      assert rationale =~ "fallback"
      assert_receive {:triager_classified, ^agent_id, "alert-triager", %{class: :unknown}}
      assert_receive {:triager_dispatched, ^agent_id, "alert-triager", [dispatched]}
      assert dispatched.profile == :generic

      rows = AgentState.history(Pageless.Repo, agent_id)
      reasoning = Enum.find(rows, &(&1.event_type == :reasoning_line))
      assert reasoning.payload["text"] =~ "fallback"

      assert_receive {:DOWN, ^monitor_ref, :process, ^pid, reason}
      assert clean_exit?(reason)
    end

    test "records Gemini failure without dispatching investigators", %{
      pubsub: broker,
      sandbox_owner: sandbox_owner
    } do
      expect(Pageless.Svc.GeminiClient.Mock, :generate, fn _opts -> {:error, :gemini_timeout} end)

      %{pid: pid, agent_id: agent_id} =
        start_triager(broker, sandbox_owner,
          investigator_module: Pageless.Proc.TriagerTest.ForbiddenInvestigator
        )

      :ok = Triager.kick_off(pid)
      monitor_ref = Process.monitor(pid)

      assert_receive {:triager_failed, ^agent_id, "alert-triager", :gemini_timeout}

      assert_receive {:triager_complete, "alert-triager", ^agent_id,
                      %{outcome: :failed, class: nil, dispatched: 0}}

      assert_receive {:DOWN, ^monitor_ref, :process, ^pid, reason}
      assert clean_exit?(reason)

      rows = AgentState.history(Pageless.Repo, agent_id)
      tool_error = Enum.find(rows, &(&1.event_type == :tool_error))
      assert tool_error.payload["tool"] == "gemini.generate"
      assert tool_error.payload["reason"] == "gemini_timeout"
      assert List.last(rows).payload["outcome"] == "failed"
      assert List.last(rows).payload["class"] == nil
      assert List.last(rows).payload["dispatched_count"] == 0
    end

    test "continues dispatching after one profile fails to spawn", %{
      pubsub: broker,
      sandbox_owner: sandbox_owner
    } do
      expect_classification_from_gemini(%{
        "class" => "service_down_with_recent_deploy",
        "confidence" => 0.91,
        "rationale" => "Deploy-correlated service outage."
      })

      %{pid: pid, agent_id: agent_id} =
        start_triager(broker, sandbox_owner,
          investigator_module: Pageless.Proc.TriagerTest.PartialFailureInvestigator
        )

      :ok = Triager.kick_off(pid)
      monitor_ref = Process.monitor(pid)

      assert_receive {:triager_dispatched, ^agent_id, "alert-triager", dispatched}
      assert Enum.map(dispatched, & &1.profile) == [:logs, :deploys]

      assert_receive {:triager_complete, "alert-triager", ^agent_id,
                      %{
                        outcome: :dispatched,
                        class: :service_down_with_recent_deploy,
                        dispatched: 2
                      }}

      assert_receive {:DOWN, ^monitor_ref, :process, ^pid, reason}
      assert clean_exit?(reason)

      rows = AgentState.history(Pageless.Repo, agent_id)
      tool_error = Enum.find(rows, &(&1.event_type == :tool_error))
      assert tool_error.payload["tool"] == "sup_alert.start_agent"
      assert tool_error.payload["args"]["profile"] == "metrics"
      assert tool_error.payload["reason"] == "spawn_blocked"
      assert List.last(rows).payload["outcome"] == "dispatched"
      assert List.last(rows).payload["dispatched_count"] == 2
    end
  end

  defp expect_classification_from_gemini(args) do
    expect(Pageless.Svc.GeminiClient.Mock, :generate, fn opts ->
      assert Keyword.fetch!(opts, :model) == :flash
      assert Keyword.fetch!(opts, :temperature) == 0.0
      assert Keyword.fetch!(opts, :tool_choice) == {:specific, "classify_and_dispatch"}
      assert Keyword.fetch!(opts, :system_instruction) =~ "alert triage classifier"
      assert Keyword.fetch!(opts, :prompt) =~ "alert-triager"
      assert Keyword.fetch!(opts, :prompt) =~ "payments-api"

      [tool] = Keyword.fetch!(opts, :tools)
      [declaration] = Map.fetch!(tool, :function_declarations)
      assert declaration.name == "classify_and_dispatch"
      assert declaration.parameters.required == ["class", "confidence", "rationale"]
      assert "service_down_with_recent_deploy" in declaration.parameters.properties.class.enum
      assert "latency_creep" in declaration.parameters.properties.class.enum
      assert "db_pool_exhaustion" in declaration.parameters.properties.class.enum
      assert "unknown" in declaration.parameters.properties.class.enum

      {:ok,
       struct(Response,
         text: Map.fetch!(args, "rationale"),
         function_calls: [struct(FunctionCall, name: "classify_and_dispatch", args: args)]
       )}
    end)
  end

  defp start_triager(broker, sandbox_owner, opts \\ []) do
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
        rules: routing_rules(),
        investigator_module:
          Keyword.get(opts, :investigator_module, Pageless.Proc.TriagerTest.InvestigatorProbe)
      ]
      |> Keyword.merge(Keyword.drop(opts, [:investigator_module]))

    assert {:ok, pid} = Alert.start_agent(alert, Triager, agent_opts)
    assert {:ok, state} = GenServer.call(pid, :get_state)
    %{pid: pid, agent_id: state.agent_id}
  end

  defp clean_exit?(reason) when reason in [:normal, :noproc, :shutdown], do: true
  defp clean_exit?({:shutdown, _details}), do: true
  defp clean_exit?(_reason), do: false

  defp routing_rules do
    %Rules{
      capability_classes: %{
        read: %{auto: true, audit: true, gated: false},
        write_dev: %{auto: true, audit: true, gated: false},
        write_prod_low: %{auto: false, audit: true, gated: false},
        write_prod_high: %{auto: false, audit: true, gated: true}
      },
      kubectl_verbs: %{read: [], write_dev: [], write_prod_low: [], write_prod_high: []},
      function_blocklist: [],
      alert_class_routing: %{
        "service_down_with_recent_deploy" => %{
          "topology" => "fan_out",
          "profiles" => ["logs", "metrics", "deploys"]
        },
        "latency_creep" => %{
          "topology" => "chain",
          "profiles" => ["metrics", "db_load", "pool_state"]
        },
        "db_pool_exhaustion" => %{
          "topology" => "single",
          "profiles" => ["pool_state"]
        },
        "unknown" => %{"topology" => "single", "profiles" => ["generic"]}
      }
    }
  end

  defp envelope do
    struct!(AlertEnvelope, %{
      alert_id: "alert-triager",
      source: :pagerduty,
      source_ref: "pd-dedup-triager",
      fingerprint: "fingerprint-triager",
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
