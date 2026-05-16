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

    test "operator_ref defaults to a session-derived neutral string", %{conn: conn} do
      broker = PubSubHelpers.start_isolated_pubsub()

      {:ok, view, _html} =
        live_isolated(conn, OperatorDashboardLive, session: %{"pubsub_broker" => broker})

      operator_ref = :sys.get_state(view.pid).socket.assigns.operator_ref

      assert is_binary(operator_ref)
      assert String.starts_with?(operator_ref, "dashboard_session:")
      refute operator_ref == "operator:demo"
      assert String.length(operator_ref) > String.length("dashboard_session:")
    end
  end

  describe "subscription churn invariant" do
    test "first alert subscribes to per-alert topic exactly once", %{conn: conn} do
      broker = PubSubHelpers.start_isolated_pubsub()
      envelope = demo_envelope("demo-a-payments-api")
      topic = alert_topic(envelope)

      {:ok, view, _html} =
        live_isolated(conn, OperatorDashboardLive, session: %{"pubsub_broker" => broker})

      Phoenix.PubSub.broadcast(broker, "alerts", {:alert_received, envelope})
      assert render(view) =~ "payments-api health check failing"

      assert PubSubHelpers.subscribed?(broker, topic, view.pid)
      assert PubSubHelpers.subscription_count(broker, topic, view.pid) == 1
    end

    test "duplicate alert envelope keeps one per-alert subscription", %{conn: conn} do
      broker = PubSubHelpers.start_isolated_pubsub()
      envelope = demo_envelope("demo-a-payments-api")
      topic = alert_topic(envelope)

      {:ok, view, _html} =
        live_isolated(conn, OperatorDashboardLive, session: %{"pubsub_broker" => broker})

      Phoenix.PubSub.broadcast(broker, "alerts", {:alert_received, envelope})
      assert render(view) =~ "payments-api health check failing"

      Phoenix.PubSub.broadcast(broker, "alerts", {:alert_received, envelope})
      assert render(view) =~ "payments-api health check failing"

      assert PubSubHelpers.subscribed?(broker, topic, view.pid)
      assert PubSubHelpers.subscription_count(broker, topic, view.pid) == 1
    end

    test "switching to a new alert unsubscribes from the prior per-alert topic", %{conn: conn} do
      broker = PubSubHelpers.start_isolated_pubsub()
      first_envelope = demo_envelope("demo-a-payments-api")
      second_envelope = demo_envelope("demo-b-payments-api")
      first_topic = alert_topic(first_envelope)
      second_topic = alert_topic(second_envelope)

      {:ok, view, _html} =
        live_isolated(conn, OperatorDashboardLive, session: %{"pubsub_broker" => broker})

      Phoenix.PubSub.broadcast(broker, "alerts", {:alert_received, first_envelope})
      assert render(view) =~ "payments-api health check failing"
      assert PubSubHelpers.subscribed?(broker, first_topic, view.pid)

      Phoenix.PubSub.broadcast(broker, "alerts", {:alert_received, second_envelope})
      assert render(view) =~ "payments-api health check failing"

      refute PubSubHelpers.subscribed?(broker, first_topic, view.pid)
      assert PubSubHelpers.subscribed?(broker, second_topic, view.pid)
      assert PubSubHelpers.subscription_count(broker, second_topic, view.pid) == 1
    end

    @tag :acceptance
    test "documented reasoning events update only the current alert tree", %{conn: conn} do
      broker = PubSubHelpers.start_isolated_pubsub()
      first_envelope = demo_envelope("demo-a-payments-api")
      second_envelope = demo_envelope("demo-b-payments-api")

      {:ok, view, _html} =
        live_isolated(conn, OperatorDashboardLive, session: %{"pubsub_broker" => broker})

      Phoenix.PubSub.broadcast(broker, "alerts", {:alert_received, first_envelope})
      assert render(view) =~ "payments-api health check failing"

      Phoenix.PubSub.broadcast(
        broker,
        alert_topic(first_envelope),
        {:triager_spawned, "triager-1", first_envelope.alert_id}
      )

      Phoenix.PubSub.broadcast(
        broker,
        alert_topic(first_envelope),
        {:triager_reasoning, "triager-1", first_envelope.alert_id, "stale triage from alert A"}
      )

      first_alert_html = render(view)
      assert first_alert_html =~ "triager-1"
      assert first_alert_html =~ "stale triage from alert A"

      Phoenix.PubSub.broadcast(
        broker,
        alert_topic(first_envelope),
        {:triager_reasoning, "triager-1", first_envelope.alert_id,
         "queued stale triage from alert A"}
      )

      Phoenix.PubSub.broadcast(broker, "alerts", {:alert_received, second_envelope})
      switched_html = render(view)
      assert switched_html =~ second_envelope.alert_id
      refute switched_html =~ "stale triage from alert A"
      refute switched_html =~ "queued stale triage from alert A"

      Phoenix.PubSub.broadcast(
        broker,
        alert_topic(first_envelope),
        {:triager_reasoning, "triager-1", first_envelope.alert_id,
         "late stale triage from alert A"}
      )

      stale_html = render(view)
      refute stale_html =~ "late stale triage from alert A"

      Phoenix.PubSub.broadcast(
        broker,
        alert_topic(second_envelope),
        {:triager_spawned, "triager-1", second_envelope.alert_id}
      )

      Phoenix.PubSub.broadcast(
        broker,
        alert_topic(second_envelope),
        {:remediator_spawned, "remediator-1", second_envelope.alert_id}
      )

      Phoenix.PubSub.broadcast(
        broker,
        alert_topic(second_envelope),
        {:escalator_spawned, "escalator-1", second_envelope.alert_id}
      )

      Phoenix.PubSub.broadcast(
        broker,
        alert_topic(second_envelope),
        {:triager_reasoning, "triager-1", second_envelope.alert_id, "triager scoped reasoning B"}
      )

      Phoenix.PubSub.broadcast(
        broker,
        alert_topic(second_envelope),
        {:remediator_reasoning, "remediator-1", second_envelope.alert_id,
         "remediator scoped reasoning B"}
      )

      Phoenix.PubSub.broadcast(
        broker,
        alert_topic(second_envelope),
        {:escalator_reasoning, "escalator-1", second_envelope.alert_id,
         "escalator scoped reasoning B"}
      )

      current_html = render(view)
      assert current_html =~ "triager scoped reasoning B"
      assert current_html =~ "remediator scoped reasoning B"
      assert current_html =~ "escalator scoped reasoning B"
      refute current_html =~ "late stale triage from alert A"
      refute current_html =~ "N/A"
      refute current_html =~ "error"
    end

    @tag :acceptance
    test "after alert switch, gate events on old topic do not reach dashboard", %{conn: conn} do
      broker = PubSubHelpers.start_isolated_pubsub()
      first_envelope = demo_envelope("demo-a-payments-api")
      second_envelope = demo_envelope("demo-b-payments-api")
      first_gate_id = unique("gate-a")
      second_gate_id = unique("gate-b")
      first_tool_call = rollout_undo_call(first_envelope.alert_id)
      second_tool_call = rollout_undo_call(second_envelope.alert_id)

      first_reasoning_context = %{
        summary: "rollback first alert",
        evidence_link: "https://runbooks.example/payments-a"
      }

      second_reasoning_context = %{
        summary: "rollback second alert",
        evidence_link: "https://runbooks.example/payments-b"
      }

      {:ok, view, _html} =
        live_isolated(conn, OperatorDashboardLive, session: %{"pubsub_broker" => broker})

      Phoenix.PubSub.broadcast(broker, "alerts", {:alert_received, first_envelope})
      assert render(view) =~ "payments-api health check failing"

      Phoenix.PubSub.broadcast(broker, "alerts", {:alert_received, second_envelope})
      assert render(view) =~ "payments-api health check failing"

      Phoenix.PubSub.broadcast(
        broker,
        alert_topic(first_envelope),
        {:gate_fired, first_gate_id, first_tool_call, :write_prod_high, "rollout undo",
         first_reasoning_context}
      )

      old_topic_html = render(view)

      Phoenix.PubSub.broadcast(
        broker,
        alert_topic(first_envelope),
        {:reasoning_line, "investigator-logs-1", first_envelope.alert_id, "stale old alert line"}
      )

      stale_agent_html = render(view)
      refute stale_agent_html =~ "stale old alert line"

      refute old_topic_html =~ "rollback first alert"
      refute old_topic_html =~ "Approve"
      refute old_topic_html =~ "Deny"
      refute old_topic_html =~ "error"

      Phoenix.PubSub.broadcast(
        broker,
        alert_topic(second_envelope),
        {:gate_fired, second_gate_id, second_tool_call, :write_prod_high, "rollout undo",
         second_reasoning_context}
      )

      current_topic_html = render(view)
      assert current_topic_html =~ "rollback second alert"
      assert current_topic_html =~ "kubectl rollout undo deployment/payments-api -n prod"
      assert current_topic_html =~ "Approve"
      assert current_topic_html =~ "Deny"
      refute current_topic_html =~ "N/A"
      refute current_topic_html =~ "error"
    end

    test "connected LiveView mount sets max_heap_size kill cap", %{conn: conn} do
      broker = PubSubHelpers.start_isolated_pubsub()
      expected_size = div(50_000_000, :erlang.system_info(:wordsize))

      {:ok, view, _html} =
        live_isolated(conn, OperatorDashboardLive, session: %{"pubsub_broker" => broker})

      assert {:max_heap_size, max_heap_size} = Process.info(view.pid, :max_heap_size)
      assert max_heap_size[:size] == expected_size
      assert max_heap_size[:kill] == true
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

      Phoenix.PubSub.broadcast(
        broker,
        "alert:#{envelope.alert_id}",
        {:triager_spawned, "triager-1", envelope.alert_id}
      )

      tree_html = render(view)
      assert tree_html =~ "triager-1"
      assert tree_html =~ "Triager"
      refute tree_html =~ "N/A"
      refute tree_html =~ "error"
    end

    test "absorbs LiveFlow hook callbacks without crashing the dashboard", %{conn: conn} do
      broker = PubSubHelpers.start_isolated_pubsub()
      envelope = demo_envelope()

      {:ok, view, _html} =
        live_isolated(conn, OperatorDashboardLive, session: %{"pubsub_broker" => broker})

      Phoenix.PubSub.broadcast(broker, "alerts", {:alert_received, envelope})
      assert render(view) =~ "payments-api health check failing"

      Phoenix.PubSub.broadcast(
        broker,
        "alert:#{envelope.alert_id}",
        {:triager_spawned, "triager-1", envelope.alert_id}
      )

      assert render(view) =~ "triager-1"

      render_hook(view, "lf:node_change", %{
        "changes" => [
          %{"id" => "triager-1", "type" => "dimensions", "height" => 114, "width" => 163}
        ]
      })

      render_hook(view, "lf:viewport_change", %{"x" => 0, "y" => 0, "zoom" => 1.0})
      render_hook(view, "lf:edge_change", %{"changes" => []})

      assert Process.alive?(view.pid)
      survived_html = render(view)
      assert survived_html =~ "triager-1"
      assert survived_html =~ "Triager"
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

    @tag :acceptance
    test "denying a gated rollout undo collapses the modal without dispatching", %{conn: conn} do
      broker = PubSubHelpers.start_isolated_pubsub()

      envelope = demo_envelope()
      gate_id = unique("gate")
      tool_call = rollout_undo_call(envelope.alert_id)
      reasoning_context = %{summary: "rollback bad deploy", evidence_link: "runbook://payments"}
      tool_dispatch = {__MODULE__, :dispatch_tool, [self()]}
      repo = repo_double_for_deny(gate_id, tool_call, self())

      :ok = Phoenix.PubSub.subscribe(broker, "alert:#{envelope.alert_id}")

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

      assert_receive {:gate_fired, ^gate_id, _, :write_prod_high, "rollout undo", _}, 500

      modal_html = render(view)
      assert modal_html =~ "rollout undo"
      assert modal_html =~ "deployment/payments-api"
      assert modal_html =~ "rollback bad deploy"
      assert modal_html =~ "Approve"
      assert modal_html =~ "Deny"

      view |> element("button", "Deny") |> render_click()

      assert_receive {:claimed_for_denial, ^gate_id, "operator:demo", "denied via dashboard"}, 500

      assert_receive {:gate_decision, :denied, ^gate_id, "operator:demo", "denied via dashboard"},
                     500

      refute_received {:tool_dispatched, _other_call}

      collapsed_html = render(view)
      refute collapsed_html =~ "rollout undo"
      refute collapsed_html =~ "deployment/payments-api"
      assert collapsed_html =~ "Pageless — Operator Dashboard"
    end
  end

  defp demo_envelope(alert_id \\ "demo-b1-payments-api") do
    assert {:ok, envelope} =
             AlertEnvelope.new(%{
               alert_id: alert_id,
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

  defp alert_topic(%AlertEnvelope{alert_id: alert_id}), do: "alert:#{alert_id}"

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

  defp repo_double_for_deny(gate_id, %ToolCall{} = tool_call, test_pid) when is_pid(test_pid) do
    module = Module.concat(__MODULE__, "RepoDoubleDeny#{System.unique_integer([:positive])}")
    gated = Macro.escape(gated_decision(gate_id, tool_call))
    denied = Macro.escape(denied_decision(gate_id, tool_call))
    test_pid_escaped = Macro.escape(test_pid)

    Module.create(
      module,
      quote do
        def get_by_gate_id(unquote(gate_id)), do: unquote(gated)

        def claim_gate_for_denial(unquote(gate_id), operator_ref, reason) do
          send(
            unquote(test_pid_escaped),
            {:claimed_for_denial, unquote(gate_id), operator_ref, reason}
          )

          {:ok, unquote(denied)}
        end
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

  defp denied_decision(gate_id, %ToolCall{} = tool_call) do
    decision_fixture(gate_id, tool_call, "denied")
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
