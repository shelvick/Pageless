defmodule Pageless.Repo.Migrations.CreateAgentStateEvents do
  @moduledoc false

  use Ecto.Migration

  @agent_types ~w(triager investigator remediator escalator)
  @event_types ~w(spawned reasoning_line tool_call tool_error tool_hallucination findings final_state)

  @doc false
  def change do
    create table(:agent_state_events) do
      add :alert_id, :text, null: false
      add :agent_id, :text, null: false
      add :agent_type, :text, null: false
      add :profile, :text
      add :event_type, :text, null: false
      add :payload, :map, null: false
      add :sequence, :integer, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:agent_state_events, :agent_state_events_agent_type_check,
             check: "agent_type IN (#{quoted_values(@agent_types)})"
           )

    create constraint(:agent_state_events, :agent_state_events_event_type_check,
             check: "event_type IN (#{quoted_values(@event_types)})"
           )

    create index(:agent_state_events, [:agent_id, :sequence])
    create index(:agent_state_events, [:alert_id, :inserted_at])
  end

  @doc false
  defp quoted_values(values) do
    values
    |> Enum.map_join(", ", &"'#{&1}'")
  end
end
