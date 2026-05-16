defmodule Pageless.Sup.Alert.State do
  @moduledoc "Per-alert state holder for immutable envelope data and injected dependencies."

  use GenServer

  alias Pageless.AlertEnvelope

  @default_tool_call_budget 30
  @default_idle_ttl_ms 300_000

  defstruct [
    :envelope,
    :pubsub,
    :sandbox_owner,
    :audit_repo,
    :gemini_client,
    :parent,
    :parent_sup,
    tool_call_count: 0,
    tool_call_budget: @default_tool_call_budget,
    idle_ttl_ms: @default_idle_ttl_ms,
    last_activity_at: nil
  ]

  @type t :: %__MODULE__{
          envelope: AlertEnvelope.t(),
          pubsub: atom(),
          sandbox_owner: pid() | nil,
          audit_repo: module(),
          gemini_client: module(),
          parent: pid() | nil,
          parent_sup: pid() | nil,
          tool_call_count: non_neg_integer(),
          tool_call_budget: pos_integer(),
          idle_ttl_ms: pos_integer(),
          last_activity_at: integer()
        }

  @doc "Builds a child spec with an alert-local id for isolated test starts."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :envelope).alert_id},
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  @type opts :: [
          envelope: AlertEnvelope.t(),
          pubsub: atom(),
          sandbox_owner: pid() | nil,
          audit_repo: module(),
          gemini_client: module(),
          parent: pid() | nil,
          parent_sup: pid() | nil,
          tool_call_budget: pos_integer(),
          idle_ttl_ms: pos_integer(),
          env_reader: (String.t() -> String.t() | nil),
          clock: (-> integer())
        ]

  @doc "Starts the per-alert state holder."
  @spec start_link(opts()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Returns the current per-alert state."
  @spec get(pid()) :: {:ok, t()}
  def get(state_pid), do: GenServer.call(state_pid, :get)

  @doc "Claims one slot from the per-alert tool-call budget."
  @spec inc_tool_call(pid()) :: :ok | {:error, :budget_exhausted}
  def inc_tool_call(state_pid), do: GenServer.call(state_pid, :inc_tool_call)

  @doc "Marks the alert as active for idle-TTL shutdown tracking."
  @spec bump_activity(pid()) :: :ok
  def bump_activity(state_pid), do: GenServer.call(state_pid, :bump_activity)

  @impl true
  def init(opts) do
    clock = Keyword.get(opts, :clock, &System.monotonic_time/1)

    state = %__MODULE__{
      envelope: Keyword.fetch!(opts, :envelope),
      pubsub: Keyword.fetch!(opts, :pubsub),
      sandbox_owner: Keyword.get(opts, :sandbox_owner),
      audit_repo: Keyword.get(opts, :audit_repo, Pageless.Repo),
      gemini_client: Keyword.get(opts, :gemini_client, Pageless.Svc.GeminiClient),
      parent: Keyword.get(opts, :parent),
      parent_sup: Keyword.get(opts, :parent_sup),
      tool_call_count: 0,
      tool_call_budget: tool_call_budget(opts),
      idle_ttl_ms: idle_ttl_ms(opts),
      last_activity_at: clock.(:millisecond)
    }

    {:ok, state, {:continue, :setup}}
  end

  @impl true
  def handle_continue(:setup, state) do
    Process.send_after(self(), :idle_check, state.idle_ttl_ms)
    {:noreply, state}
  end

  @impl true
  def handle_call(:get, _from, state), do: {:reply, {:ok, state}, state}

  def handle_call(
        :inc_tool_call,
        _from,
        %{tool_call_count: count, tool_call_budget: budget} = state
      )
      when count < budget do
    {:reply, :ok, %{state | tool_call_count: count + 1}}
  end

  def handle_call(:inc_tool_call, _from, state) do
    {:reply, {:error, :budget_exhausted}, state}
  end

  def handle_call(:bump_activity, _from, state) do
    {:reply, :ok, %{state | last_activity_at: System.monotonic_time(:millisecond)}}
  end

  @impl true
  def handle_info(:idle_check, %{parent_sup: nil} = state) do
    Process.send_after(self(), :idle_check, state.idle_ttl_ms)
    {:noreply, state}
  end

  def handle_info(:idle_check, state) do
    elapsed_ms = System.monotonic_time(:millisecond) - state.last_activity_at

    if elapsed_ms >= state.idle_ttl_ms do
      Supervisor.stop(state.parent_sup, :normal)
    else
      Process.send_after(self(), :idle_check, state.idle_ttl_ms - elapsed_ms)
    end

    {:noreply, state}
  end

  @spec tool_call_budget(keyword()) :: pos_integer()
  defp tool_call_budget(opts) do
    opts
    |> Keyword.get(:tool_call_budget, tool_call_budget_default(Keyword.get(opts, :env_reader)))
    |> normalize_tool_call_budget()
  end

  @spec normalize_tool_call_budget(term()) :: pos_integer()
  defp normalize_tool_call_budget(value) when is_integer(value) and value > 0, do: value
  defp normalize_tool_call_budget(_value), do: @default_tool_call_budget

  @spec tool_call_budget_default(term()) :: pos_integer()
  defp tool_call_budget_default(env_reader) when is_function(env_reader, 1) do
    case env_reader.("ALERT_TOOL_CALL_BUDGET") do
      value when is_binary(value) -> parse_tool_call_budget(value)
      _value -> @default_tool_call_budget
    end
  end

  defp tool_call_budget_default(_env_reader) do
    System.get_env("ALERT_TOOL_CALL_BUDGET")
    |> parse_tool_call_budget()
  end

  @spec parse_tool_call_budget(String.t() | nil) :: pos_integer()
  defp parse_tool_call_budget(nil), do: @default_tool_call_budget

  defp parse_tool_call_budget(value) when is_binary(value) do
    case Integer.parse(value) do
      {budget, ""} when budget > 0 -> budget
      _other -> @default_tool_call_budget
    end
  end

  @spec idle_ttl_ms(keyword()) :: pos_integer()
  defp idle_ttl_ms(opts) do
    opts
    |> Keyword.get(:idle_ttl_ms, idle_ttl_default(Keyword.get(opts, :env_reader)))
    |> normalize_idle_ttl_ms()
  end

  @spec normalize_idle_ttl_ms(term()) :: pos_integer()
  defp normalize_idle_ttl_ms(value) when is_integer(value) and value > 0, do: value
  defp normalize_idle_ttl_ms(_value), do: @default_idle_ttl_ms

  @spec idle_ttl_default(term()) :: pos_integer()
  defp idle_ttl_default(env_reader) when is_function(env_reader, 1) do
    try do
      case env_reader.("ALERT_IDLE_TTL_MS") do
        value when is_binary(value) -> parse_idle_ttl_ms(value)
        _value -> @default_idle_ttl_ms
      end
    rescue
      FunctionClauseError -> @default_idle_ttl_ms
    end
  end

  defp idle_ttl_default(_env_reader) do
    Application.get_env(:pageless, :alert_idle_ttl_ms, @default_idle_ttl_ms)
    |> normalize_idle_ttl_ms()
  end

  @spec parse_idle_ttl_ms(String.t()) :: pos_integer()
  defp parse_idle_ttl_ms(value) when is_binary(value) do
    case Integer.parse(value) do
      {ttl, ""} when ttl > 0 -> ttl
      _other -> @default_idle_ttl_ms
    end
  end
end
