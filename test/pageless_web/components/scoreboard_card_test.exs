defmodule PagelessWeb.Components.ScoreboardCardTest do
  @moduledoc "Tests for the dashboard scoreboard card component."

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias PagelessWeb.Components.ScoreboardCard

  describe "scoreboard_card/1" do
    test "renders placeholder counters when stats are nil" do
      html = render_component(&ScoreboardCard.scoreboard_card/1, stats: nil)

      assert html =~ "Time to resolution"
      assert html =~ "Agents spawned"
      assert html =~ "Tool calls"
      assert html =~ "Operator decisions"
      assert html =~ "Terminal commands"
      assert html =~ "—"
      assert html =~ "[CONDUCTOR]"
    end

    test "renders locked PAGELESS scoreboard stats" do
      html = render_component(&ScoreboardCard.scoreboard_card/1, stats: locked_scoreboard_stats())

      assert html =~ "1m 28s"
      assert html =~ "5"
      assert html =~ "9"
      assert html =~ "1"
      assert html =~ "0"
      assert html =~ "[CONDUCTOR]"
    end

    test "renders supplied values and placeholders for missing counters" do
      html =
        render_component(&ScoreboardCard.scoreboard_card/1,
          stats: %{time_to_resolution: "1m 28s"}
        )

      assert html =~ "1m 28s"
      assert html =~ "—"
      assert html =~ "[CONDUCTOR]"
    end
  end

  defp locked_scoreboard_stats do
    %{
      time_to_resolution: "1m 28s",
      agents_spawned: 5,
      tool_calls: 9,
      operator_decisions: 1,
      terminal_commands: 0
    }
  end
end
