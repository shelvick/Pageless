defmodule PagelessWeb.Components.ApprovalModal do
  @moduledoc "Operator approval modal for gated capability decisions."

  use Phoenix.LiveComponent

  alias Pageless.Governance.CapabilityGate
  alias Pageless.Governance.ToolCall

  @type gate_envelope :: %{
          gate_id: String.t(),
          tool_call: ToolCall.t(),
          classification: atom(),
          verb: String.t() | nil,
          reasoning_context: map()
        }

  @doc "Initializes the modal with no in-flight approval or denial request."
  @spec mount(Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def mount(socket) do
    {:ok, assign(socket, :in_flight, false)}
  end

  @doc "Merges parent assigns and resets button state when the visible gate changes."
  @spec update(map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def update(assigns, socket) do
    previous_gate = Map.get(socket.assigns, :gate_envelope)
    next_gate = Map.get(assigns, :gate_envelope, previous_gate)

    socket =
      socket
      |> assign(assigns)
      |> maybe_reset_in_flight(previous_gate, next_gate)

    {:ok, socket}
  end

  @doc "Dispatches approval or denial requests asynchronously through the capability gate."
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event("approve", _params, socket) do
    %{gate_envelope: %{gate_id: gate_id}} = socket.assigns

    start_gate_task(socket, fn opts, operator_ref ->
      CapabilityGate.approve(gate_id, operator_ref, opts)
    end)

    {:noreply, assign(socket, :in_flight, true)}
  end

  def handle_event("deny", _params, socket) do
    %{gate_envelope: %{gate_id: gate_id}} = socket.assigns

    start_gate_task(socket, fn opts, operator_ref ->
      CapabilityGate.deny(gate_id, operator_ref, "denied via dashboard", opts)
    end)

    {:noreply, assign(socket, :in_flight, true)}
  end

  @doc "Renders the modal overlay when a gate is pending."
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <div id={@id}>
      <div
        :if={@gate_envelope}
        class="fixed inset-0 z-50 flex items-center justify-center bg-black/70 px-4 py-8 text-white backdrop-blur-sm"
      >
        <section class="w-full max-w-2xl rounded-3xl border border-red-400/70 bg-slate-950 p-6 shadow-2xl shadow-red-950/50 sm:p-8">
          <div class="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
            <div>
              <p class="text-xs font-black uppercase tracking-[0.35em] text-red-300">
                Capability gate
              </p>
              <h2 class="mt-3 text-3xl font-black tracking-tight">Operator approval required</h2>
            </div>
            <span class="rounded-full border border-red-300/70 bg-red-500/20 px-3 py-1 text-sm font-black text-red-100">
              {inspect(@gate_envelope.classification)}
            </span>
          </div>

          <div class="mt-6 rounded-2xl border border-slate-700 bg-black/60 p-4 font-mono text-sm text-cyan-100">
            {command_text(@gate_envelope.tool_call)}
          </div>

          <p class="mt-5 text-sm leading-6 text-slate-200">
            verb
            <code class="rounded bg-slate-800 px-1 py-0.5 text-cyan-200">{@gate_envelope.verb}</code>
            classifies as
            <code class="rounded bg-slate-800 px-1 py-0.5 text-red-200">
              {inspect(@gate_envelope.classification)}
            </code>
            — operator approval required.
          </p>

          <div class="mt-5 rounded-2xl border border-slate-800 bg-slate-900/80 p-4">
            <h3 class="text-sm font-bold uppercase tracking-[0.24em] text-slate-400">
              Reasoning context
            </h3>
            <p class="mt-3 text-slate-100">{reasoning_summary(@gate_envelope.reasoning_context)}</p>
            <a
              :if={evidence_link(@gate_envelope.reasoning_context)}
              href={evidence_link(@gate_envelope.reasoning_context)}
              class="mt-3 inline-flex text-sm font-bold text-cyan-300 underline-offset-4 hover:underline"
            >
              Evidence trail
            </a>
          </div>

          <div class="mt-7 flex flex-col-reverse gap-3 sm:flex-row sm:justify-end">
            <button
              type="button"
              phx-click="deny"
              phx-target={@myself}
              disabled={@in_flight}
              class="rounded-xl border border-slate-600 px-5 py-3 font-black text-slate-100 disabled:cursor-not-allowed disabled:opacity-50"
            >
              Deny
            </button>
            <button
              type="button"
              phx-click="approve"
              phx-target={@myself}
              disabled={@in_flight}
              class="rounded-xl bg-emerald-400 px-5 py-3 font-black text-emerald-950 shadow-lg shadow-emerald-950/40 disabled:cursor-not-allowed disabled:opacity-50"
            >
              Approve
            </button>
          </div>
        </section>
      </div>
    </div>
    """
  end

  @spec maybe_reset_in_flight(
          Phoenix.LiveView.Socket.t(),
          gate_envelope() | nil,
          gate_envelope() | nil
        ) ::
          Phoenix.LiveView.Socket.t()
  defp maybe_reset_in_flight(socket, previous_gate, next_gate) when previous_gate != next_gate do
    assign(socket, :in_flight, false)
  end

  defp maybe_reset_in_flight(socket, _previous_gate, _next_gate), do: socket

  @spec start_gate_task(Phoenix.LiveView.Socket.t(), (keyword(), String.t() -> term())) ::
          {:ok, pid()} | {:error, term()}
  defp start_gate_task(socket, gate_fun) do
    %{operator_ref: operator_ref} = socket.assigns
    caller = self()
    opts = gate_opts(socket.assigns, caller)

    Task.Supervisor.start_child(Pageless.TaskSupervisor, fn -> gate_fun.(opts, operator_ref) end)
  end

  @spec gate_opts(map(), pid()) :: keyword()
  defp gate_opts(assigns, reply_to) do
    [
      repo: assigns.repo,
      pubsub: assigns.pubsub,
      tool_dispatch: assigns.tool_dispatch,
      reply_to: reply_to
    ]
  end

  @spec command_text(ToolCall.t()) :: String.t()
  defp command_text(%ToolCall{tool: tool, args: args}) when is_list(args) do
    [Atom.to_string(tool) | Enum.map(args, &to_string/1)]
    |> Enum.join(" ")
  end

  defp command_text(%ToolCall{tool: tool, args: args}), do: "#{tool} #{inspect(args)}"

  @spec reasoning_summary(map()) :: String.t()
  defp reasoning_summary(%{summary: summary}) when is_binary(summary), do: summary
  defp reasoning_summary(%{"summary" => summary}) when is_binary(summary), do: summary
  defp reasoning_summary(_context), do: "No reasoning summary provided."

  @spec evidence_link(map()) :: String.t() | nil
  defp evidence_link(%{evidence_link: link}) when is_binary(link), do: link
  defp evidence_link(%{"evidence_link" => link}) when is_binary(link), do: link
  defp evidence_link(_context), do: nil
end
