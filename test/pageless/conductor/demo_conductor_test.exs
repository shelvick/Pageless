defmodule Pageless.Conductor.DemoConductorTest do
  @moduledoc "Tests for the demo conductor PubSub producer."

  use ExUnit.Case, async: true

  alias Pageless.AlertEnvelope
  alias Pageless.Conductor.DemoConductor
  alias Pageless.PubSubHelpers

  describe "start_link/1" do
    test "requires an explicitly injected PubSub broker" do
      assert_raise KeyError, fn ->
        DemoConductor.start_link([])
      end
    end
  end

  describe "broadcast_alert/2" do
    test "broadcasts the supplied alert envelope on the alerts topic" do
      broker = PubSubHelpers.start_isolated_pubsub()
      pid = start_supervised!({DemoConductor, pubsub: broker})
      :ok = PubSubHelpers.subscribe(broker, "alerts")
      envelope = demo_envelope()

      assert :ok = DemoConductor.broadcast_alert(pid, envelope)

      assert_receive {:alert_received, ^envelope}, 1_000
    end
  end

  describe "broadcast_beat/2" do
    test "broadcasts B2 and B8 conductor beats on the conductor topic" do
      broker = PubSubHelpers.start_isolated_pubsub()
      pid = start_supervised!({DemoConductor, pubsub: broker})
      :ok = PubSubHelpers.subscribe(broker, "conductor")

      assert :ok = DemoConductor.broadcast_beat(pid, :b2)
      assert :ok = DemoConductor.broadcast_beat(pid, :b8)

      assert_receive {:conductor_beat, :b2, :conductor}, 1_000
      assert_receive {:conductor_beat, :b8, :conductor}, 1_000
    end
  end

  describe "broadcast_scoreboard/2" do
    test "broadcasts locked scoreboard stats as a B7 conductor beat" do
      broker = PubSubHelpers.start_isolated_pubsub()
      pid = start_supervised!({DemoConductor, pubsub: broker})
      :ok = PubSubHelpers.subscribe(broker, "conductor")
      stats = locked_scoreboard_stats()

      assert :ok = DemoConductor.broadcast_scoreboard(pid, stats)

      assert_receive {:conductor_beat, :b7, :conductor, ^stats}, 1_000
    end
  end

  defp demo_envelope do
    assert {:ok, envelope} =
             AlertEnvelope.new(%{
               alert_id: "demo-b1-payments-api",
               source: :demo,
               source_ref: "pageless-demo:b1",
               fingerprint: "payments-api-health-check-failing",
               received_at: ~U[2026-05-13 03:45:00Z],
               started_at: ~U[2026-05-13 03:44:12Z],
               status: :firing,
               severity: :p1,
               alert_class: :service_down_with_recent_deploy,
               title: "payments-api health check failing — 1/8 instances responding",
               service: "payments-api",
               labels: %{"service" => "payments-api", "severity" => "p1"},
               annotations: %{"summary" => "payments-api health check failing"},
               payload_raw: %{"demo_beat" => "B1"}
             })

    envelope
  end

  defp locked_scoreboard_stats do
    %{
      time_to_resolution: "1m 28s",
      agents_spawned: 5,
      tool_calls: 9,
      operator_decisions: 1,
      terminal_commands: 0
    }
  end
end
