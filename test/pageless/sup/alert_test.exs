defmodule Pageless.Sup.AlertTest.StubAgent do
  @moduledoc "Agent test double that keeps running until the test asks it to stop."

  @doc "Starts the stub agent and sends its opts to the configured caller."
  @spec start_link(keyword()) :: {:ok, pid()}
  def start_link(opts) do
    caller = Keyword.fetch!(opts, :caller)

    Task.start_link(fn ->
      send(caller, {:stub_agent_started, self(), opts})

      receive do
        :stop -> :ok
      end
    end)
  end
end

defmodule Pageless.Sup.AlertTest.IgnoreAgent do
  @moduledoc "Agent test double that opts out of startup."

  @doc "Returns :ignore to exercise DynamicSupervisor propagation."
  @spec start_link(keyword()) :: :ignore
  def start_link(_opts), do: :ignore
end

defmodule Pageless.Sup.AlertTest.CrashAgent do
  @moduledoc "Agent test double that crashes during init."

  @doc "Returns an error tuple to exercise agent-supervisor failure propagation."
  @spec start_link(keyword()) :: {:error, :boom}
  def start_link(_opts), do: {:error, :boom}
end

defmodule Pageless.Sup.AlertTest.OtherGemini do
  @moduledoc "Marker module used to assert per-agent dependency overrides win."
end

