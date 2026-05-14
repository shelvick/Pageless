defmodule PagelessWeb.OperatorDashboardLiveTest do
  @moduledoc "Tests for the operator dashboard LiveView shell."

  use PagelessWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Pageless.AlertEnvelope
  alias Pageless.AuditTrail.Decision
  alias Pageless.Conductor.DemoConductor
  alias Pageless.Governance.ToolCall
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

    @tag :acceptance
    test "approving a gated rollout undo dispatches once and collapses the modal", %{conn: conn} do
      broker = PubSubHelpers.start_isolated_pubsub()

      envelope = demo_envelope()
      gate_id = unique("gate")
      tool_call = rollout_undo_call(envelope.alert_id)
      reasoning_context = %{summary: "rollback bad deploy", evidence_link: "runbook://payments"}
      tool_dispatch = {__MODULE__, :dispatch_tool, [self()]}
      repo = repo_double(gate_id, tool_call)

      {:ok, view, _html} =
        live_isolated(conn, OperatorDashboardLive,
          session: %{
            "pubsub_broker" => broker,
            "repo" => repo,
            "tool_dispatch" => tool_dispatch,
            "operator_ref" => "operator:demo"
          }
        )

      Phoenix.PubSub.broadcast(broker, "alerts", {:alert_received, envelope})
      assert render(view) =~ "payments-api health check failing"

      Phoenix.PubSub.broadcast(
        broker,
        "alert:#{envelope.alert_id}",
        {:gate_fired, gate_id, tool_call, :write_prod_high, "rollout undo", reasoning_context}
      )

      modal_html = render(view)
      assert modal_html =~ "rollout undo"
      assert modal_html =~ "deployment/payments-api"
      assert modal_html =~ "rollback bad deploy"
      assert modal_html =~ "Approve"
      assert modal_html =~ "Deny"
      refute modal_html =~ "N/A"
      refute modal_html =~ "error"

      view |> element("button", "Approve") |> render_click()

      assert_receive {:tool_dispatched, ^tool_call}, 500
      refute_received {:tool_dispatched, _other_call}

      Phoenix.PubSub.broadcast(
        broker,
        "alert:#{envelope.alert_id}",
        {:gate_decision, :executed, gate_id, tool_call, "rolled back"}
      )

      collapsed_html = render(view)
      refute collapsed_html =~ "rollout undo"
      refute collapsed_html =~ "deployment/payments-api"
      assert collapsed_html =~ "Pageless — Operator Dashboard"
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

  def dispatch_tool(test_pid, %ToolCall{} = dispatched_call) when is_pid(test_pid) do
    send(test_pid, {:tool_dispatched, dispatched_call})
    {:ok, "rolled back"}
  end

  defp rollout_undo_call(alert_id) do
    %ToolCall{
      tool: :kubectl,
      args: ["rollout", "undo", "deployment/payments-api", "-n", "prod"],
      agent_id: Ecto.UUID.generate(),
      agent_pid_inspect: inspect(self()),
      alert_id: alert_id,
      request_id: unique("req"),
      reasoning_context: %{summary: "rollback bad deploy", evidence_link: "runbook://payments"}
    }
  end

  defp repo_double(gate_id, %ToolCall{} = tool_call) do
    module = Module.concat(__MODULE__, "RepoDouble#{System.unique_integer([:positive])}")
    gated = Macro.escape(gated_decision(gate_id, tool_call))
    approved = Macro.escape(approved_decision(gate_id, tool_call))

    Module.create(
      module,
      quote do
        def get_by_gate_id(unquote(gate_id)), do: unquote(gated)

        def claim_gate_for_approval(unquote(gate_id), "operator:demo"),
          do: {:ok, unquote(approved)}

        def update_decision(decision, _attrs),
          do: {:ok, %{decision | decision: "executed", result_status: "ok"}}
      end,
      Macro.Env.location(__ENV__)
    )

    module
  end

  defp gated_decision(gate_id, %ToolCall{} = tool_call) do
    decision_fixture(gate_id, tool_call, "gated")
  end

  defp approved_decision(gate_id, %ToolCall{} = tool_call) do
    decision_fixture(gate_id, tool_call, "approved")
  end

  defp decision_fixture(gate_id, %ToolCall{} = tool_call, decision) do
    %Decision{
      id: Ecto.UUID.generate(),
      request_id: tool_call.request_id,
      gate_id: gate_id,
      alert_id: tool_call.alert_id,
      agent_id: tool_call.agent_id,
      agent_pid_inspect: tool_call.agent_pid_inspect,
      tool: Atom.to_string(tool_call.tool),
      args: %{"argv" => tool_call.args},
      extracted_verb: "rollout undo",
      classification: "write_prod_high",
      decision: decision,
      result_summary: Jason.encode!(%{"reasoning_context" => tool_call.reasoning_context})
    }
  end

  defp unique(prefix), do: "#{prefix}_#{System.unique_integer([:positive])}"
end
