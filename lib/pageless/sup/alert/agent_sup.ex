defmodule Pageless.Sup.Alert.AgentSup do
  @moduledoc "DynamicSupervisor for agent processes working on one alert."

  use DynamicSupervisor

  @doc "Starts the per-alert agent DynamicSupervisor."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []), do: DynamicSupervisor.start_link(__MODULE__, opts)

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one, max_restarts: 3, max_seconds: 5)
  end
end
