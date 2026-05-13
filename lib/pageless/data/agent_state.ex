defmodule Pageless.Data.AgentState do
  @moduledoc """
  Append-only Ecto schema and query API for per-agent cognitive trace events.
  """

  use Ecto.Schema

  import Ecto.Changeset
  import Ecto.Query

  @agent_types [:triager, :investigator, :remediator, :escalator]
  @event_types [
    :spawned,
    :reasoning_line,
    :tool_call,
    :tool_error,
    :tool_hallucination,
    :findings,
    :final_state
  ]

  @type agent_type :: :triager | :investigator | :remediator | :escalator
  @type event_type ::
          :spawned
          | :reasoning_line
          | :tool_call
          | :tool_error
          | :tool_hallucination
          | :findings
          | :final_state

  @type attrs :: %{
          optional(:alert_id) => String.t(),
          optional(:agent_id) => String.t(),
          optional(:agent_type) => agent_type(),
          optional(:profile) => String.t() | nil,
          optional(:event_type) => event_type(),
          optional(:payload) => map(),
          optional(:sequence) => integer()
        }

  @type t :: %__MODULE__{
          id: integer() | nil,
          alert_id: String.t() | nil,
          agent_id: String.t() | nil,
          agent_type: agent_type() | nil,
          profile: String.t() | nil,
          event_type: event_type() | nil,
          payload: map() | nil,
          sequence: integer() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "agent_state_events" do
    field :alert_id, :string
    field :agent_id, :string
    field :agent_type, Ecto.Enum, values: @agent_types
    field :profile, :string
    field :event_type, Ecto.Enum, values: @event_types
    field :payload, :map
    field :sequence, :integer

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Appends one event row for an agent.
  """
  @spec append_event(Ecto.Repo.t(), attrs()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def append_event(repo, attrs) do
    %__MODULE__{}
    |> changeset(attrs)
    |> repo.insert()
  end

  @doc """
  Returns all events for an agent in ascending sequence order.
  """
  @spec history(Ecto.Repo.t(), String.t() | nil) :: [t()]
  def history(repo, agent_id), do: history(repo, agent_id, [])

  @doc """
  Returns events for an agent, optionally filtered by event type, lower time bound, and limit.
  """
  @spec history(Ecto.Repo.t(), String.t() | nil, keyword()) :: [t()]
  def history(repo, agent_id, opts) do
    if is_nil(agent_id) do
      []
    else
      __MODULE__
      |> where([event], event.agent_id == ^agent_id)
      |> filter_event_type(Keyword.get(opts, :event_type))
      |> filter_since(Keyword.get(opts, :since))
      |> order_by([event], asc: event.sequence, asc: event.id)
      |> maybe_limit(Keyword.get(opts, :limit))
      |> repo.all()
    end
  end

  @doc """
  Returns all events for an alert across agents in insertion order.
  """
  @spec history_for_alert(Ecto.Repo.t(), String.t()) :: [t()]
  def history_for_alert(repo, alert_id) do
    __MODULE__
    |> where([event], event.alert_id == ^alert_id)
    |> order_by([event], asc: event.inserted_at, asc: event.id)
    |> repo.all()
  end

  @doc """
  Returns the latest final-state event for an agent, or nil when none exists.
  """
  @spec final_state(Ecto.Repo.t(), String.t()) :: t() | nil
  def final_state(repo, agent_id) do
    __MODULE__
    |> where([event], event.agent_id == ^agent_id and event.event_type == :final_state)
    |> order_by([event], desc: event.sequence, desc: event.id)
    |> limit(1)
    |> repo.one()
  end

  @spec changeset(t(), attrs() | map()) :: Ecto.Changeset.t()
  defp changeset(event, attrs) do
    event
    |> cast(attrs, [:alert_id, :agent_id, :agent_type, :profile, :event_type, :payload, :sequence])
    |> validate_required([:alert_id, :agent_id, :agent_type, :event_type, :payload, :sequence])
    |> validate_payload_map()
  end

  @spec validate_payload_map(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  defp validate_payload_map(changeset) do
    validate_change(changeset, :payload, fn
      :payload, payload when is_map(payload) -> []
      :payload, _payload -> [payload: "must be a map"]
    end)
  end

  @spec filter_event_type(Ecto.Queryable.t(), event_type() | [event_type()] | nil) ::
          Ecto.Query.t()
  defp filter_event_type(query, nil), do: query

  defp filter_event_type(query, event_types) when is_list(event_types) do
    where(query, [event], event.event_type in ^event_types)
  end

  defp filter_event_type(query, event_type) do
    where(query, [event], event.event_type == ^event_type)
  end

  @spec filter_since(Ecto.Queryable.t(), DateTime.t() | nil) :: Ecto.Query.t()
  defp filter_since(query, nil), do: query

  defp filter_since(query, since) do
    where(query, [event], event.inserted_at > ^since)
  end

  @spec maybe_limit(Ecto.Queryable.t(), pos_integer() | nil) :: Ecto.Query.t()
  defp maybe_limit(query, nil), do: query

  defp maybe_limit(query, limit_count) do
    limit(query, ^limit_count)
  end
end
