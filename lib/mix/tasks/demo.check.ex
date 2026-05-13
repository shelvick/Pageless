defmodule Mix.Tasks.Demo.Check do
  @moduledoc """
  Pre-record gate for the demo video.

  Reads `Pageless.Conductor.BeatModeRegistry`, prints a status table, and exits
  non-zero if any must-be-real beat reports `:conductor`.
  """

  use Mix.Task

  alias Pageless.Conductor.BeatModeRegistry

  @shortdoc "Block recording if any must-be-real demo beat is still :conductor."

  defmodule Row do
    @moduledoc "A rendered decision row for one demo beat."

    @type t :: %__MODULE__{
            beat: BeatModeRegistry.beat(),
            mode: BeatModeRegistry.mode(),
            must_be_real?: boolean(),
            verdict: :ok | :fail | :skip
          }

    defstruct [:beat, :mode, :must_be_real?, :verdict]
  end

  defmodule Result do
    @moduledoc "Pure demo check result used by the Mix task shell wrapper."

    @type t :: %__MODULE__{
            exit_code: 0 | 1,
            failing_beats: [BeatModeRegistry.beat()],
            message: String.t(),
            rows: [Row.t()]
          }

    defstruct [:exit_code, :failing_beats, :message, :rows]
  end

  @doc "Runs the pre-record check and halts with the resulting exit code."
  @spec run([String.t()]) :: no_return()
  def run(args) do
    result = decision_for_args(args)

    result.rows
    |> render_table()
    |> Mix.shell().info()

    Mix.shell().info(result.message)
    System.halt(result.exit_code)
  end

  @doc "Builds the production decision for the task arguments. Extra args are ignored."
  @spec decision_for_args([String.t()]) :: Result.t()
  def decision_for_args(_args) do
    check(BeatModeRegistry.beats(), &BeatModeRegistry.beat_mode/1)
  end

  @doc "Returns the pure pre-record decision for beats and a mode lookup function."
  @spec check([BeatModeRegistry.beat()], (BeatModeRegistry.beat() -> BeatModeRegistry.mode())) ::
          Result.t()
  def check(beats, mode_lookup) when is_list(beats) and is_function(mode_lookup, 1) do
    rows = Enum.map(beats, &row_for(&1, mode_lookup.(&1)))
    failing_beats = rows |> Enum.filter(&(&1.verdict == :fail)) |> Enum.map(& &1.beat)

    %Result{
      exit_code: exit_code(failing_beats),
      failing_beats: failing_beats,
      message: message(failing_beats),
      rows: rows
    }
  end

  @doc "Renders a plain-text status table for demo check rows."
  @spec render_table([Row.t()]) :: String.t()
  def render_table(rows) when is_list(rows) do
    (["Beat | Mode | Must-be-real? | Verdict"] ++ Enum.map(rows, &render_row/1))
    |> Enum.join("\n")
  end

  @spec row_for(BeatModeRegistry.beat(), BeatModeRegistry.mode()) :: Row.t()
  defp row_for(beat, mode) do
    must_be_real? = BeatModeRegistry.must_be_real?(beat)

    %Row{
      beat: beat,
      mode: mode,
      must_be_real?: must_be_real?,
      verdict: verdict(must_be_real?, mode)
    }
  end

  @spec verdict(boolean(), BeatModeRegistry.mode()) :: :ok | :fail | :skip
  defp verdict(true, :real), do: :ok
  defp verdict(true, :conductor), do: :fail
  defp verdict(false, _mode), do: :skip

  @spec exit_code([BeatModeRegistry.beat()]) :: 0 | 1
  defp exit_code([]), do: 0
  defp exit_code(_failing_beats), do: 1

  @spec message([BeatModeRegistry.beat()]) :: String.t()
  defp message([]), do: "All must-be-real beats are :real. Recording permitted."

  defp message(failing_beats) do
    names = Enum.map_join(failing_beats, ", ", &format_beat/1)
    "Cannot record: #{names} are still :conductor. Flip them to :real before recording."
  end

  @spec render_row(Row.t()) :: String.t()
  defp render_row(%Row{} = row) do
    Enum.join(
      [
        format_beat(row.beat),
        inspect(row.mode),
        to_string(row.must_be_real?),
        format_verdict(row.verdict)
      ],
      " | "
    )
  end

  @spec format_beat(BeatModeRegistry.beat()) :: String.t()
  defp format_beat(beat), do: beat |> to_string() |> String.upcase()

  @spec format_verdict(:ok | :fail | :skip) :: String.t()
  defp format_verdict(:ok), do: "OK"
  defp format_verdict(:fail), do: "FAIL"
  defp format_verdict(:skip), do: "-"
end
