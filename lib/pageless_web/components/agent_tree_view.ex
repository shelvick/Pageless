defmodule PagelessWeb.Components.AgentTreeView do
  @moduledoc """
  Per-alert agent topology projection for the operator dashboard.

  The component receives agent PubSub events forwarded by the parent LiveView,
  mutates an in-memory topology map, and renders each node through
  `PagelessWeb.Components.AgentNode`. It uses an inline SVG/HTML fallback path
  rather than LiveFlow so the demo tree stays dependency-light and predictable.
  """

  use Phoenix.LiveComponent

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
    socket = assign(socket, Map.drop(assigns, [:event]))

    socket =
      if Map.has_key?(assigns, :alert_id) and assigns.alert_id != socket.assigns[:alert_id] do
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

  def event_to_node_mutation({:reasoning_line, agent_id, line}, state) do
    state
    |> update_existing_node(agent_id, fn data ->
      Map.update(data, :reasoning, [line], fn lines -> trim_reasoning(lines ++ [line]) end)
    end)
    |> to_tuple()
  end

  def event_to_node_mutation({:triager_reasoning, agent_id, line}, state) do
    event_to_node_mutation({:reasoning_line, agent_id, line}, state)
  end

  def event_to_node_mutation({:remediator_reasoning, agent_id, line}, state) do
    event_to_node_mutation({:reasoning_line, agent_id, line}, state)
  end

  def event_to_node_mutation({:escalator_reasoning, agent_id, line}, state) do
    event_to_node_mutation({:reasoning_line, agent_id, line}, state)
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

  def event_to_node_mutation(_event, state) do
    state
    |> normalize_state()
    |> to_tuple()
  end

  @doc "Renders the SVG-fallback tree and node cards."
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    assigns = assign(assigns, :laid_out_nodes, laid_out_nodes(assigns.node_data))

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
        class="relative mt-6 min-h-[28rem] overflow-hidden rounded-2xl border border-slate-800 bg-slate-900/40 p-4"
      >
        <svg
          class="pointer-events-none absolute inset-0 h-full w-full"
          viewBox="0 0 1000 520"
          preserveAspectRatio="none"
          aria-hidden="true"
        >
          <line
            :for={edge <- @topology.edges}
            x1={edge_x(@laid_out_nodes, edge.source)}
            y1={edge_y(@laid_out_nodes, edge.source)}
            x2={edge_x(@laid_out_nodes, edge.target)}
            y2={edge_y(@laid_out_nodes, edge.target)}
            class="stroke-cyan-500/50"
            stroke-width="2"
          />
        </svg>

        <div class="relative grid gap-5 lg:grid-cols-3">
          <div :for={level <- grouped_levels(@laid_out_nodes)} class="space-y-5">
            <.live_component
              :for={node <- level}
              module={AgentNode}
              id={node.id}
              role={node.data.role}
              data={node.data}
              beat={nil}
            />
          </div>
        </div>
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
  end

  @spec level_for_role(atom()) :: non_neg_integer()
  defp level_for_role(:triager), do: 0
  defp level_for_role(:investigator), do: 1
  defp level_for_role(:remediator), do: 1
  defp level_for_role(:escalator), do: 2
  defp level_for_role(_role), do: 2

  @spec grouped_levels([map()]) :: [[map()]]
  defp grouped_levels(nodes) do
    nodes
    |> Enum.group_by(& &1.level)
    |> Enum.sort_by(fn {level, _nodes} -> level end)
    |> Enum.map(fn {_level, nodes} -> nodes end)
  end

  @spec edge_x([map()], String.t()) :: integer()
  defp edge_x(nodes, id), do: coordinate(nodes, id, 120, 360, :level)

  @spec edge_y([map()], String.t()) :: integer()
  defp edge_y(nodes, id), do: coordinate(nodes, id, 80, 115, :index)

  @spec coordinate([map()], String.t(), integer(), integer(), :level | :index) :: integer()
  defp coordinate(nodes, id, base, step, axis) do
    nodes
    |> Enum.with_index()
    |> Enum.find_value(base, fn {node, index} ->
      if node.id == id do
        if axis == :level, do: base + node.level * step, else: base + index * step
      end
    end)
  end
end
