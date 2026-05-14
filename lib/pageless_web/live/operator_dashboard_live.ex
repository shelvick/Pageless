defmodule PagelessWeb.OperatorDashboardLive do
  @moduledoc "Operator dashboard LiveView that subscribes to alert and conductor PubSub events."

  use Phoenix.LiveView

  import PagelessWeb.Components.AlertIntakeCard
  import PagelessWeb.Components.ScoreboardCard

  alias Pageless.AlertEnvelope
  alias Pageless.AuditTrail
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
      :ok = Phoenix.PubSub.subscribe(broker, "alerts")
      :ok = Phoenix.PubSub.subscribe(broker, "conductor")
    end

    socket =
      assign(socket,
        page_title: @page_title,
        pubsub_broker: broker,
        repo: Map.get(session, "repo", AuditTrail),
        tool_dispatch: normalize_tool_dispatch(Map.get(session, "tool_dispatch")),
        operator_ref: Map.get(session, "operator_ref", "operator:demo"),
        envelope: nil,
        stats: nil,
        current_beat: nil,
        gate_envelope: nil,
        alert_topic: nil
      )

    {:ok, socket}
  end

  @doc "Updates dashboard assigns from PubSub messages."
  @spec handle_info(term(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_info(message, socket) do
    {:noreply, apply_dashboard_event(socket, message)}
  end

  @spec apply_dashboard_event(Phoenix.LiveView.Socket.t(), term()) :: Phoenix.LiveView.Socket.t()
  defp apply_dashboard_event(socket, {:alert_received, %AlertEnvelope{} = envelope}) do
    topic = "alert:#{envelope.alert_id}"

    if connected?(socket) and socket.assigns.alert_topic != topic do
      :ok = Phoenix.PubSub.subscribe(socket.assigns.pubsub_broker, topic)
    end

    assign(socket, envelope: envelope, alert_topic: topic)
  end

  defp apply_dashboard_event(
         socket,
         {:gate_fired, gate_id, tool_call, classification, verb, reasoning_context}
       ) do
    assign(socket,
      gate_envelope: %{
        gate_id: gate_id,
        tool_call: tool_call,
        classification: classification,
        verb: verb,
        reasoning_context: reasoning_context || %{}
      }
    )
  end

  defp apply_dashboard_event(socket, {:gate_result, _gate_id, _result}) do
    assign(socket, :gate_envelope, nil)
  end

  defp apply_dashboard_event(socket, message)
       when is_tuple(message) and tuple_size(message) >= 3 and elem(message, 0) == :gate_decision do
    assign(socket, :gate_envelope, nil)
  end

  defp apply_dashboard_event(socket, {:conductor_beat, :b7, :conductor, stats})
       when is_map(stats) do
    assign(socket, :stats, stats)
  end

  defp apply_dashboard_event(socket, {:conductor_beat, beat, :conductor})
       when beat in [:b2, :b8] do
    assign(socket, :current_beat, beat)
  end

  defp apply_dashboard_event(socket, _message), do: socket

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

          <section class="rounded-2xl border border-slate-700 bg-slate-950/70 p-6 shadow-2xl">
            <div class="text-xs font-bold uppercase tracking-[0.28em] text-slate-500">Agent tree</div>
            <div class="mt-8 rounded-2xl border border-dashed border-slate-700 bg-slate-900/50 p-10 text-center text-slate-400">
              Agent tree — landing in a later Change Set
            </div>
          </section>

          <.scoreboard_card stats={@stats} />
        </div>
      </div>
    </div>
    """
  end
end
