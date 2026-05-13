defmodule Pageless.Sup.AlertIntake do
  @moduledoc "Subscriber GenServer that turns alert PubSub broadcasts into alert supervisors."

  use GenServer

  require Logger

  alias Pageless.Sup.AlertTree

  @type opts :: [pubsub: atom(), tree: pid() | GenServer.name(), name: GenServer.name() | nil]
  @type state :: %{pubsub: atom(), tree: pid() | GenServer.name()}

  @doc "Starts the alert intake subscriber."
  @spec start_link(opts()) :: GenServer.on_start()
  def start_link(opts) do
    opts
    |> Keyword.fetch(:name)
    |> start_link_with_name(opts)
  end

  @spec start_link_with_name({:ok, GenServer.name()} | :error, opts()) :: GenServer.on_start()
  defp start_link_with_name({:ok, name}, opts) do
    name_opts = Keyword.put([], :name, name)
    GenServer.start_link(__MODULE__, opts, name_opts)
  end

  defp start_link_with_name(:error, opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    {:ok, %{pubsub: Keyword.fetch!(opts, :pubsub), tree: Keyword.fetch!(opts, :tree)},
     {:continue, :setup}}
  end

  @impl true
  def handle_continue(:setup, state) do
    :ok = Phoenix.PubSub.subscribe(state.pubsub, "alerts")
    {:noreply, state}
  end

  @impl true
  def handle_call(:get_state, _from, state), do: {:reply, {:ok, state}, state}

  @doc "Handles alert broadcasts by starting per-alert supervisors."
  @impl true
  @spec handle_info(term(), state()) :: {:noreply, state()}
  def handle_info(message, state), do: handle_intake_message(message, state)

  @spec handle_intake_message(term(), state()) :: {:noreply, state()}
  defp handle_intake_message({:alert_received, envelope}, state) do
    state.tree
    |> AlertTree.start_alert(envelope: envelope, pubsub: state.pubsub)
    |> log_start_result(envelope)

    {:noreply, state}
  end

  defp handle_intake_message(_message, state), do: {:noreply, state}

  @spec log_start_result(DynamicSupervisor.on_start_child(), Pageless.AlertEnvelope.t()) :: :ok
  defp log_start_result({:ok, _pid}, envelope) do
    Logger.debug("started alert supervisor for #{envelope.alert_id}")
  end

  defp log_start_result(:ignore, envelope) do
    Logger.debug("ignored alert supervisor for #{envelope.alert_id}")
  end

  defp log_start_result({:error, reason}, envelope) do
    Logger.warning(
      "failed to start alert supervisor for #{envelope.alert_id}: #{inspect(reason)}"
    )
  end
end
