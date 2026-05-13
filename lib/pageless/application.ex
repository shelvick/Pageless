defmodule Pageless.Application do
  @moduledoc """
  OTP application entry point.

  Boots the root supervision tree: Repo, named PubSub (production singleton —
  test instances use isolated per-test pubsub per global CLAUDE.md test
  isolation rules), and the Phoenix endpoint. Day 1+ additions land here:
  AlertTreeSupervisor, CFG_RulesYamlLoader, SVC_GeminiClient, SVC_MCPClient.
  """
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Pageless.Repo,
      {Phoenix.PubSub, name: Pageless.PubSub},
      PagelessWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Pageless.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    PagelessWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