defmodule Pageless.Sup.AlertTest do
  @moduledoc "Tests per-alert supervisor state and dynamic agent spawning."

  use ExUnit.Case, async: true

  alias Pageless.AlertEnvelope
  alias Pageless.PubSubHelpers
  alias Pageless.Sup.Alert
  alias Pageless.Sup.Alert.State
  alias Pageless.SupHelpers

  setup do
    %{pubsub: PubSubHelpers.start_isolated_pubsub()}
  end

  describe "alert spawn" do
    test "starts State and AgentSup children with per-alert state", %{pubsub: broker} do
      env = envelope(alert_id: "alert-supervisor")
      %{alert: alert, state: state_pid, agent_sup: agent_sup} = start_alert(env, broker)

      children = Supervisor.which_children(alert)

      assert Enum.count(children) == 2
      assert Process.alive?(state_pid)
      assert Process.alive?(agent_sup)
      assert {:ok, state} = State.get(state_pid)
      assert state.envelope == env
      assert state.pubsub == broker
    end

    test "missing envelope opt fails startup", %{pubsub: broker} do
      spec = %{id: :missing_envelope_alert, start: {Alert, :start_link, [[pubsub: broker]]}}
      assert {:error, {{{:badkey, :envelope, _opts}, _stack}, _child}} = start_supervised(spec)
    end
  end

  describe "tool-call budget state" do
    test "State initializes tool_call_count to 0", %{pubsub: broker} do
      state_pid = start_state(broker)

      assert {:ok, state} = State.get(state_pid)
      assert state.tool_call_count == 0
    end

    test "State defaults tool_call_budget to 30", %{pubsub: broker} do
      state_pid = start_state(broker, env_reader: fn "ALERT_TOOL_CALL_BUDGET" -> nil end)

      assert {:ok, state} = State.get(state_pid)
      assert state.tool_call_budget == 30
    end

    test "State :tool_call_budget opt overrides default", %{pubsub: broker} do
      state_pid = start_state(broker, tool_call_budget: 5)

      assert {:ok, state} = State.get(state_pid)
      assert state.tool_call_budget == 5
    end

    test "State falls back to default for invalid budget opt", %{pubsub: broker} do
      for invalid_budget <- [0, -1, "5", nil] do
        state_pid = start_state(broker, tool_call_budget: invalid_budget)

        assert {:ok, state} = State.get(state_pid)
        assert state.tool_call_budget == 30
      end
    end

    test "inc_tool_call increments count and returns :ok", %{pubsub: broker} do
      state_pid = start_state(broker, tool_call_budget: 2)

      assert :ok = State.inc_tool_call(state_pid)
      assert {:ok, state} = State.get(state_pid)
      assert state.tool_call_count == 1
    end

    test "inc_tool_call returns :budget_exhausted at exact budget", %{pubsub: broker} do
      state_pid = start_state(broker, tool_call_budget: 2)

      assert :ok = State.inc_tool_call(state_pid)
      assert :ok = State.inc_tool_call(state_pid)
      assert {:error, :budget_exhausted} = State.inc_tool_call(state_pid)

      assert {:ok, state} = State.get(state_pid)
      assert state.tool_call_count == 2
    end

    test "inc_tool_call idempotent once budget exhausted", %{pubsub: broker} do
      state_pid = start_state(broker, tool_call_budget: 1)

      assert :ok = State.inc_tool_call(state_pid)

      for _ <- 1..3 do
        assert {:error, :budget_exhausted} = State.inc_tool_call(state_pid)
      end

      assert {:ok, state} = State.get(state_pid)
      assert state.tool_call_count == 1
    end

    test "concurrent inc_tool_call serializes to budget cap", %{pubsub: broker} do
      state_pid = start_state(broker, tool_call_budget: 3)

      tasks =
        for _ <- 1..10 do
          Task.async(fn -> State.inc_tool_call(state_pid) end)
        end

      results = Task.await_many(tasks, 5_000)

      assert Enum.count(results, &(&1 == :ok)) == 3
      assert Enum.count(results, &(&1 == {:error, :budget_exhausted})) == 7

      assert {:ok, state} = State.get(state_pid)
      assert state.tool_call_count == 3
    end

    test "State.get reflects accumulated tool_call_count", %{pubsub: broker} do
      state_pid = start_state(broker, tool_call_budget: 10)

      for _ <- 1..5 do
        assert :ok = State.inc_tool_call(state_pid)
      end

      assert {:ok, state} = State.get(state_pid)
      assert state.tool_call_count == 5
    end

    test "State reads tool_call_budget from env_reader", %{pubsub: broker} do
      state_pid = start_state(broker, env_reader: fn "ALERT_TOOL_CALL_BUDGET" -> "7" end)

      assert {:ok, state} = State.get(state_pid)
      assert state.tool_call_budget == 7
    end

    test "State falls back to default on unparseable env value", %{pubsub: broker} do
      state_pid =
        start_state(broker, env_reader: fn "ALERT_TOOL_CALL_BUDGET" -> "not_a_number" end)

      assert {:ok, state} = State.get(state_pid)
      assert state.tool_call_budget == 30
    end

    test "tool_call_budget opt wins over env_reader", %{pubsub: broker} do
      state_pid =
        start_state(broker,
          tool_call_budget: 3,
          env_reader: fn "ALERT_TOOL_CALL_BUDGET" -> "10" end
        )

      assert {:ok, state} = State.get(state_pid)
      assert state.tool_call_budget == 3
    end

    test "State.get does not consume tool-call budget", %{pubsub: broker} do
      state_pid = start_state(broker, tool_call_budget: 5)

      assert {:ok, %{tool_call_count: 0}} = State.get(state_pid)
      assert :ok = State.inc_tool_call(state_pid)
      assert {:ok, %{tool_call_count: 1}} = State.get(state_pid)
      assert :ok = State.inc_tool_call(state_pid)
      assert {:ok, %{tool_call_count: 2}} = State.get(state_pid)
      assert :ok = State.inc_tool_call(state_pid)

      assert {:ok, state} = State.get(state_pid)
      assert state.tool_call_count == 3
    end
  end

  describe "idle shutdown state" do
    test "State initializes idle TTL and last activity", %{pubsub: broker} do
      state_pid = start_state(broker, idle_ttl_ms: 1_000)

      assert {:ok, state} = State.get(state_pid)
      assert state.idle_ttl_ms == 1_000
      assert is_integer(state.last_activity_at)
    end

    test "State reads idle TTL from env_reader", %{pubsub: broker} do
      state_pid =
        start_state(broker,
          env_reader: fn
            "ALERT_IDLE_TTL_MS" -> "700"
            _key -> nil
          end
        )

      assert {:ok, state} = State.get(state_pid)
      assert state.idle_ttl_ms == 700
    end

    test "idle_ttl_ms opt wins over env_reader", %{pubsub: broker} do
      state_pid =
        start_state(broker,
          idle_ttl_ms: 1_000,
          env_reader: fn
            "ALERT_IDLE_TTL_MS" -> "50"
            _key -> nil
          end
        )

      assert {:ok, state} = State.get(state_pid)
      assert state.idle_ttl_ms == 1_000
    end

    test "bump_activity updates last activity", %{pubsub: broker} do
      state_pid = start_state(broker)
      assert {:ok, before_bump} = State.get(state_pid)

      assert :ok = State.bump_activity(state_pid)

      assert {:ok, after_bump} = State.get(state_pid)
      assert after_bump.last_activity_at >= before_bump.last_activity_at
    end

    test "idle TTL stops the parent alert supervisor", %{pubsub: broker} do
      %{alert: alert} = start_alert(envelope(alert_id: "alert-idle-stop"), broker, idle_ttl_ms: 1)
      monitor_ref = Process.monitor(alert)

      assert_receive {:DOWN, ^monitor_ref, :process, ^alert, reason}, 1_000
      assert clean_exit?(reason)
    end
  end

  describe "start_agent/3" do
    test "starts an agent under AgentSup with merged per-alert defaults", %{pubsub: broker} do
      env = envelope(alert_id: "alert-agent-start")

      %{alert: alert, state: state_pid, agent_sup: agent_sup} =
        start_alert(env, broker, parent: self())

      assert {:ok, agent_pid} =
               Alert.start_agent(alert, Pageless.Sup.AlertTest.StubAgent,
                 caller: self(),
                 extra: :value
               )

      assert_receive {:stub_agent_started, ^agent_pid, opts}
      assert Keyword.fetch!(opts, :alert_id) == env.alert_id
      assert Keyword.fetch!(opts, :envelope) == env
      assert Keyword.fetch!(opts, :pubsub) == broker
      assert Keyword.fetch!(opts, :parent) == self()
      assert Keyword.fetch!(opts, :alert_state_pid) == state_pid
      assert Keyword.fetch!(opts, :extra) == :value

      assert Enum.any?(DynamicSupervisor.which_children(agent_sup), fn {_id, pid, _type, _modules} ->
               pid == agent_pid
             end)
    end

    test "two agents start as distinct children under AgentSup", %{pubsub: broker} do
      %{alert: alert, agent_sup: agent_sup} =
        start_alert(envelope(alert_id: "alert-two-agents"), broker)

      assert {:ok, first} =
               Alert.start_agent(alert, Pageless.Sup.AlertTest.StubAgent, caller: self())

      assert {:ok, second} =
               Alert.start_agent(alert, Pageless.Sup.AlertTest.StubAgent, caller: self())

      assert first != second
      assert DynamicSupervisor.count_children(agent_sup).active == 2
    end

    test "propagates :ignore from the agent child spec", %{pubsub: broker} do
      %{alert: alert} = start_alert(envelope(alert_id: "alert-ignore-agent"), broker)

      assert :ignore = Alert.start_agent(alert, Pageless.Sup.AlertTest.IgnoreAgent, [])
    end

    test "per-agent extras win over per-alert defaults", %{pubsub: broker} do
      %{alert: alert} =
        start_alert(envelope(alert_id: "alert-agent-overrides"), broker,
          gemini_client: Pageless.Svc.GeminiClient.Mock
        )

      assert {:ok, agent_pid} =
               Alert.start_agent(alert, Pageless.Sup.AlertTest.StubAgent,
                 caller: self(),
                 gemini_client: Pageless.Sup.AlertTest.OtherGemini
               )

      assert_receive {:stub_agent_started, ^agent_pid, opts}
      assert Keyword.fetch!(opts, :gemini_client) == Pageless.Sup.AlertTest.OtherGemini
    end

    test "agent startup errors are returned to the caller", %{pubsub: broker} do
      %{alert: alert} = start_alert(envelope(alert_id: "alert-crash-agent"), broker)

      assert {:error, :boom} = Alert.start_agent(alert, Pageless.Sup.AlertTest.CrashAgent, [])
    end
  end

  describe "lifecycle" do
    test "stop/1 cleanly stops supervisor and children", %{pubsub: broker} do
      %{alert: alert, state: state_pid, agent_sup: agent_sup} =
        start_alert(envelope(alert_id: "alert-stop"), broker)

      assert :ok = Alert.stop(alert)

      refute Process.alive?(alert)
      refute Process.alive?(state_pid)
      refute Process.alive?(agent_sup)
    end

    test "normally exiting agent is not restarted", %{pubsub: broker} do
      %{alert: alert, agent_sup: agent_sup} =
        start_alert(envelope(alert_id: "alert-agent-normal"), broker)

      assert {:ok, agent_pid} =
               Alert.start_agent(alert, Pageless.Sup.AlertTest.StubAgent, caller: self())

      assert_receive {:stub_agent_started, ^agent_pid, _opts}
      monitor_ref = Process.monitor(agent_pid)
      send(agent_pid, :stop)
      assert_receive {:DOWN, ^monitor_ref, :process, ^agent_pid, reason}
      assert clean_exit?(reason)

      refute Enum.any?(DynamicSupervisor.which_children(agent_sup), fn {_id, pid, _type, _modules} ->
               pid == agent_pid
             end)
    end
  end

  defp start_alert(env, broker, opts \\ []) do
    defaults = [envelope: env, pubsub: broker, parent: self()]
    SupHelpers.start_isolated_alert(Keyword.merge(defaults, opts))
  end

  defp start_state(broker, opts \\ []) do
    defaults = [envelope: envelope(alert_id: unique("alert-state")), pubsub: broker]
    start_supervised!({State, Keyword.merge(defaults, opts)})
  end

  defp unique(prefix) do
    "#{prefix}-#{System.unique_integer([:positive])}"
  end

  defp clean_exit?(reason) when reason in [:normal, :noproc, :shutdown], do: true
  defp clean_exit?({:shutdown, _details}), do: true
  defp clean_exit?(_reason), do: false

  defp envelope(overrides) do
    defaults = %{
      alert_id: "alert-sup-123",
      source: :alertmanager,
      source_ref: "am-ref",
      fingerprint: "fingerprint-alert",
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

    struct!(AlertEnvelope, Map.merge(defaults, Map.new(overrides)))
  end
end
