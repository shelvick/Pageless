defmodule Pageless.Sup.AlertTree do
  @moduledoc "DynamicSupervisor that owns one supervised process tree per alert."

  use DynamicSupervisor

  alias Pageless.Sup.Alert

  @default_max_children 10

  @type opts :: [
          name: GenServer.name() | nil,
          alert_supervisor: module() | nil,
          max_children: pos_integer() | :infinity
        ]

  @doc "Starts the alert tree DynamicSupervisor."
  @spec start_link(opts()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: opts[:name])
  end

  @doc """
  Initializes the DynamicSupervisor with a bounded `max_children` cap.

  Resolution order: explicit `:max_children` opt → `:pageless, :alert_tree_max_children`
  app env (set by `config/runtime.exs` from the `ALERT_TREE_MAX_CHILDREN` env var) →
  hardcoded default of #{@default_max_children}.
  """
  @impl true
  @spec init(opts()) :: {:ok, DynamicSupervisor.sup_flags()}
  def init(opts) do
    max_children =
      Keyword.get(
        opts,
        :max_children,
        Application.get_env(:pageless, :alert_tree_max_children, @default_max_children)
      )

    DynamicSupervisor.init(strategy: :one_for_one, max_children: max_children)
  end

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

  @doc "Returns active-child utilization for a bounded alert tree."
  @spec utilization(pid() | GenServer.name()) :: float()
  def utilization(tree) do
    case max_children(tree) do
      :infinity -> 0.0
      max_children -> DynamicSupervisor.count_children(tree).active / max_children
    end
  end

  @spec max_children(pid() | GenServer.name()) :: pos_integer() | :infinity
  defp max_children(tree) do
    tree
    |> :sys.get_state()
    |> Map.fetch!(:max_children)
  end

  @spec child_id(keyword()) :: term()
  defp child_id(alert_opts) do
    case Keyword.get(alert_opts, :envelope) do
      %{alert_id: alert_id} -> alert_id
      _envelope -> make_ref()
    end
  end
end
