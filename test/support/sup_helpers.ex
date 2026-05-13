defmodule Pageless.SupHelpers do
  @moduledoc "Test helpers for isolated alert supervision trees."

  alias Pageless.Sup.Alert
  alias Pageless.Sup.Alert.State

  @doc "Starts an isolated alert tree and intake pair under the current test supervisor."
  @spec start_isolated_tree(keyword()) :: %{tree: pid(), intake: pid()}
  def start_isolated_tree(opts) do
    broker = Keyword.fetch!(opts, :pubsub)

    tree =
      ExUnit.Callbacks.start_supervised!(
        {Pageless.Sup.AlertTree, []},
        id: {Pageless.Sup.AlertTree, System.unique_integer([:positive])}
      )

    intake =
      ExUnit.Callbacks.start_supervised!(
        {Pageless.Sup.AlertIntake, pubsub: broker, tree: tree},
        id: {Pageless.Sup.AlertIntake, System.unique_integer([:positive])}
      )

    {:ok, %{pubsub: ^broker, tree: ^tree}} = GenServer.call(intake, :get_state)

    %{tree: tree, intake: intake}
  end

  @doc "Starts one isolated SUP_Alert and registers cleanup for spawned agents."
  @spec start_isolated_alert(keyword()) :: %{alert: pid(), state: pid(), agent_sup: pid()}
  def start_isolated_alert(opts) do
    alert = ExUnit.Callbacks.start_supervised!({Alert, opts})
    %{state: state, agent_sup: agent_sup} = locate_alert_children(alert)
    {:ok, _state} = State.get(state)

    %{alert: alert, state: state, agent_sup: agent_sup}
  end

  @doc "Returns the state holder and agent DynamicSupervisor children for an alert supervisor."
  @spec locate_alert_children(pid()) :: %{state: pid(), agent_sup: pid()}
  def locate_alert_children(alert) do
    children = Supervisor.which_children(alert)

    %{
      state: child_pid(children, Pageless.Sup.Alert.State),
      agent_sup: child_pid(children, Pageless.Sup.Alert.AgentSup)
    }
  end

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
