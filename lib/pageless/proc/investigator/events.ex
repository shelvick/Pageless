defmodule Pageless.Proc.Investigator.Events do
  @moduledoc "Agent-state event, PubSub, parent-notification, and JSON-shaping helpers for investigators."

  require Logger

  alias Pageless.Data.AgentState

  @doc "Appends an investigator event to the audit state stream and advances the sequence counter."
  @spec append(map(), AgentState.event_type(), map()) :: map()
  def append(state, event_type, payload) do
    attrs = %{
      alert_id: state.alert_id,
      agent_id: state.agent_id,
      agent_type: :investigator,
      profile: Atom.to_string(state.profile.name),
      event_type: event_type,
      payload: json_safe(payload),
      sequence: state.sequence
    }

    case AgentState.append_event(state.audit_repo, attrs) do
      {:ok, _row} ->
        :ok

      {:error, reason} ->
        Logger.warning("failed to append investigator state: #{inspect(reason)}")
    end

    %{state | sequence: state.sequence + 1}
  end

  @doc "Broadcasts an investigator event on the alert-local PubSub topic."
  @spec broadcast(map(), tuple()) :: map()
  def broadcast(state, event) do
    :ok = Phoenix.PubSub.broadcast(state.pubsub, "alert:#{state.alert_id}", event)
    state
  end

  @doc "Notifies the parent process with completed investigation findings when one is present."
  @spec notify_parent(map(), map()) :: map()
  def notify_parent(%{parent: nil} = state, _findings), do: state

  def notify_parent(state, findings) do
    send(state.parent, {:investigation_findings, state.alert_id, state.profile.name, findings})
    state
  end

  @doc "Converts tuples, atoms, lists, and maps into JSON-encodable shapes."
  @spec json_safe(term()) :: term()
  def json_safe(value) when is_atom(value), do: Atom.to_string(value)

  def json_safe(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.map(&json_safe/1)

  def json_safe(value) when is_map(value),
    do: Map.new(value, fn {key, val} -> {json_key(key), json_safe(val)} end)

  def json_safe(value) when is_list(value), do: Enum.map(value, &json_safe/1)
  def json_safe(value), do: value

  @spec json_key(term()) :: term()
  defp json_key(key) when is_atom(key), do: Atom.to_string(key)
  defp json_key(key), do: key
end
