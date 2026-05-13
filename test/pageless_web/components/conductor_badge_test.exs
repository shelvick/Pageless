defmodule PagelessWeb.Components.ConductorBadgeTest do
  @moduledoc """
  Tests conductor badge rendering for stagecraft and real demo beats.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Pageless.Conductor.BeatModeRegistry
  alias PagelessWeb.Components.ConductorBadge

  describe "conductor_badge/1" do
    test "renders the visible conductor stencil for B1" do
      html = render_component(&ConductorBadge.conductor_badge/1, beat: :b1)

      assert html =~ "[CONDUCTOR]"
      assert html =~ "bg-yellow-"
    end

    test "renders the [CONDUCTOR] stencil for every :conductor beat" do
      # Day 1 truth: every beat in the registry currently reports :conductor
      # (no agent implementations are wired up yet), so the badge must
      # render for all eight beats. As `do_beat_mode/1` clauses flip from
      # :conductor to :real, this test will fail loudly on those flipped
      # beats — which is the signal to broaden the test to cover the
      # empty-render branch (or split into two filtered loops).
      for beat <- BeatModeRegistry.beats() do
        mode = BeatModeRegistry.beat_mode(beat)

        assert mode == :conductor,
               "Day-1 invariant broken: beat_mode(#{inspect(beat)}) is #{inspect(mode)}. " <>
                 "Update this test to cover the :real branch before flipping registry clauses."

        html = render_component(&ConductorBadge.conductor_badge/1, beat: beat)

        assert html =~ "[CONDUCTOR]", "expected badge for #{inspect(beat)}"
        assert html =~ "bg-yellow-", "expected yellow styling for #{inspect(beat)}"
      end
    end

    test "propagates FunctionClauseError for out-of-range beats" do
      assert_raise FunctionClauseError, fn ->
        render_component(&ConductorBadge.conductor_badge/1, beat: :b9)
      end
    end
  end
end
