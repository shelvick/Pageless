defmodule PagelessWeb.Components.ConductorBadge do
  @moduledoc """
  Visible `[CONDUCTOR]` badge stencil for drift-prevention layer 2.

  Renders a loud yellow pill for any `:conductor`-mode beat per
  `Pageless.Conductor.BeatModeRegistry`; renders empty markup for `:real`-mode
  beats. Stateless function component.
  """

  use Phoenix.Component

  alias Pageless.Conductor.BeatModeRegistry

  attr :beat, :atom,
    required: true,
    values: [:b1, :b2, :b3, :b4, :b5, :b6, :b7, :b8]

  @doc "Renders the conductor badge for conductor-mode beats and nothing for real beats."
  @spec conductor_badge(map()) :: Phoenix.LiveView.Rendered.t()
  def conductor_badge(assigns) do
    assigns = assign(assigns, :mode, BeatModeRegistry.beat_mode(assigns.beat))

    ~H"""
    <span
      :if={@mode == :conductor}
      class="inline-flex items-center rounded border border-yellow-600 bg-yellow-400 px-2 py-0.5 text-xs font-bold uppercase tracking-wider text-yellow-900"
    >
      [CONDUCTOR]
    </span>
    """
  end
end
