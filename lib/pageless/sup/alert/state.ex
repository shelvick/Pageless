defmodule Pageless.Sup.Alert.State do
  @moduledoc "Per-alert state holder for immutable envelope data and injected dependencies."

  use GenServer

  alias Pageless.AlertEnvelope

  defstruct [:envelope, :pubsub, :sandbox_owner, :audit_repo, :gemini_client, :parent]

  @type t :: %__MODULE__{
          envelope: AlertEnvelope.t(),
          pubsub: atom(),
          sandbox_owner: pid() | nil,
          audit_repo: module(),
          gemini_client: module(),
          parent: pid() | nil
        }

  @doc "Starts the per-alert state holder."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Returns the current per-alert state."
  @spec get(pid()) :: {:ok, t()}
  def get(state_pid), do: GenServer.call(state_pid, :get)

  @impl true
  def init(opts) do
    state = %__MODULE__{
      envelope: Keyword.fetch!(opts, :envelope),
      pubsub: Keyword.fetch!(opts, :pubsub),
      sandbox_owner: Keyword.get(opts, :sandbox_owner),
      audit_repo: Keyword.get(opts, :audit_repo, Pageless.Repo),
      gemini_client: Keyword.get(opts, :gemini_client, Pageless.Svc.GeminiClient),
      parent: Keyword.get(opts, :parent)
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:get, _from, state), do: {:reply, {:ok, state}, state}
end
