defmodule Pageless.Conductor.DemoConductor do
  @moduledoc """
  Driver process for conductor-mode demo beats.

  Broadcasts B1/B2/B7/B8 events through an injected Phoenix.PubSub broker. The
  process is intentionally unnamed so tests can run with isolated brokers.
  """

  use GenServer

  alias Pageless.AlertEnvelope
  alias Pageless.Conductor.BeatModeRegistry

  @type beat :: BeatModeRegistry.beat()
  @type opts :: [pubsub: atom()]
  @type state :: %{pubsub: atom()}

  @doc "Starts the demo conductor with an explicitly injected PubSub broker."
  @spec start_link(opts()) :: GenServer.on_start()
  def start_link(opts) do
    pubsub = Keyword.fetch!(opts, :pubsub)
    GenServer.start_link(__MODULE__, %{pubsub: pubsub})
  end

  @doc "Broadcasts a B1 alert envelope on the alerts topic."
  @spec broadcast_alert(GenServer.server(), AlertEnvelope.t()) :: :ok | {:error, :real_beat}
  def broadcast_alert(server, %AlertEnvelope{} = envelope) do
    GenServer.call(server, {:broadcast_alert, envelope})
  end

  @doc "Broadcasts a conductor beat cue on the conductor topic."
  @spec broadcast_beat(GenServer.server(), beat()) :: :ok | {:error, :real_beat}
  def broadcast_beat(server, beat) do
    GenServer.call(server, {:broadcast_beat, beat})
  end

  @doc "Broadcasts B7 scoreboard stats on the conductor topic."
  @spec broadcast_scoreboard(GenServer.server(), map()) :: :ok | {:error, :real_beat}
  def broadcast_scoreboard(server, stats) when is_map(stats) do
    GenServer.call(server, {:broadcast_scoreboard, stats})
  end

  @impl true
  @spec init(state()) :: {:ok, state()}
  def init(state), do: {:ok, state}

  @doc false
  @impl true
  @spec handle_call(
          {:broadcast_alert, AlertEnvelope.t()}
          | {:broadcast_beat, beat()}
          | {:broadcast_scoreboard, map()},
          GenServer.from(),
          state()
        ) :: {:reply, :ok, state()}
  def handle_call(message, _from, state) do
    {beat, topic, payload} = conductor_event(message)
    reply = broadcast_if_conductor(state.pubsub, beat, topic, payload)

    {:reply, reply, state}
  end

  @spec conductor_event(
          {:broadcast_alert, AlertEnvelope.t()}
          | {:broadcast_beat, beat()}
          | {:broadcast_scoreboard, map()}
        ) ::
          {beat(), String.t(), term()}
  defp conductor_event({:broadcast_alert, envelope}) do
    {:b1, "alerts", {:alert_received, envelope}}
  end

  defp conductor_event({:broadcast_beat, beat}) do
    {beat, "conductor", {:conductor_beat, beat, :conductor}}
  end

  defp conductor_event({:broadcast_scoreboard, stats}) do
    {:b7, "conductor", {:conductor_beat, :b7, :conductor, stats}}
  end

  @spec broadcast_if_conductor(atom(), beat(), String.t(), term()) :: :ok
  defp broadcast_if_conductor(pubsub, beat, topic, message) do
    :conductor = BeatModeRegistry.beat_mode(beat)
    Phoenix.PubSub.broadcast(pubsub, topic, message)
  end
end
