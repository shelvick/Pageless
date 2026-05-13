defmodule Pageless.Sup.Alert do
  @moduledoc "Per-alert supervisor that owns alert state and dynamic agent children."

  use Supervisor

  alias Pageless.AlertEnvelope
  alias Pageless.Sup.Alert.AgentSup
  alias Pageless.Sup.Alert.State

  @type opts :: [
          envelope: AlertEnvelope.t(),
          pubsub: atom(),
          sandbox_owner: pid() | nil,
          audit_repo: module() | nil,
          gemini_client: module() | nil,
          parent: pid() | nil
        ]

  @doc "Starts a supervisor for one alert envelope."
  @spec start_link(opts()) :: Supervisor.on_start()
  def start_link(opts) do
    with :ok <- require_opt(opts, :envelope),
         :ok <- require_opt(opts, :pubsub) do
      Supervisor.start_link(__MODULE__, opts)
    else
      {:error, error} -> {:error, error}
    end
  end

  @impl true
  def init(opts) do
    children = [
      {State, opts},
      AgentSup
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc "Starts an agent under this alert's AgentSup with alert-scoped defaults injected."
  @spec start_agent(pid(), module(), keyword()) :: DynamicSupervisor.on_start_child()
  def start_agent(alert_sup, agent_module, agent_extra_opts) do
    %{state: state_pid, agent_sup: agent_sup} = locate_children(alert_sup)
    {:ok, state} = State.get(state_pid)

    full_opts =
      [
        alert_id: state.envelope.alert_id,
        envelope: state.envelope,
        pubsub: state.pubsub,
        sandbox_owner: state.sandbox_owner,
        audit_repo: state.audit_repo,
        gemini_client: state.gemini_client,
        parent: state.parent || self()
      ]
      |> Keyword.merge(agent_extra_opts)

    DynamicSupervisor.start_child(agent_sup, agent_spec(agent_module, full_opts))
  end

  @spec require_opt(keyword(), atom()) :: :ok | {:error, {{:badkey, atom(), keyword()}, []}}
  defp require_opt(opts, key) do
    if Keyword.has_key?(opts, key), do: :ok, else: {:error, {{:badkey, key, opts}, []}}
  end

  @spec agent_spec(module(), keyword()) :: Supervisor.child_spec()
  defp agent_spec(agent_module, opts) do
    %{
      id: {agent_module, System.unique_integer([:positive])},
      start: {__MODULE__, :start_agent_process, [agent_module, opts]},
      restart: :transient,
      type: :worker
    }
  end

  @doc "Starts an agent process for the DynamicSupervisor child spec wrapper."
  @spec start_agent_process(module(), keyword()) :: {:ok, pid()} | :ignore | {:error, term()}
  def start_agent_process(agent_module, opts), do: agent_module.start_link(opts)

  @doc "Stops the alert supervisor normally."
  @spec stop(pid()) :: :ok
  def stop(alert_sup), do: Supervisor.stop(alert_sup, :normal)

  @spec locate_children(pid()) :: %{state: pid(), agent_sup: pid()}
  defp locate_children(alert_sup) do
    children = Supervisor.which_children(alert_sup)

    %{
      state: child_pid(children, State),
      agent_sup: child_pid(children, AgentSup)
    }
  end

  @spec child_pid([Supervisor.child()], module()) :: pid()
  defp child_pid(children, module) do
    {_id, pid, _type, _modules} =
      Enum.find(children, fn
        {^module, _pid, _type, _modules} -> true
        {_id, _pid, _type, modules} when is_list(modules) -> module in modules
        _child -> false
      end)

    pid
  end
end
