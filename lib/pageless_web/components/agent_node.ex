defmodule PagelessWeb.Components.AgentNode do
  @moduledoc """
  Per-agent visual node for the operator dashboard tree.

  The component receives all visible state from the parent tree and renders a
  role label, status cue, optional reasoning preview, optional tool call, and
  cap-class banner. It does not subscribe to PubSub or read persistent state.
  """

  use Phoenix.LiveComponent

  import PagelessWeb.Components.ConductorBadge

  @doc "Initializes transient animation assigns for the node."
  @spec mount(Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def mount(socket) do
    {:ok, assign(socket, entry_animated?: false, banner_anchored_at: nil)}
  end

  @doc "Stores the latest node rendering assigns."
  @spec update(map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def update(%{node: node} = assigns, socket) do
    assigns =
      assigns
      |> Map.delete(:node)
      |> Map.put(:id, node.id)
      |> Map.put(:role, node.data.role)
      |> Map.put(:data, node.data)
      |> Map.put_new(:beat, nil)

    update(assigns, socket)
  end

  def update(assigns, socket) do
    previous_banner = socket.assigns[:data] && Map.get(socket.assigns.data, :banner)
    incoming_banner = assigns[:data] && Map.get(assigns.data, :banner)

    socket =
      socket
      |> assign(assigns)
      |> assign(:entry_animated?, true)
      |> maybe_anchor_banner(previous_banner, incoming_banner)

    {:ok, socket}
  end

  @doc "Renders one agent node card."
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    assigns = prepare_assigns(assigns)

    ~H"""
    <article
      class={[
        "relative overflow-hidden rounded-2xl border bg-slate-950/90 p-4 text-left shadow-xl",
        @status_class
      ]}
      data-agent-id={@id}
    >
      <div
        :if={@banner_label}
        class={[
          "absolute inset-x-0 top-0 z-10 px-3 py-1 text-center text-xs font-black tracking-[0.24em] text-white",
          @banner_class
        ]}
      >
        {@banner_label}
      </div>

      <div class={if @banner_label, do: "pt-6", else: ""}>
        <div class="flex flex-wrap items-center justify-between gap-2">
          <div class="flex items-center gap-2">
            <span class={["h-2.5 w-2.5 rounded-full", @dot_class]}></span>
            <div>
              <h3 class="text-sm font-black uppercase tracking-[0.18em] text-slate-100">
                {@role_label}
              </h3>
              <p class="font-mono text-xs text-slate-500">{@id}</p>
            </div>
          </div>

          <div class="flex items-center gap-2">
            <span
              :if={@profile_label}
              class="rounded-full border border-cyan-500/50 px-2 py-0.5 text-xs font-bold text-cyan-200"
            >
              {@profile_label}
            </span>
            <.conductor_badge :if={@beat} beat={@beat} />
          </div>
        </div>

        <div :if={@show_details?} class="mt-4 space-y-3">
          <div :if={@reasoning != []} class="rounded-xl border border-slate-800 bg-slate-900/70 p-3">
            <div class="mb-2 text-xs font-bold uppercase tracking-[0.18em] text-slate-500">
              Reasoning
            </div>
            <p :for={line <- @reasoning} class="font-mono text-xs leading-relaxed text-slate-300">
              {line}
            </p>
          </div>

          <div :if={@tool_call} class={["rounded-xl border bg-slate-900/80 p-3", @tool_class]}>
            <div class="mb-2 flex items-center justify-between gap-2">
              <span class="text-xs font-bold uppercase tracking-[0.18em] text-slate-500">
                Tool call
              </span>
              <span
                :if={@classification_label}
                class={["rounded-full px-2 py-0.5 text-xs font-black", @classification_class]}
              >
                {@classification_label}
              </span>
            </div>
            <p class="font-mono text-xs leading-relaxed text-slate-100">{@tool_call.command}</p>
            <p :if={@tool_result_label} class="mt-2 text-xs text-slate-400">{@tool_result_label}</p>
          </div>

          <p :if={@elapsed_label} class="text-xs font-semibold text-slate-500">{@elapsed_label}</p>
        </div>
      </div>
    </article>
    """
  end

  @spec maybe_anchor_banner(Phoenix.LiveView.Socket.t(), atom() | nil, atom() | nil) ::
          Phoenix.LiveView.Socket.t()
  defp maybe_anchor_banner(socket, previous_banner, incoming_banner)
       when not is_nil(incoming_banner) and incoming_banner != previous_banner do
    assign(socket, :banner_anchored_at, DateTime.utc_now())
  end

  defp maybe_anchor_banner(socket, _previous_banner, _incoming_banner), do: socket

  @spec prepare_assigns(map()) :: map()
  defp prepare_assigns(assigns) do
    data = Map.get(assigns, :data, %{})
    status = Map.get(data, :status, :idle)
    tool_call = Map.get(data, :tool_call)
    banner = Map.get(data, :banner)

    assigns
    |> assign(:role_label, role_label(Map.get(assigns, :role, :agent)))
    |> assign(:reasoning, Map.get(data, :reasoning, []))
    |> assign(:tool_call, tool_call)
    |> assign(:profile_label, profile_label(Map.get(data, :payload, %{})))
    |> assign(:show_details?, status != :idle)
    |> assign(:status_class, status_class(status))
    |> assign(:dot_class, dot_class(status))
    |> assign(:banner_label, banner_label(banner))
    |> assign(:banner_class, banner_class(banner))
    |> assign(:classification_label, classification_label(tool_call))
    |> assign(:classification_class, classification_class(tool_call))
    |> assign(:tool_class, tool_class(tool_call))
    |> assign(:tool_result_label, tool_result_label(tool_call))
    |> assign(:elapsed_label, elapsed_label(Map.get(data, :elapsed_ms)))
  end

  @spec role_label(atom()) :: String.t()
  defp role_label(role) do
    role
    |> Atom.to_string()
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  @spec profile_label(map()) :: String.t() | nil
  defp profile_label(%{profile: profile}) when is_atom(profile), do: role_label(profile)
  defp profile_label(%{profile: profile}) when is_binary(profile), do: String.capitalize(profile)
  defp profile_label(_payload), do: nil

  @spec status_class(atom()) :: String.t()
  defp status_class(:thinking), do: "border-cyan-500 shadow-cyan-950/40"
  defp status_class(:tool_active), do: "border-amber-500 shadow-amber-950/30"
  defp status_class(:gated), do: "border-red-500 shadow-red-950/40"
  defp status_class(:escalated), do: "border-orange-500 shadow-orange-950/40"
  defp status_class(:auto_fired), do: "border-green-500 shadow-green-950/40"
  defp status_class(_status), do: "border-slate-700 shadow-slate-950/30"

  @spec dot_class(atom()) :: String.t()
  defp dot_class(:thinking), do: "animate-pulse bg-cyan-300"
  defp dot_class(:tool_active), do: "animate-pulse bg-amber-300"
  defp dot_class(:gated), do: "bg-red-400"
  defp dot_class(:escalated), do: "bg-orange-400"
  defp dot_class(:auto_fired), do: "bg-green-400"
  defp dot_class(:done), do: "bg-slate-500"
  defp dot_class(_status), do: "bg-slate-600"

  @spec banner_label(atom() | nil) :: String.t() | nil
  defp banner_label(:gated), do: "GATED"
  defp banner_label(:escalated), do: "ESCALATED"
  defp banner_label(:auto_fired), do: "AUTONOMOUS"
  defp banner_label(nil), do: nil
  defp banner_label(banner), do: banner |> Atom.to_string() |> String.upcase()

  @spec banner_class(atom() | nil) :: String.t()
  defp banner_class(:gated), do: "bg-red-600"
  defp banner_class(:escalated), do: "bg-orange-500"
  defp banner_class(:auto_fired), do: "bg-green-500"
  defp banner_class(_banner), do: "bg-slate-600"

  @spec classification_label(map() | nil) :: String.t() | nil
  defp classification_label(%{classification: classification}) when is_atom(classification) do
    classification |> Atom.to_string() |> String.upcase()
  end

  defp classification_label(_tool_call), do: nil

  @spec classification_class(map() | nil) :: String.t()
  defp classification_class(%{classification: :write_prod_high}), do: "bg-red-500 text-white"
  defp classification_class(%{classification: :write_prod_low}), do: "bg-orange-500 text-white"
  defp classification_class(%{classification: :write_dev}), do: "bg-amber-400 text-slate-950"
  defp classification_class(%{classification: :read}), do: "bg-green-500 text-white"
  defp classification_class(_tool_call), do: "bg-slate-700 text-slate-100"

  @spec tool_class(map() | nil) :: String.t()
  defp tool_class(%{classification: :write_prod_high}), do: "border-red-500"
  defp tool_class(%{classification: :write_prod_low}), do: "border-orange-500"
  defp tool_class(%{classification: :write_dev}), do: "border-amber-500"
  defp tool_class(%{classification: :read}), do: "border-green-600"
  defp tool_class(_tool_call), do: "border-slate-700"

  @spec tool_result_label(map() | nil) :: String.t() | nil
  defp tool_result_label(%{result: nil}), do: "pending"
  defp tool_result_label(%{result: {:ok, _result}}), do: "ok"
  defp tool_result_label(%{result: {:error, reason}}), do: "error: #{inspect(reason)}"
  defp tool_result_label(_tool_call), do: nil

  @spec elapsed_label(non_neg_integer() | nil) :: String.t() | nil
  defp elapsed_label(nil), do: nil
  defp elapsed_label(ms) when ms < 1_000, do: "#{ms}ms"
  defp elapsed_label(ms) when ms < 60_000, do: "#{Float.round(ms / 1_000, 1)}s"
  defp elapsed_label(ms), do: "#{div(ms, 60_000)}m #{div(rem(ms, 60_000), 1_000)}s"
end
