defmodule PagelessWeb.OperatorDashboardLiveTest do
  @moduledoc "Tests for the operator dashboard LiveView shell."

  use PagelessWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Pageless.AlertEnvelope
  alias Pageless.Conductor.DemoConductor
  alias Pageless.PubSubHelpers
  alias PagelessWeb.OperatorDashboardLive

  describe "mount" do
    test "renders the initial dashboard shell with placeholders", %{conn: conn} do
      broker = PubSubHelpers.start_isolated_pubsub()

      {:ok, _view, html} =
        live_isolated(conn, OperatorDashboardLive, session: %{"pubsub_broker" => broker})

      assert html =~ "Pageless — Operator Dashboard"
      assert html =~ "No alert"
      assert html =~ "Agent tree"
      assert html =~ "Time to resolution"
      assert html =~ "—"
    end
  end

  describe "PubSub round trip" do
    @tag :acceptance
    test "conductor alert and scoreboard events update the visible dashboard", %{conn: conn} do
      broker = PubSubHelpers.start_isolated_pubsub()
      conductor = start_supervised!({DemoConductor, pubsub: broker})
      envelope = demo_envelope()
      stats = locked_scoreboard_stats()

      {:ok, view, _html} =
        live_isolated(conn, OperatorDashboardLive, session: %{"pubsub_broker" => broker})

      assert :ok = DemoConductor.broadcast_alert(conductor, envelope)

      alert_html = render(view)
      assert alert_html =~ "payments-api health check failing"
      assert alert_html =~ "[CONDUCTOR]"
      refute alert_html =~ "N/A"
      refute alert_html =~ "error"

      assert :ok = DemoConductor.broadcast_scoreboard(conductor, stats)

      scoreboard_html = render(view)
      assert scoreboard_html =~ "1m 28s"
      assert scoreboard_html =~ "5"
      assert scoreboard_html =~ "9"
      assert scoreboard_html =~ "1"
      assert scoreboard_html =~ "0"
      refute scoreboard_html =~ "N/A"
      refute scoreboard_html =~ "error"

      assert :ok = DemoConductor.broadcast_beat(conductor, :b2)
      assert :ok = DemoConductor.broadcast_beat(conductor, :b8)

      assert render(view) =~ "Pageless — Operator Dashboard"
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
