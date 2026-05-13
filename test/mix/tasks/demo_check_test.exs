defmodule Mix.Tasks.Demo.CheckTest do
  @moduledoc """
  Tests the pure decision and table-rendering logic behind mix demo.check.
  """

  use ExUnit.Case, async: true

  alias Mix.Tasks.Demo.Check

  @beats [:b1, :b2, :b3, :b4, :b5, :b6, :b7, :b8]
  @production_modes %{
    b1: :conductor,
    b2: :conductor,
    b3: :real,
    b4: :real,
    b5: :real,
    b6: :real,
    b7: :conductor,
    b8: :conductor
  }

  describe "check/2" do
    test "permits recording when every must-be-real beat is real" do
      result = Check.check(@beats, &Map.fetch!(@production_modes, &1))

      assert result.exit_code == 0
      assert result.failing_beats == []
      assert result.message == "All must-be-real beats are :real. Recording permitted."
    end

    test "blocks recording when a must-be-real beat is conductor-driven" do
      modes = %{@production_modes | b3: :conductor}

      result = Check.check(@beats, &Map.fetch!(modes, &1))

      assert result.exit_code == 1
      assert result.failing_beats == [:b3]
      assert result.message =~ "Cannot record"
      assert result.message =~ "B3"
    end

    test "names every failing must-be-real beat" do
      modes = %{@production_modes | b3: :conductor, b5: :conductor}

      result = Check.check(@beats, &Map.fetch!(modes, &1))

      assert result.exit_code == 1
      assert result.failing_beats == [:b3, :b5]
      assert result.message =~ "B3"
      assert result.message =~ "B5"
    end

    test "ignores conductor-mode stagecraft beats when deciding exit code" do
      result = Check.check(@beats, &Map.fetch!(@production_modes, &1))

      stagecraft_rows = Enum.filter(result.rows, &(&1.must_be_real? == false))

      assert Enum.map(stagecraft_rows, & &1.beat) == [:b1, :b2, :b7, :b8]
      assert Enum.all?(stagecraft_rows, &(&1.verdict == :skip))
      assert result.exit_code == 0
    end
  end

  describe "render_table/1" do
    test "renders one row per beat with mode, must-be-real flag, and verdict" do
      result = Check.check(@beats, &Map.fetch!(@production_modes, &1))
      table = Check.render_table(result.rows)

      assert table =~ "Beat"
      assert table =~ "Mode"
      assert table =~ "Must-be-real?"
      assert table =~ "Verdict"

      for beat <- @beats do
        assert table =~ String.upcase(to_string(beat))
      end

      assert table =~ ":real"
      assert table =~ ":conductor"
      assert table =~ "OK"
      assert table =~ "-"
    end
  end

  describe "run/1" do
    test "uses the same pure production decision regardless of args" do
      # Day 1: live registry returns :conductor for every beat, so the
      # production decision must FAIL — B3-B6 are policy must-be-real but
      # nothing is wired up yet. This will only flip to exit 0 once every
      # must-be-real beat's implementation has landed and its
      # `do_beat_mode/1` clause has been promoted to `:real`.
      result = Check.decision_for_args(["anything", "else"])

      assert result.exit_code == 1
      assert result.failing_beats == [:b3, :b4, :b5, :b6]
    end
  end
end
