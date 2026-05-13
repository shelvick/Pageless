defmodule Pageless.Conductor.BeatModeRegistryTest do
  @moduledoc """
  Tests the locked pure beat-mode table used by conductor drift-prevention.
  """

  use ExUnit.Case, async: true

  alias Pageless.Conductor.BeatModeRegistry

  # Live state — Day 1, nothing wired up yet. Each entry flips to `:real`
  # as its corresponding implementation lands.
  @expected_live_modes %{
    b1: :conductor,
    b2: :conductor,
    b3: :conductor,
    b4: :conductor,
    b5: :conductor,
    b6: :conductor,
    b7: :conductor,
    b8: :conductor
  }

  # Locked PAGELESS.md policy — independent of live state.
  @expected_must_be_real %{
    b1: false,
    b2: false,
    b3: true,
    b4: true,
    b5: true,
    b6: true,
    b7: false,
    b8: false
  }

  describe "beat table" do
    test "returns the locked beat order" do
      assert BeatModeRegistry.beats() == [:b1, :b2, :b3, :b4, :b5, :b6, :b7, :b8]
    end

    test "reports live mode per beat (Day 1: every beat is :conductor)" do
      for {beat, mode} <- @expected_live_modes do
        assert BeatModeRegistry.beat_mode(beat) == mode
      end
    end

    test "raises FunctionClauseError for unknown beats" do
      assert_raise FunctionClauseError, fn ->
        BeatModeRegistry.beat_mode(:b9)
      end
    end
  end

  describe "must-be-real policy (independent of live state)" do
    test "matches the locked PAGELESS.md must-be-real beat table" do
      for {beat, expected} <- @expected_must_be_real do
        assert BeatModeRegistry.must_be_real?(beat) == expected
      end
    end

    test "returns the ordered must-be-real subset" do
      assert BeatModeRegistry.must_be_real_beats() == [:b3, :b4, :b5, :b6]
    end

    test "propagates FunctionClauseError for unknown beats" do
      assert_raise FunctionClauseError, fn ->
        BeatModeRegistry.must_be_real?(:bx)
      end
    end

    test "policy is independent of live state — must_be_real? does not call beat_mode" do
      # Critical invariant: the gate must report FAIL on Day 1 because
      # B3-B6 are policy-must-be-real but the live state for all beats is
      # :conductor. If must_be_real?/1 were derived from beat_mode/1, no
      # beat would ever be must-be-real until its live state flipped, and
      # the gate would be tautologically green from Day 1.
      assert BeatModeRegistry.must_be_real?(:b3) == true
      assert BeatModeRegistry.beat_mode(:b3) == :conductor
    end
  end
end
