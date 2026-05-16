defmodule Pageless.Sup.AlertTreeTest.StubAlert do
  @moduledoc "Minimal alert supervisor test double used by AlertTree tests."

  @doc "Starts a tiny linked process and reports its start opts to the caller."
  @spec start_link(keyword()) :: {:ok, pid()}
  def start_link(opts) do
    caller = Keyword.fetch!(opts, :caller)
    parent = self()

    pid =
      spawn_link(fn ->
        send(caller, {:stub_alert_started, self(), parent, opts})

        receive do
          :stop -> :ok
        end
      end)

    {:ok, pid}
  end
end

defmodule Pageless.Sup.AlertTreeTest do
  @moduledoc "Tests isolated alert tree supervision and PubSub intake."

  use ExUnit.Case, async: true

  alias Pageless.AlertEnvelope
  alias Pageless.PubSubHelpers
  alias Pageless.Sup.AlertTree
  alias Pageless.SupHelpers

  setup do
    %{pubsub: PubSubHelpers.start_isolated_pubsub()}
  end

  describe "DynamicSupervisor surface" do
    test "starts as an unnamed DynamicSupervisor" do
      tree = start_supervised!({AlertTree, []})

      assert Process.alive?(tree)
      assert Process.info(tree, :registered_name) == {:registered_name, []}
      assert DynamicSupervisor.count_children(tree).active == 0
    end

    test "start_alert/2 starts an alert supervisor child", %{pubsub: broker} do
      tree = start_supervised!({AlertTree, []})
      env = envelope(alert_id: "alert-tree-child")

      assert {:ok, child_pid} =
               AlertTree.start_alert(tree,
                 envelope: env,
                 pubsub: broker,
                 alert_supervisor: Pageless.Sup.AlertTreeTest.StubAlert,
                 caller: self()
               )

      assert Process.alive?(child_pid)
      assert DynamicSupervisor.count_children(tree).active == 1
      assert_receive {:stub_alert_started, ^child_pid, _parent, opts}
      assert Keyword.fetch!(opts, :envelope) == env
      assert Keyword.fetch!(opts, :pubsub) == broker
    end

    test "uses injected alert supervisor module", %{pubsub: broker} do
      tree = start_supervised!({AlertTree, []})

      assert {:ok, child_pid} =
               AlertTree.start_alert(tree,
                 envelope: envelope(alert_id: "alert-injected-module"),
                 pubsub: broker,
                 alert_supervisor: Pageless.Sup.AlertTreeTest.StubAlert,
                 caller: self()
               )

      assert_receive {:stub_alert_started, ^child_pid, _parent, opts}
      assert Keyword.fetch!(opts, :alert_supervisor) == Pageless.Sup.AlertTreeTest.StubAlert
    end

    test "start_alert/2 returns {:error, :max_children} when the cap is reached", %{
      pubsub: broker
    } do
      tree = start_supervised!({AlertTree, max_children: 1})

      assert {:ok, _first_pid} =
               AlertTree.start_alert(tree,
                 envelope: envelope(alert_id: "alert-cap-1"),
                 pubsub: broker,
                 alert_supervisor: Pageless.Sup.AlertTreeTest.StubAlert,
                 caller: self()
               )

      assert {:error, :max_children} =
               AlertTree.start_alert(tree,
                 envelope: envelope(alert_id: "alert-cap-2"),
                 pubsub: broker,
                 alert_supervisor: Pageless.Sup.AlertTreeTest.StubAlert,
                 caller: self()
               )

      assert DynamicSupervisor.count_children(tree).active == 1
      assert Process.alive?(tree)
    end

    test "utilization/1 returns active children divided by max_children", %{pubsub: broker} do
      tree = start_supervised!({AlertTree, max_children: 2})

      assert AlertTree.utilization(tree) == 0.0

      assert {:ok, _first_pid} =
               AlertTree.start_alert(tree,
                 envelope: envelope(alert_id: "alert-utilization-1"),
                 pubsub: broker,
                 alert_supervisor: Pageless.Sup.AlertTreeTest.StubAlert,
                 caller: self()
               )

      assert AlertTree.utilization(tree) == 0.5
    end

    test "utilization/1 returns zero for unbounded trees" do
      tree = start_supervised!({AlertTree, max_children: :infinity})

      assert AlertTree.utilization(tree) == 0.0
    end

    test "concurrent start_alert calls produce distinct children", %{pubsub: broker} do
      tree = start_supervised!({AlertTree, []})
      parent = self()

      tasks =
        for index <- 1..2 do
          Task.async(fn ->
            AlertTree.start_alert(tree,
              envelope: envelope(alert_id: "alert-concurrent-#{index}"),
              pubsub: broker,
              alert_supervisor: Pageless.Sup.AlertTreeTest.StubAlert,
              caller: parent
            )
          end)
        end

      child_pids =
        Enum.map(tasks, fn task ->
          assert {:ok, child_pid} = Task.await(task, 1_000)
          child_pid
        end)

      assert Enum.uniq(child_pids) == child_pids
      assert DynamicSupervisor.count_children(tree).active == 2
    end
  end

  describe "AlertIntake subscriber" do
    test "isolated helper starts unnamed tree and intake", %{pubsub: broker} do
      %{tree: tree, intake: intake} = SupHelpers.start_isolated_tree(pubsub: broker)

      assert Process.alive?(tree)
      assert Process.alive?(intake)
      assert Process.info(tree, :registered_name) == {:registered_name, []}
      assert Process.info(intake, :registered_name) == {:registered_name, []}
    end

    test "get_state handshakes after subscription setup", %{pubsub: broker} do
      %{tree: tree, intake: intake} = SupHelpers.start_isolated_tree(pubsub: broker)

      assert {:ok, %{pubsub: ^broker, tree: ^tree}} = GenServer.call(intake, :get_state)
    end

    test "broadcasting alert_received starts one alert child", %{pubsub: broker} do
      %{tree: tree, intake: intake} = SupHelpers.start_isolated_tree(pubsub: broker)
      before_count = DynamicSupervisor.count_children(tree).active

      Phoenix.PubSub.broadcast(
        broker,
        "alerts",
        {:alert_received, envelope(alert_id: "alert-intake-1")}
      )

      assert {:ok, _state} = GenServer.call(intake, :get_state)

      assert DynamicSupervisor.count_children(tree).active == before_count + 1
    end

    test "broadcasting two alerts starts two children", %{pubsub: broker} do
      %{tree: tree, intake: intake} = SupHelpers.start_isolated_tree(pubsub: broker)

      Phoenix.PubSub.broadcast(
        broker,
        "alerts",
        {:alert_received, envelope(alert_id: "alert-intake-a")}
      )

      Phoenix.PubSub.broadcast(
        broker,
        "alerts",
        {:alert_received, envelope(alert_id: "alert-intake-b")}
      )

      assert {:ok, _state} = GenServer.call(intake, :get_state)

      assert DynamicSupervisor.count_children(tree).active == 2
    end

    test "intake logs a warning and stays alive when the tree is at max_children", %{
      pubsub: broker
    } do
      tree =
        start_supervised!({AlertTree, max_children: 1},
          id: {AlertTree, :overflow_intake_test}
        )

      intake =
        start_supervised!({Pageless.Sup.AlertIntake, pubsub: broker, tree: tree},
          id: {Pageless.Sup.AlertIntake, :overflow_intake_test}
        )

      {:ok, _state} = GenServer.call(intake, :get_state)

      # Saturate the tree directly with the stub supervisor so no real Alert is started.
      {:ok, _first_pid} =
        AlertTree.start_alert(tree,
          envelope: envelope(alert_id: "alert-overflow-first"),
          pubsub: broker,
          alert_supervisor: Pageless.Sup.AlertTreeTest.StubAlert,
          caller: self()
        )

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          Phoenix.PubSub.broadcast(
            broker,
            "alerts",
            {:alert_received, envelope(alert_id: "alert-overflow-shed")}
          )

          # Serialize the intake mailbox so we know the message has been processed.
          {:ok, _state} = GenServer.call(intake, :get_state)
        end)

      assert log =~ "alert tree at max_children"
      assert log =~ "alert-overflow-shed"
      assert Process.alive?(intake)
      assert DynamicSupervisor.count_children(tree).active == 1
    end

    test "unknown messages do not crash intake", %{pubsub: broker} do
      %{intake: intake} = SupHelpers.start_isolated_tree(pubsub: broker)

      send(intake, {:unknown, :message})
      assert {:ok, %{pubsub: ^broker}} = GenServer.call(intake, :get_state)
      assert Process.alive?(intake)
    end

    test "isolated brokers do not leak alert broadcasts across trees" do
      broker_a = PubSubHelpers.start_isolated_pubsub()
      broker_b = PubSubHelpers.start_isolated_pubsub()
      %{tree: tree_a, intake: intake_a} = SupHelpers.start_isolated_tree(pubsub: broker_a)
      %{tree: tree_b, intake: intake_b} = SupHelpers.start_isolated_tree(pubsub: broker_b)

      Phoenix.PubSub.broadcast(
        broker_a,
        "alerts",
        {:alert_received, envelope(alert_id: "alert-broker-a")}
      )

      assert {:ok, _state} = GenServer.call(intake_a, :get_state)
      assert {:ok, _state} = GenServer.call(intake_b, :get_state)

      assert DynamicSupervisor.count_children(tree_a).active == 1
      assert DynamicSupervisor.count_children(tree_b).active == 0
    end
  end

  defp envelope(overrides) do
    defaults = %{
      alert_id: "alert-tree-123",
      source: :alertmanager,
      source_ref: "am-ref",
      fingerprint: "fingerprint-tree",
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
