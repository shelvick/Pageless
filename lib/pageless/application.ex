defmodule Pageless.Application do
  @moduledoc """
  OTP application entry point.

  Boots the root supervision tree in dependency order: Repo, named PubSub,
  alert DynamicSupervisor, alert intake subscriber, and the Phoenix endpoint.
  Production uses structural singleton names here; tests use isolated per-test
  supervisors and PubSub brokers. The endpoint is configured away from port 4000.
  """
  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        Pageless.Repo,
        {Phoenix.PubSub, name: Pageless.PubSub},
        {Pageless.Sup.AlertTree, name: Pageless.AlertTree},
        %{
          id: Pageless.Sup.AlertIntake,
          start:
            {Pageless.Sup.AlertIntake, :start_link,
             [[pubsub: Pageless.PubSub, tree: Pageless.AlertTree, name: Pageless.AlertIntake]]}
        },
        {Pageless.Conductor.DemoConductor, pubsub: Pageless.PubSub},
        PagelessWeb.Endpoint
      ]
      |> append_mcp_filesystem(Application.get_env(:pageless, :mcp_filesystem, :disabled))

    opts = [strategy: :one_for_one, name: Pageless.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @spec append_mcp_filesystem(
          [Supervisor.child_spec() | module() | {module(), term()}],
          :disabled | nil | keyword()
        ) ::
          [Supervisor.child_spec() | module() | {module(), term()}]
  defp append_mcp_filesystem(children, disabled) when disabled in [nil, :disabled], do: children

  defp append_mcp_filesystem(children, config) when is_list(config) do
    children ++
      [
        {Anubis.Client,
         name: Pageless.MCP.Filesystem,
         transport:
           {:stdio,
            command: Keyword.fetch!(config, :command), args: Keyword.get(config, :args, [])},
         client_info: %{name: "pageless", version: "0.1.0"},
         capabilities: %{},
         protocol_version: Keyword.get(config, :protocol_version, "2024-11-05")}
      ]
  end

  @impl true
  def config_change(changed, _new, removed) do
    PagelessWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
