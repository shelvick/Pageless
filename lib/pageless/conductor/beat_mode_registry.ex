defmodule Pageless.Conductor.BeatModeRegistry do
  @moduledoc """
  Single source of truth for demo beat classification.

  Two independent classifiers:

    * `must_be_real?/1` — the locked PAGELESS.md policy (which beats MUST be
      backed by real infrastructure to permit recording). Static.
    * `beat_mode/1` — the live state (which beats are CURRENTLY wired up to
      real infrastructure vs. still driven by the demo conductor). Hand-flipped
      from `:conductor` to `:real` as each implementation lands.

  Decoupling matters: collapsing both into one function makes
  `mix demo.check` tautologically green from Day 1, even when no real agents
  exist. With them separate, the gate correctly fails until each must-be-real
  beat's implementation flips its `do_beat_mode/1` clause to `:real`.

  Pure module; no GenServer, ETS, I/O, or application config.
  """

  @type beat :: :b1 | :b2 | :b3 | :b4 | :b5 | :b6 | :b7 | :b8
  @type mode :: :conductor | :real

  @doc "Returns the locked demo beat order."
  @spec beats() :: [beat()]
  def beats, do: [:b1, :b2, :b3, :b4, :b5, :b6, :b7, :b8]

  @doc """
  Returns the live mode for a demo beat: `:conductor` if still driven by the
  demo conductor, `:real` if the corresponding implementation is wired up.

  Flipped from `:conductor` to `:real` clause-by-clause as each must-be-real
  beat's implementation lands (triager → B3, investigators → B4, etc.).
  """
  @spec beat_mode(atom()) :: mode()
  def beat_mode(beat) when is_atom(beat), do: do_beat_mode(beat)

  @doc """
  Returns true when the beat must be backed by real infrastructure to record.

  Encodes the locked PAGELESS.md must-be-real beat table. Independent of
  `beat_mode/1` — a `true` here against a `:conductor` `beat_mode/1` is
  precisely the failure mode `mix demo.check` is designed to detect.
  """
  @spec must_be_real?(atom()) :: boolean()
  def must_be_real?(beat) when is_atom(beat), do: do_must_be_real?(beat)

  @doc "Returns the ordered subset of beats that must be real (locked policy)."
  @spec must_be_real_beats() :: [beat()]
  def must_be_real_beats do
    Enum.filter(beats(), &must_be_real?/1)
  end

  # Live state — Day 1: nothing real is wired up yet.
  # Flip each clause to `:real` as the corresponding implementation lands.
  @spec do_beat_mode(beat()) :: mode()
  defp do_beat_mode(:b1), do: :conductor
  defp do_beat_mode(:b2), do: :conductor
  defp do_beat_mode(:b3), do: :conductor
  defp do_beat_mode(:b4), do: :conductor
  defp do_beat_mode(:b5), do: :conductor
  defp do_beat_mode(:b6), do: :conductor
  defp do_beat_mode(:b7), do: :conductor
  defp do_beat_mode(:b8), do: :conductor

  # Locked policy — PAGELESS.md must-be-real beat table. Do NOT edit without
  # also editing PAGELESS.md.
  @spec do_must_be_real?(beat()) :: boolean()
  defp do_must_be_real?(:b1), do: false
  defp do_must_be_real?(:b2), do: false
  defp do_must_be_real?(:b3), do: true
  defp do_must_be_real?(:b4), do: true
  defp do_must_be_real?(:b5), do: true
  defp do_must_be_real?(:b6), do: true
  defp do_must_be_real?(:b7), do: false
  defp do_must_be_real?(:b8), do: false
end
