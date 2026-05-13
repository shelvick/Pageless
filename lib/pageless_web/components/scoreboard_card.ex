defmodule PagelessWeb.Components.ScoreboardCard do
  @moduledoc "Renders the dashboard scoreboard counters for the demo wrap-up beat."

  use Phoenix.Component

  import PagelessWeb.Components.ConductorBadge

  attr :stats, :map, default: nil

  @doc "Renders scoreboard counters, using em dashes for counters that are not available yet."
  @spec scoreboard_card(map()) :: Phoenix.LiveView.Rendered.t()
  def scoreboard_card(assigns) do
    assigns = assign(assigns, :rows, rows(assigns.stats || %{}))

    ~H"""
    <section class="rounded-2xl border border-cyan-700 bg-slate-950/90 p-6 text-slate-100 shadow-2xl shadow-cyan-950/30">
      <div class="flex items-center justify-between gap-4">
        <div class="text-xs font-bold uppercase tracking-[0.28em] text-cyan-300">Scoreboard</div>
        <.conductor_badge beat={:b7} />
      </div>

      <dl class="mt-5 grid gap-3 sm:grid-cols-2 lg:grid-cols-1 xl:grid-cols-2">
        <div
          :for={{label, value} <- @rows}
          class="rounded-xl border border-slate-800 bg-slate-900/70 p-4"
        >
          <dt class="text-sm text-slate-400">{label}</dt>
          <dd class="mt-1 text-3xl font-black text-white">{value}</dd>
        </div>
      </dl>
    </section>
    """
  end

  @spec rows(map()) :: [{String.t(), String.t()}]
  defp rows(stats) do
    [
      {"Time to resolution", Map.get(stats, :time_to_resolution, "—")},
      {"Agents spawned", Map.get(stats, :agents_spawned, "—")},
      {"Tool calls", Map.get(stats, :tool_calls, "—")},
      {"Operator decisions", Map.get(stats, :operator_decisions, "—")},
      {"Terminal commands", Map.get(stats, :terminal_commands, "—")}
    ]
    |> Enum.map(fn {label, value} -> {label, to_string(value)} end)
  end
end
