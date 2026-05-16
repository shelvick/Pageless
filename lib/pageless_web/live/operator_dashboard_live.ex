defmodule PagelessWeb.OperatorDashboardLive do
  @moduledoc "Operator dashboard LiveView that subscribes to alert and conductor PubSub events."

  use Phoenix.LiveView

  import PagelessWeb.Components.AlertIntakeCard
  import PagelessWeb.Components.ScoreboardCard

  alias Pageless.AlertEnvelope
  alias Pageless.AuditTrail
  alias PagelessWeb.Components.AgentTreeView
  alias PagelessWeb.Components.ApprovalModal

  @page_title "Pageless — Operator Dashboard"

  @doc "Mounts the dashboard and subscribes to the injected PubSub broker when connected."
  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def mount(_params, session, socket) do
    broker =
      Map.get(
        session,
        "pubsub_broker",
        Application.get_env(:pageless, :pubsub_broker, Pageless.PubSub)
      )

    if connected?(socket) do
      Process.flag(:max_heap_size, %{
        size: div(50_000_000, :erlang.system_info(:wordsize)),
        kill: true
      })

      :ok = Phoenix.PubSub.subscribe(broker, "alerts")
      :ok = Phoenix.PubSub.subscribe(broker, "conductor")
    end

    socket =
      assign(socket,
        page_title: @page_title,
        pubsub_broker: broker,
        repo: Map.get(session, "repo", AuditTrail),
        tool_dispatch: normalize_tool_dispatch(Map.get(session, "tool_dispatch")),
        operator_ref: Map.get(session, "operator_ref", "dashboard_session:" <> socket.id),
        envelope: nil,
        stats: nil,
        current_beat: nil,
        gate_envelope: nil,
        alert_topic: nil,
        tree_event: nil
      )

    {:ok, socket}
  end

  @doc "Updates dashboard assigns from PubSub messages."
  @spec handle_info(term(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_info(message, socket) do
    {:noreply, apply_dashboard_event(socket, message)}
  end

  @doc """
  Absorbs LiveFlow JS hook callbacks bubbled up from the nested flow.

  `LiveFlow.Components.Flow`'s client hook uses `pushEvent` (not `pushEventTo`),
  so events like `lf:node_change` reach this LiveView even though the tree is
  read-only here. Any `lf:` event is dropped to keep the LiveView alive.
  """
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event("lf:" <> _rest, _params, socket), do: {:noreply, socket}

  @spec apply_dashboard_event(Phoenix.LiveView.Socket.t(), term()) :: Phoenix.LiveView.Socket.t()
  defp apply_dashboard_event(socket, {:alert_received, %AlertEnvelope{} = envelope}) do
    topic = "alert:#{envelope.alert_id}"

    if connected?(socket) and socket.assigns.alert_topic != topic do
      if socket.assigns.alert_topic do
        :ok = Phoenix.PubSub.unsubscribe(socket.assigns.pubsub_broker, socket.assigns.alert_topic)
      end

      :ok = Phoenix.PubSub.subscribe(socket.assigns.pubsub_broker, topic)
    end

    assign(socket,
      envelope: envelope,
      alert_topic: topic,
      gate_envelope: nil,
      tree_event: nil
    )
  end

  defp apply_dashboard_event(
         socket,
         {:gate_fired, gate_id, tool_call, classification, verb, reasoning_context}
       ) do
    if current_alert_event?(socket, tool_call) do
      assign(socket,
        gate_envelope: %{
          gate_id: gate_id,
          tool_call: tool_call,
          classification: classification,
          verb: verb,
          reasoning_context: reasoning_context || %{}
        }
      )
    else
      socket
    end
  end

  defp apply_dashboard_event(socket, {:gate_result, gate_id, _result}) do
    gate_id
    |> matching_gate?(socket)
    |> maybe_clear_gate(socket)
  end

  defp apply_dashboard_event(socket, message)
       when is_tuple(message) and tuple_size(message) >= 3 and elem(message, 0) == :gate_decision do
    message
    |> current_gate_decision?(socket)
    |> maybe_clear_gate(socket)
  end

  defp apply_dashboard_event(socket, {:conductor_beat, :b7, :conductor, stats})
       when is_map(stats) do
    assign(socket, :stats, stats)
  end

  defp apply_dashboard_event(socket, {:conductor_beat, beat, :conductor})
       when beat in [:b2, :b8] do
    assign(socket, :current_beat, beat)
  end

  defp apply_dashboard_event(socket, message) when is_tuple(message) do
    if agent_event?(message) and current_alert_event?(socket, message) do
      assign(socket, :tree_event, message)
    else
      socket
    end
  end

  defp apply_dashboard_event(socket, _message), do: socket

  @spec agent_event?(tuple()) :: boolean()
  defp agent_event?(message) do
    message
    |> elem(0)
    |> agent_event_name?()
  end

  @spec agent_event_name?(atom()) :: boolean()
  defp agent_event_name?(name)
       when name in [
              :reasoning_line,
              :tool_call,
              :tool_error,
              :tool_hallucination,
              :investigation_complete,
              :investigation_failed,
              :page_out_sent,
              :page_out_failed
            ],
       do: true

  defp agent_event_name?(name) do
    name
    |> Atom.to_string()
    |> String.starts_with?(["triager_", "investigator_", "remediator_", "escalator_"])
  end

  @spec current_alert_event?(Phoenix.LiveView.Socket.t(), term()) :: boolean()
  defp current_alert_event?(socket, event) do
    case {current_alert_id(socket), event_alert_id(event)} do
      {alert_id, alert_id} when is_binary(alert_id) -> true
      {_current, _event} -> false
    end
  end

  @spec current_alert_id(Phoenix.LiveView.Socket.t()) :: String.t() | nil
  defp current_alert_id(socket), do: socket.assigns.envelope && socket.assigns.envelope.alert_id

  @spec event_alert_id(term()) :: String.t() | nil
  defp event_alert_id(%{alert_id: alert_id}), do: binary_alert_id(alert_id)

  defp event_alert_id({:reasoning_line, _agent_id, alert_id, _line}),
    do: binary_alert_id(alert_id)

  defp event_alert_id({:tool_call, _agent_id, alert_id, _tool, _args, _result, _classification}),
    do: binary_alert_id(alert_id)

  defp event_alert_id({:triager_spawned, _agent_id, alert_id}), do: binary_alert_id(alert_id)

  defp event_alert_id({:triager_reasoning, _agent_id, alert_id, _line}),
    do: binary_alert_id(alert_id)

  defp event_alert_id({:triager_dispatched, _agent_id, alert_id, _investigators}),
    do: binary_alert_id(alert_id)

  defp event_alert_id({:triager_classified, _agent_id, alert_id, _classification}),
    do: binary_alert_id(alert_id)

  defp event_alert_id({:triager_failed, _agent_id, alert_id, _reason}),
    do: binary_alert_id(alert_id)

  defp event_alert_id({:investigator_spawned, alert_id, _profile, _pid}),
    do: binary_alert_id(alert_id)

  defp event_alert_id({:investigation_complete, alert_id, _profile, _findings}),
    do: binary_alert_id(alert_id)

  defp event_alert_id({:investigation_failed, alert_id, _profile, _reason}),
    do: binary_alert_id(alert_id)

  defp event_alert_id({:remediator_spawned, _agent_id, alert_id}), do: binary_alert_id(alert_id)

  defp event_alert_id({:remediator_reasoning, _agent_id, alert_id, _line}),
    do: binary_alert_id(alert_id)

  defp event_alert_id({:remediator_action_proposed, _agent_id, alert_id, _proposal}),
    do: binary_alert_id(alert_id)

  defp event_alert_id({:remediator_action_executed, _agent_id, alert_id, _result}),
    do: binary_alert_id(alert_id)

  defp event_alert_id({:remediator_action_failed, _agent_id, alert_id, _failure}),
    do: binary_alert_id(alert_id)

  defp event_alert_id({:remediator_escalating, _agent_id, alert_id, _pid, _reason}),
    do: binary_alert_id(alert_id)

  defp event_alert_id({:escalator_spawned, _agent_id, alert_id}), do: binary_alert_id(alert_id)

  defp event_alert_id({:escalator_reasoning, _agent_id, alert_id, _line}),
    do: binary_alert_id(alert_id)

  defp event_alert_id({:page_out_sent, _agent_id, alert_id, _payload}),
    do: binary_alert_id(alert_id)

  defp event_alert_id({:page_out_failed, _agent_id, alert_id, _reason}),
    do: binary_alert_id(alert_id)

  defp event_alert_id(_event), do: nil

  @spec binary_alert_id(term()) :: String.t() | nil
  defp binary_alert_id(alert_id) when is_binary(alert_id), do: alert_id
  defp binary_alert_id(_alert_id), do: nil

  @spec current_gate_decision?(tuple(), Phoenix.LiveView.Socket.t()) :: boolean()
  defp current_gate_decision?(message, socket) do
    current_alert_event?(socket, message) or
      message
      |> tuple_gate_id()
      |> matching_gate?(socket)
  end

  @spec tuple_gate_id(tuple()) :: String.t() | nil
  defp tuple_gate_id(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.find(&gate_id?/1)
  end

  @spec gate_id?(term()) :: boolean()
  defp gate_id?(value), do: is_binary(value) and String.starts_with?(value, "gate_")

  @spec matching_gate?(String.t() | nil, Phoenix.LiveView.Socket.t()) :: boolean()
  defp matching_gate?(gate_id, %{assigns: %{gate_envelope: %{gate_id: gate_id}}})
       when is_binary(gate_id),
       do: true

  defp matching_gate?(_gate_id, _socket), do: false

  @spec maybe_clear_gate(boolean(), Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp maybe_clear_gate(true, socket), do: assign(socket, :gate_envelope, nil)
  defp maybe_clear_gate(false, socket), do: socket

  @spec normalize_tool_dispatch(term()) :: (term() -> {:ok, term()} | {:error, term()})
  defp normalize_tool_dispatch({module, function, extra_args})
       when is_atom(module) and is_atom(function) and is_list(extra_args) do
    fn tool_call -> apply(module, function, extra_args ++ [tool_call]) end
  end

  defp normalize_tool_dispatch(dispatch) when is_function(dispatch, 1), do: dispatch

  defp normalize_tool_dispatch(_dispatch),
    do: fn _tool_call -> {:error, :tool_not_implemented} end

  @doc "Renders the dashboard shell."
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-[radial-gradient(circle_at_top_left,#7f1d1d,transparent_35%),linear-gradient(135deg,#020617,#0f172a_55%,#082f49)] px-4 py-6 text-white sm:px-8">
      <div class="mx-auto max-w-7xl">
        <header class="mb-6 flex flex-col gap-2 border-b border-white/10 pb-5">
          <p class="text-xs font-black uppercase tracking-[0.35em] text-cyan-300">Pageless</p>
          <h1 class="text-4xl font-black tracking-tight sm:text-6xl">{@page_title}</h1>
        </header>

        <.live_component
          module={ApprovalModal}
          id="approval-modal"
          gate_envelope={@gate_envelope}
          pubsub={@pubsub_broker}
          repo={@repo}
          tool_dispatch={@tool_dispatch}
          operator_ref={@operator_ref}
        />

        <div class="grid gap-5 lg:grid-cols-[1fr_1.2fr_0.9fr]">
          <.alert_intake_card envelope={@envelope} />

          <.live_component
            module={AgentTreeView}
            id="agent-tree"
            alert_id={@envelope && @envelope.alert_id}
            pubsub={@pubsub_broker}
            event={@tree_event}
          />

          <.scoreboard_card stats={@stats} />
        </div>
      </div>
    </div>
    """
  end
end
