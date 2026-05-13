defmodule PagelessWeb.Components.AlertIntakeCard do
  @moduledoc "Renders the dashboard alert intake card for the latest alert envelope."

  use Phoenix.Component

  import PagelessWeb.Components.ConductorBadge

  alias Pageless.AlertEnvelope

  attr :envelope, AlertEnvelope, default: nil

  @doc "Renders either the latest alert or a quiet no-alert placeholder."
  @spec alert_intake_card(map()) :: Phoenix.LiveView.Rendered.t()
  def alert_intake_card(assigns) do
    render_envelope(assigns, assigns.envelope)
  end

  @spec render_envelope(map(), AlertEnvelope.t() | nil) :: Phoenix.LiveView.Rendered.t()
  defp render_envelope(assigns, nil) do
    ~H"""
    <section class="rounded-2xl border border-slate-800 bg-slate-950/80 p-6 text-slate-300 shadow-2xl">
      <div class="text-xs font-bold uppercase tracking-[0.28em] text-slate-500">Alert intake</div>
      <p class="mt-6 text-2xl font-semibold text-slate-100">No alert</p>
      <p class="mt-2 text-sm text-slate-500">Waiting for the next incident signal.</p>
    </section>
    """
  end

  defp render_envelope(assigns, %AlertEnvelope{} = envelope) do
    assigns = assign(assigns, :envelope, envelope)

    assigns =
      assigns
      |> assign(:severity, format_atom(assigns.envelope.severity))
      |> assign(:alert_class, format_atom(assigns.envelope.alert_class))
      |> assign(:source, Atom.to_string(assigns.envelope.source))
      |> assign(:received_at, format_time(assigns.envelope.received_at))

    ~H"""
    <section class="rounded-2xl border border-red-600 bg-red-950/80 p-6 text-red-50 shadow-2xl shadow-red-950/30">
      <div class="flex items-start justify-between gap-4">
        <div>
          <div class="text-xs font-bold uppercase tracking-[0.28em] text-red-300">Alert intake</div>
          <h2 class="mt-4 text-3xl font-black leading-tight">{@envelope.title}</h2>
        </div>
        <span class="rounded-full bg-red-500 px-3 py-1 text-sm font-black text-white">
          {@severity}
        </span>
      </div>

      <div class="mt-5 flex flex-wrap items-center gap-2 text-sm">
        <.conductor_badge beat={:b1} />
        <span class="rounded border border-red-500/50 px-2 py-1">{@alert_class}</span>
        <span class="rounded border border-red-500/50 px-2 py-1">{@source}</span>
        <span class="rounded border border-red-500/50 px-2 py-1">{@received_at}</span>
      </div>

      <dl class="mt-5 grid gap-3 text-sm sm:grid-cols-2">
        <div>
          <dt class="text-red-300">Service</dt>
          <dd class="font-semibold">{@envelope.service}</dd>
        </div>
        <div>
          <dt class="text-red-300">Fingerprint</dt>
          <dd class="font-mono text-xs">{@envelope.fingerprint}</dd>
        </div>
      </dl>
    </section>
    """
  end

  @spec format_atom(atom()) :: String.t()
  defp format_atom(value) do
    value
    |> Atom.to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  @spec format_time(DateTime.t()) :: String.t()
  defp format_time(%DateTime{} = value) do
    value
    |> DateTime.to_time()
    |> Time.truncate(:second)
    |> Time.to_string()
  end
end
