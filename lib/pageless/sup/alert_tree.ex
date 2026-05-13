defmodule Pageless.Sup.AlertTree do
  @moduledoc "DynamicSupervisor that owns one supervised process tree per alert."

  use DynamicSupervisor

  alias Pageless.Sup.Alert

  @type opts :: [name: GenServer.name() | nil, alert_supervisor: module() | nil]

  @doc "Starts the alert tree DynamicSupervisor."
  @spec start_link(opts()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: opts[:name])
  end

  @impl true
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)

  @doc "Starts one alert supervisor child under the alert tree."
  @spec start_alert(pid() | GenServer.name(), Alert.opts()) :: DynamicSupervisor.on_start_child()
  def start_alert(tree, alert_opts) do
    alert_module = Keyword.get(alert_opts, :alert_supervisor, Alert)

    spec = %{
      id: child_id(alert_opts),
      start: {alert_module, :start_link, [alert_opts]},
      restart: :temporary,
      type: :supervisor
    }

    DynamicSupervisor.start_child(tree, spec)
  end

  @spec child_id(keyword()) :: term()
  defp child_id(alert_opts) do
    case Keyword.get(alert_opts, :envelope) do
      %{alert_id: alert_id} -> alert_id
      _envelope -> make_ref()
    end
  end
end
