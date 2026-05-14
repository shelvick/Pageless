defmodule PagelessWeb.Components.AgentTreeViewTest do
  @moduledoc "Tests for the agent tree topology projection component."

  use PagelessWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Pageless.AlertEnvelope
  alias Pageless.PubSubHelpers
  alias PagelessWeb.Components.AgentTreeView
  alias PagelessWeb.OperatorDashboardLive

  describe "event_to_node_mutation/2" do
    test "adds a triager root node when the triager spawns" do
      {topology, node_data} =
        mutate(empty_projection(), {:triager_spawned, "triager-1", "alert-x"})

      assert node_data["triager-1"].role == :triager
      assert node_data["triager-1"].status == :thinking
      assert node_data["triager-1"].reasoning == []
      assert has_node?(topology, "triager-1")
      assert edge_count(topology) == 0
    end

    test "fans out investigator nodes from a dispatched triager" do
      pid = self()

      projection =
        empty_projection()
        |> mutate_projection({:triager_spawned, "triager-1", "alert-x"})
        |> mutate_projection(
          {:triager_dispatched, "triager-1", "alert-x",
           [
             %{profile: :logs, pid: pid, chain_position: 0},
             %{profile: :metrics, pid: pid, chain_position: 1},
             %{profile: :deploys, pid: pid, chain_position: 2}
           ]}
        )

      %{topology: topology, node_data: node_data} = projection

      assert map_size(node_data) == 4
      assert Enum.count(node_data, fn {_id, data} -> data.role == :investigator end) == 3
      assert Enum.any?(node_data, fn {_id, data} -> data.payload[:profile] == :logs end)
      assert Enum.any?(node_data, fn {_id, data} -> data.payload[:profile] == :metrics end)
      assert Enum.any?(node_data, fn {_id, data} -> data.payload[:profile] == :deploys end)
      assert edge_count(topology) == 3
      assert has_edge?(topology, "triager-1", investigator_id(node_data, :logs))
    end

    test "streams reasoning into one investigator without changing siblings" do
      projection = investigator_projection()
      logs_id = investigator_id(projection.node_data, :logs)
      metrics_id = investigator_id(projection.node_data, :metrics)
      metrics_before = projection.node_data[metrics_id]

      %{node_data: node_data} =
        mutate_projection(projection, {:reasoning_line, logs_id, "Errors begin at 03:44:12"})

      assert node_data[logs_id].reasoning == ["Errors begin at 03:44:12"]
      assert node_data[metrics_id] == metrics_before
    end

    test "records investigator tool calls with literal command and classification" do
      projection = investigator_projection()
      logs_id = investigator_id(projection.node_data, :logs)
      result = {:ok, "pod logs"}

      %{node_data: node_data} =
        mutate_projection(
          projection,
          {:tool_call, logs_id, "kubectl", ["logs", "-n", "prod"], result, :read}
        )

      assert node_data[logs_id].status == :tool_active
      assert node_data[logs_id].tool_call.command == "kubectl logs -n prod"
      assert node_data[logs_id].tool_call.classification == :read
      assert node_data[logs_id].tool_call.result == result
    end

    test "marks gated remediator proposals with a command card and red banner state" do
      projection = remediator_projection()

      %{node_data: node_data} =
        mutate_projection(
          projection,
          {:remediator_action_proposed, "remediator-1", "alert-x",
           %{
             gate_id: "g-1",
             action: :rollout_undo,
             args: ["deployment/payments-api", "-n", "prod"],
             classification_hint: :write_prod_high,
             rationale: "rollback bad deploy",
             considered_alternatives: [%{action: :restart}],
             classification: nil
           }}
        )

      assert node_data["remediator-1"].status == :tool_active
      assert node_data["remediator-1"].banner == :gated
      assert node_data["remediator-1"].gate_id == "g-1"
      assert node_data["remediator-1"].tool_call.command =~ "kubectl rollout undo"
      assert node_data["remediator-1"].tool_call.command =~ "deployment/payments-api"
    end

    test "marks auto-fired remediation executions with a green autonomous banner" do
      projection =
        remediator_projection()
        |> mutate_projection(
          {:remediator_action_proposed, "remediator-1", "alert-x",
           %{
             gate_id: nil,
             action: :rollout_restart,
             args: ["deployment/payments-api", "-n", "prod"],
             classification_hint: :write_dev,
             rationale: "restart unhealthy pods",
             considered_alternatives: [],
             classification: nil
           }}
        )

      %{node_data: node_data} =
        mutate_projection(
          projection,
          {:remediator_action_executed, "remediator-1", "alert-x",
           %{gate_id: nil, action: :rollout_restart, args: [], result: {:ok, "restarted"}}}
        )

      assert node_data["remediator-1"].status == :done
      assert node_data["remediator-1"].banner == :auto_fired
    end

    test "marks escalated remediation and pre-draws the escalator handoff" do
      projection =
        remediator_projection()
        |> mutate_projection(
          {:remediator_action_proposed, "remediator-1", "alert-x",
           %{
             gate_id: "g-1",
             action: :rollout_undo,
             args: ["deployment/payments-api"],
             classification_hint: :write_prod_high,
             rationale: "rollback bad deploy",
             considered_alternatives: [],
             classification: nil
           }}
        )
        |> mutate_projection(
          {:remediator_action_failed, "remediator-1", "alert-x",
           %{reason: {:denied, "operator denied"}, gate_id: "g-1"}}
        )

      escalator_pid = self()

      %{topology: topology, node_data: node_data} =
        mutate_projection(
          projection,
          {:remediator_escalating, "remediator-1", "alert-x", escalator_pid, "operator denied"}
        )

      escalator_id = escalator_id(node_data)
      assert node_data["remediator-1"].banner == :escalated
      assert node_data[escalator_id].role == :escalator
      assert node_data[escalator_id].status == :thinking
      assert has_edge?(topology, "remediator-1", escalator_id)
    end

    test "drops unknown events and secondary events for unknown agents" do
      projection = investigator_projection()

      assert mutate_projection(projection, {:something_unrelated, :foo, :bar}) == projection

      assert mutate_projection(projection, {:reasoning_line, "missing-agent", "late line"}) ==
               projection
    end
  end

  describe "dashboard forwarding integration" do
    @tag :acceptance
    test "forwarded alert-topic agent events render in the tree", %{conn: conn} do
      broker = PubSubHelpers.start_isolated_pubsub()
      envelope = demo_envelope()

      {:ok, view, _html} =
        live_isolated(conn, OperatorDashboardLive, session: %{"pubsub_broker" => broker})

      Phoenix.PubSub.broadcast(broker, "alerts", {:alert_received, envelope})
      alert_html = render(view)
      assert alert_html =~ "payments-api health check failing"
      refute alert_html =~ "Agent tree — awaiting alert"

      Phoenix.PubSub.broadcast(
        broker,
        "alert:#{envelope.alert_id}",
        {:triager_spawned, "triager-1", envelope.alert_id}
      )

      triager_html = render(view)
      assert triager_html =~ "triager-1"
      assert triager_html =~ "Triager"

      Phoenix.PubSub.broadcast(
        broker,
        "alert:#{envelope.alert_id}",
        {:triager_dispatched, "triager-1", envelope.alert_id,
         [
           %{profile: :logs, pid: self(), chain_position: 0},
           %{profile: :metrics, pid: self(), chain_position: 1},
           %{profile: :deploys, pid: self(), chain_position: 2}
         ]}
      )

      investigators_html = render(view)
      assert investigators_html =~ "Logs"
      assert investigators_html =~ "Metrics"
      assert investigators_html =~ "Deploys"

      Phoenix.PubSub.broadcast(
        broker,
        "alert:#{envelope.alert_id}",
        {:reasoning_line, "investigator-logs-1", "Errors begin at 03:44:12"}
      )

      reasoning_html = render(view)
      assert reasoning_html =~ "Errors begin at 03:44:12"
      refute reasoning_html =~ "N/A"
      refute reasoning_html =~ "error"
    end
  end

  defp empty_projection do
    %{topology: %{nodes: %{}, edges: []}, node_data: %{}}
  end

  defp mutate(%{topology: topology, node_data: node_data}, event) do
    AgentTreeView.event_to_node_mutation(event, %{topology: topology, node_data: node_data})
  end

  defp mutate_projection(projection, event) do
    {topology, node_data} = mutate(projection, event)
    %{topology: topology, node_data: node_data}
  end

  defp investigator_projection do
    pid = self()

    empty_projection()
    |> mutate_projection({:triager_spawned, "triager-1", "alert-x"})
    |> mutate_projection(
      {:triager_dispatched, "triager-1", "alert-x",
       [
         %{profile: :logs, pid: pid, chain_position: 0},
         %{profile: :metrics, pid: pid, chain_position: 1},
         %{profile: :deploys, pid: pid, chain_position: 2}
       ]}
    )
  end

  defp remediator_projection do
    empty_projection()
    |> mutate_projection({:triager_spawned, "triager-1", "alert-x"})
    |> mutate_projection({:remediator_spawned, "remediator-1", "alert-x"})
  end

  defp has_node?(topology, id), do: id in node_ids(topology)

  defp node_ids(%{nodes: nodes}) when is_map(nodes), do: Map.keys(nodes)
  defp node_ids(%{nodes: nodes}) when is_list(nodes), do: Enum.map(nodes, &node_id/1)
  defp node_ids(%{nodes: nodes}), do: Enum.map(nodes, &node_id/1)
  defp node_ids(_topology), do: []

  defp node_id(%{id: id}), do: id
  defp node_id(%{"id" => id}), do: id
  defp node_id(id) when is_binary(id), do: id

  defp edge_count(%{edges: edges}) when is_list(edges), do: length(edges)
  defp edge_count(_topology), do: 0

  defp has_edge?(%{edges: edges}, source, target) when is_list(edges) do
    Enum.any?(edges, fn edge ->
      edge_endpoint(edge, :source) == source and edge_endpoint(edge, :target) == target
    end)
  end

  defp has_edge?(_topology, _source, _target), do: false

  defp edge_endpoint(%{source: value}, :source), do: value
  defp edge_endpoint(%{target: value}, :target), do: value
  defp edge_endpoint(%{"source" => value}, :source), do: value
  defp edge_endpoint(%{"target" => value}, :target), do: value
  defp edge_endpoint({source, _target}, :source), do: source
  defp edge_endpoint({_source, target}, :target), do: target

  defp investigator_id(node_data, profile) do
    id =
      Enum.find_value(node_data, fn {id, data} ->
        if data.role == :investigator and data.payload[:profile] == profile, do: id
      end)

    assert id
    id
  end

  defp escalator_id(node_data) do
    id = Enum.find_value(node_data, fn {id, data} -> if data.role == :escalator, do: id end)

    assert id
    id
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
end
