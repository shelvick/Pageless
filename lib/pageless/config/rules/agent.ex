defmodule Pageless.Config.Rules.Agent do
  @moduledoc """
  Process-local holder for validated Pageless rules.
  """

  alias Pageless.Config.Rules

  @doc "Builds a supervisor child spec for an unnamed rules Agent."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 500
    }
  end

  @doc "Starts an unnamed Agent containing the validated rules for the supplied path."
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts) do
    opts
    |> Keyword.fetch!(:path)
    |> Rules.load!()
    |> then(&Agent.start_link(fn -> &1 end))
  end

  @doc "Returns the validated rules struct from an Agent PID."
  @spec get(pid()) :: Rules.t()
  def get(pid), do: Agent.get(pid, & &1)
end
