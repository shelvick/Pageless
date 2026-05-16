defmodule PagelessWeb.Components.AgentTreeView do
  @moduledoc """
  Per-alert agent topology projection for the operator dashboard.

  The component receives agent PubSub events forwarded by the parent LiveView,
  mutates an in-memory topology map, projects that topology into
  `LiveFlow.Components.Flow`, and renders each node through
  `PagelessWeb.Components.AgentNode`.
  """

  use Phoenix.LiveComponent

  alias LiveFlow.{Edge, Node, State}
  alias PagelessWeb.Components.AgentNode

  @type topology :: %{nodes: map(), edges: [edge()]}
  @type edge :: %{source: String.t(), target: String.t()}
  @type node_data :: %{optional(String.t()) => map()}

  @doc "Initializes the empty topology projection."
  @spec mount(Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def mount(socket) do
    {:ok, assign(socket, topology: empty_topology(), node_data: %{}, alert_id: nil, pubsub: nil)}
  end

  @doc "Applies parent assigns or a forwarded agent event to the tree state."
  @spec update(map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def update(assigns, socket) do
    previous_alert_id = socket.assigns[:alert_id]
    alert_changed? = Map.has_key?(assigns, :alert_id) and assigns.alert_id != previous_alert_id

    socket = assign(socket, Map.drop(assigns, [:event]))

    socket =
      if alert_changed? do
        assign(socket, topology: empty_topology(), node_data: %{})
      else
        socket
      end

    socket =
      case Map.get(assigns, :event) do
        nil ->
          socket

        event ->
          {topology, node_data} = event_to_node_mutation(event, socket.assigns)
          assign(socket, topology: topology, node_data: node_data)
      end

    {:ok, socket}
  end

  @doc "Mutates topology and node data for one agent event without side effects."
  @spec event_to_node_mutation(term(), %{topology: topology(), node_data: node_data()}) ::
          {topology(), node_data()}
  def event_to_node_mutation({:triager_spawned, agent_id, _alert_id}, state) do
    state
    |> add_node(agent_id, :triager, status: :thinking)
    |> to_tuple()
  end

  def event_to_node_mutation({:triager_dispatched, triager_id, _alert_id, investigators}, state)
      when is_list(investigators) do
    projection = normalize_state(state)

    investigators
    |> Enum.reduce(projection, fn entry, acc ->
      profile = Map.get(entry, :profile, :investigator)
      agent_id = investigator_agent_id(profile)

      acc
      |> add_node(agent_id, :investigator, status: :thinking, payload: %{profile: profile})
      |> add_edge(triager_id, agent_id)
    end)
    |> to_tuple()
  end

  def event_to_node_mutation({:remediator_spawned, agent_id, _alert_id}, state) do
    state
    |> add_node(agent_id, :remediator, status: :thinking)
    |> maybe_add_parent_edge("triager-1", agent_id)
    |> to_tuple()
  end

  def event_to_node_mutation({:escalator_spawned, agent_id, _alert_id}, state) do
    state
    |> add_node(agent_id, :escalator, status: :thinking)
    |> maybe_add_parent_edge("remediator-1", agent_id)
    |> to_tuple()
  end

  def event_to_node_mutation({:reasoning_line, agent_id, _alert_id, line}, state) do
    event_to_node_mutation({:reasoning_line, agent_id, line}, state)
  end

  def event_to_node_mutation({:reasoning_line, agent_id, line}, state) do
    state
    |> update_existing_node(agent_id, fn data ->
      Map.update(data, :reasoning, [line], fn lines -> trim_reasoning(lines ++ [line]) end)
    end)
    |> to_tuple()
  end

  def event_to_node_mutation({:triager_reasoning, agent_id, _alert_id, line}, state) do
    event_to_node_mutation({:triager_reasoning, agent_id, line}, state)
  end

  def event_to_node_mutation({:triager_reasoning, agent_id, line}, state) do
    event_to_node_mutation({:reasoning_line, agent_id, line}, state)
  end

  def event_to_node_mutation({:remediator_reasoning, agent_id, _alert_id, line}, state) do
    event_to_node_mutation({:remediator_reasoning, agent_id, line}, state)
  end

  def event_to_node_mutation({:remediator_reasoning, agent_id, line}, state) do
    event_to_node_mutation({:reasoning_line, agent_id, line}, state)
  end

  def event_to_node_mutation({:escalator_reasoning, agent_id, _alert_id, line}, state) do
    event_to_node_mutation({:escalator_reasoning, agent_id, line}, state)
  end

  def event_to_node_mutation({:escalator_reasoning, agent_id, line}, state) do
    event_to_node_mutation({:reasoning_line, agent_id, line}, state)
  end

  def event_to_node_mutation(
        {:tool_call, agent_id, _alert_id, tool, args, result, classification},
        state
      ) do
    event_to_node_mutation({:tool_call, agent_id, tool, args, result, classification}, state)
  end

  def event_to_node_mutation({:tool_call, agent_id, tool, args, result, classification}, state) do
    command = format_command(tool, args)

    state
    |> update_existing_node(agent_id, fn data ->
      data
      |> Map.put(:status, :tool_active)
      |> Map.put(:tool_call, %{command: command, classification: classification, result: result})
    end)
    |> to_tuple()
  end

  def event_to_node_mutation({:remediator_action_proposed, agent_id, _alert_id, proposal}, state)
      when is_map(proposal) do
    gate_id = Map.get(proposal, :gate_id)
    classification = Map.get(proposal, :classification_hint) || Map.get(proposal, :classification)

    state
    |> update_existing_node(agent_id, fn data ->
      data
      |> Map.put(:status, :tool_active)
      |> Map.put(:banner, if(gate_id, do: :gated, else: nil))
      |> Map.put(:gate_id, gate_id)
      |> Map.put(:tool_call, %{
        command: remediator_command(proposal),
        classification: classification,
        result: nil
      })
      |> Map.update(:reasoning, [], fn lines ->
        maybe_append_line(lines, Map.get(proposal, :rationale))
      end)
      |> Map.update(:payload, %{}, fn payload ->
        Map.put(
          payload,
          :considered_alternatives,
          Map.get(proposal, :considered_alternatives, [])
        )
      end)
    end)
    |> to_tuple()
  end

  def event_to_node_mutation({:remediator_action_executed, agent_id, _alert_id, result}, state)
      when is_map(result) do
    state
    |> update_existing_node(agent_id, fn data ->
      data
      |> Map.put(:status, :done)
      |> Map.put(:banner, if(Map.get(result, :gate_id), do: nil, else: :auto_fired))
    end)
    |> to_tuple()
  end

  def event_to_node_mutation({:remediator_action_failed, agent_id, _alert_id, failure}, state)
      when is_map(failure) do
    state
    |> update_existing_node(agent_id, fn data ->
      data
      |> Map.put(:status, :done)
      |> Map.update(:payload, %{failed: failure}, &Map.put(&1, :failed, failure))
    end)
    |> to_tuple()
  end

  def event_to_node_mutation(
        {:remediator_escalating, remediator_id, _alert_id, escalator_pid, reason},
        state
      ) do
    escalator_id = "escalator-#{inspect(escalator_pid)}"

    state
    |> update_existing_node(remediator_id, fn data ->
      data
      |> Map.put(:banner, :escalated)
      |> Map.update(
        :payload,
        %{escalation_reason: reason},
        &Map.put(&1, :escalation_reason, reason)
      )
    end)
    |> add_node(escalator_id, :escalator, status: :thinking)
    |> add_edge(remediator_id, escalator_id)
    |> to_tuple()
  end

  def event_to_node_mutation({:page_out_sent, agent_id, _alert_id, page_payload}, state) do
    state
    |> update_existing_node(agent_id, fn data ->
      data
      |> Map.put(:status, :done)
      |> Map.update(:payload, %{page_out: page_payload}, &Map.put(&1, :page_out, page_payload))
    end)
    |> to_tuple()
  end

  def event_to_node_mutation({:triager_classified, agent_id, _alert_id, classification}, state)
      when is_map(classification) do
    state
    |> update_existing_node(agent_id, fn data ->
      data
      |> Map.put(:status, :tool_active)
      |> Map.update(:payload, classification, &Map.merge(&1, classification))
    end)
    |> to_tuple()
  end

  def event_to_node_mutation({:triager_failed, agent_id, _alert_id, reason}, state) do
    state
    |> update_existing_node(agent_id, fn data ->
      data
      |> Map.put(:status, :done)
      |> Map.update(:payload, %{failed: reason}, &Map.put(&1, :failed, reason))
    end)
    |> to_tuple()
  end

  def event_to_node_mutation({:tool_hallucination, agent_id, attempted_tool}, state) do
    line = "Hallucinated tool: #{attempted_tool}"

    state
    |> update_existing_node(agent_id, fn data ->
      Map.update(data, :reasoning, [line], fn lines -> trim_reasoning(lines ++ [line]) end)
    end)
    |> to_tuple()
  end

  def event_to_node_mutation({:investigation_complete, _alert_id, profile, findings}, state)
      when is_map(findings) do
    state
    |> update_existing_node(investigator_agent_id(profile), fn data ->
      data
      |> Map.put(:status, :done)
      |> Map.update(:payload, %{findings: findings}, &Map.put(&1, :findings, findings))
    end)
    |> to_tuple()
  end

  def event_to_node_mutation({:investigation_failed, _alert_id, profile, reason}, state) do
    state
    |> update_existing_node(investigator_agent_id(profile), fn data ->
      data
      |> Map.put(:status, :done)
      |> Map.update(:payload, %{failed: reason}, &Map.put(&1, :failed, reason))
    end)
    |> to_tuple()
  end

  def event_to_node_mutation({:page_out_failed, agent_id, _alert_id, reason}, state) do
    state
    |> update_existing_node(agent_id, fn data ->
      data
      |> Map.put(:status, :done)
      |> Map.update(:payload, %{failed: reason}, &Map.put(&1, :failed, reason))
    end)
    |> to_tuple()
  end

  def event_to_node_mutation(_event, state) do
    state
    |> normalize_state()
    |> to_tuple()
  end

  @doc "Renders the LiveFlow tree and node cards."
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    laid_out_nodes = laid_out_nodes(assigns.node_data)

    assigns =
      assigns
      |> assign(:flow, flow_from_topology(assigns.topology, laid_out_nodes))
      |> assign(:flow_id, "#{assigns.id}-flow")

    ~H"""
    <section class="rounded-2xl border border-slate-700 bg-slate-950/70 p-6 shadow-2xl">
      <div class="flex items-center justify-between gap-4">
        <div class="text-xs font-bold uppercase tracking-[0.28em] text-slate-500">Agent tree</div>
        <span :if={@alert_id} class="font-mono text-xs text-slate-500">{@alert_id}</span>
      </div>

      <div
        :if={is_nil(@alert_id)}
        class="mt-8 rounded-2xl border border-dashed border-slate-700 bg-slate-900/50 p-10 text-center text-slate-400"
      >
        Agent tree — awaiting alert
      </div>

      <div
        :if={@alert_id && map_size(@node_data) == 0}
        class="mt-8 rounded-2xl border border-dashed border-cyan-900 bg-slate-900/50 p-10 text-center text-slate-400"
      >
        Agent tree — waiting for triager
      </div>

      <div
        :if={@alert_id && map_size(@node_data) > 0}
        class="mt-6 h-[34rem] overflow-hidden rounded-2xl border border-slate-800 bg-slate-900/40"
      >
        <.live_component
          module={LiveFlow.Components.Flow}
          id={@flow_id}
          flow={@flow}
          node_types={%{agent: AgentNode}}
          opts={
            %{
              background: :dots,
              controls: false,
              fit_view_on_init: true,
              default_edge_type: :smoothstep,
              nodes_draggable: false,
              nodes_connectable: false,
              elements_selectable: false,
              pan_on_drag: true,
              zoom_on_scroll: true
            }
          }
        />
      </div>
    </section>
    """
  end

  @spec empty_topology() :: topology()
  defp empty_topology, do: %{nodes: %{}, edges: []}

  @spec normalize_state(map()) :: %{topology: topology(), node_data: node_data()}
  defp normalize_state(state) do
    %{
      topology: Map.get(state, :topology, empty_topology()),
      node_data: Map.get(state, :node_data, %{})
    }
  end

  @spec add_node(map(), String.t(), atom(), keyword()) :: map()
  defp add_node(state, agent_id, role, opts) do
    projection = normalize_state(state)
    status = Keyword.get(opts, :status, :idle)
    payload = Keyword.get(opts, :payload, %{})

    node = %{id: agent_id, role: role}
    data = Map.merge(default_node_data(role, status), %{payload: payload})

    %{
      projection
      | topology: put_in(projection.topology, [:nodes, agent_id], node),
        node_data: Map.put(projection.node_data, agent_id, data)
    }
  end

  @spec add_edge(map(), String.t(), String.t()) :: map()
  defp add_edge(state, source, target) do
    projection = normalize_state(state)
    edge = %{source: source, target: target}

    edges =
      if edge in projection.topology.edges do
        projection.topology.edges
      else
        projection.topology.edges ++ [edge]
      end

    %{projection | topology: %{projection.topology | edges: edges}}
  end

  @spec maybe_add_parent_edge(map(), String.t(), String.t()) :: map()
  defp maybe_add_parent_edge(state, source, target) do
    projection = normalize_state(state)

    if Map.has_key?(projection.node_data, source) do
      add_edge(projection, source, target)
    else
      projection
    end
  end

  @spec update_existing_node(map(), String.t(), (map() -> map())) :: map()
  defp update_existing_node(state, agent_id, update_fun) do
    projection = normalize_state(state)

    if Map.has_key?(projection.node_data, agent_id) do
      %{projection | node_data: Map.update!(projection.node_data, agent_id, update_fun)}
    else
      projection
    end
  end

  @spec to_tuple(map()) :: {topology(), node_data()}
  defp to_tuple(state) do
    projection = normalize_state(state)
    {projection.topology, projection.node_data}
  end

  @spec investigator_agent_id(atom() | String.t()) :: String.t()
  defp investigator_agent_id(profile), do: "investigator-#{profile}-1"

  @spec default_node_data(atom(), atom()) :: map()
  defp default_node_data(role, status) do
    %{
      role: role,
      status: status,
      reasoning: [],
      tool_call: nil,
      elapsed_ms: nil,
      banner: nil,
      gate_id: nil,
      payload: %{}
    }
  end

  @spec trim_reasoning([String.t()]) :: [String.t()]
  defp trim_reasoning(lines), do: Enum.take(lines, -3)

  @spec maybe_append_line([String.t()], String.t() | nil) :: [String.t()]
  defp maybe_append_line(lines, nil), do: lines
  defp maybe_append_line(lines, line), do: trim_reasoning(lines ++ [line])

  @spec format_command(String.t() | atom(), [term()]) :: String.t()
  defp format_command(tool, args) do
    ([to_string(tool)] ++ Enum.map(args, &to_string/1))
    |> Enum.join(" ")
  end

  @spec remediator_command(map()) :: String.t()
  defp remediator_command(%{action: :rollout_undo, args: args}),
    do: format_command("kubectl", ["rollout", "undo" | args])

  defp remediator_command(%{action: :rollout_restart, args: args}),
    do: format_command("kubectl", ["rollout", "restart" | args])

  defp remediator_command(%{action: action, args: args}),
    do: format_command("kubectl", [action | args])

  defp remediator_command(_proposal), do: "kubectl"

  @spec laid_out_nodes(node_data()) :: [map()]
  defp laid_out_nodes(node_data) do
    node_data
    |> Enum.map(fn {id, data} -> %{id: id, data: data, level: level_for_role(data.role)} end)
    |> Enum.sort_by(fn node -> {node.level, node.id} end)
    |> Enum.with_index()
    |> Enum.map(fn {node, index} -> Map.put(node, :index, index) end)
  end

  @spec level_for_role(atom()) :: non_neg_integer()
  defp level_for_role(:triager), do: 0
  defp level_for_role(:investigator), do: 1
  defp level_for_role(:remediator), do: 1
  defp level_for_role(:escalator), do: 2
  defp level_for_role(_role), do: 2

  @spec flow_from_topology(topology(), [map()]) :: State.t()
  defp flow_from_topology(topology, laid_out_nodes) do
    State.new(
      nodes: Enum.map(laid_out_nodes, &flow_node/1),
      edges: Enum.map(topology.edges, &flow_edge/1)
    )
  end

  @spec flow_node(map()) :: Node.t()
  defp flow_node(node) do
    Node.new(node.id, flow_position(node), node.data,
      type: :agent,
      draggable: false,
      connectable: false,
      selectable: false,
      deletable: false,
      class: "agent-node-entry"
    )
  end

  @spec flow_position(map()) :: %{x: integer(), y: integer()}
  defp flow_position(%{level: level, index: index}) do
    %{x: 40 + level * 340, y: 70 + index * 130}
  end

  @spec flow_edge(edge()) :: Edge.t()
  defp flow_edge(%{source: source, target: target}) do
    Edge.new("#{source}->#{target}", source, target,
      type: :smoothstep,
      animated: true,
      selectable: false,
      deletable: false,
      style: %{"stroke" => "rgba(6, 182, 212, 0.65)", "stroke-width" => "2"}
    )
  end
end
