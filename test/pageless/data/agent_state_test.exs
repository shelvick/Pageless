defmodule Pageless.Data.AgentStateTest do
  @moduledoc """
  Tests the append-only agent state event schema and query API.
  """

  use Pageless.DataCase, async: true

  alias Pageless.Data.AgentState

  describe "migration and table shape" do
    test "agent_state_events table has expected columns and composite indexes" do
      columns =
        Repo.query!("""
        SELECT column_name
        FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'agent_state_events'
        ORDER BY ordinal_position
        """)
        |> Map.fetch!(:rows)
        |> List.flatten()

      assert columns == [
               "id",
               "alert_id",
               "agent_id",
               "agent_type",
               "profile",
               "event_type",
               "payload",
               "sequence",
               "inserted_at",
               "updated_at"
             ]

      index_rows =
        Repo.query!("""
        SELECT indexdef
        FROM pg_indexes
        WHERE schemaname = 'public' AND tablename = 'agent_state_events'
        """)
        |> Map.fetch!(:rows)
        |> List.flatten()

      assert Enum.any?(index_rows, &(&1 =~ "agent_id" and &1 =~ "sequence"))
      assert Enum.any?(index_rows, &(&1 =~ "alert_id" and &1 =~ "inserted_at"))
    end

    test "database rejects out-of-band invalid agent_type and event_type values" do
      assert Repo.query!("SELECT to_regclass('public.agent_state_events')::text").rows == [
               ["agent_state_events"]
             ]

      assert_raise Postgrex.Error, fn ->
        Repo.query!("""
        INSERT INTO agent_state_events
          (alert_id, agent_id, agent_type, event_type, payload, sequence, inserted_at, updated_at)
        VALUES
          ('alert-db-guard', 'agent-db-guard', 'bogus_agent', 'bogus_event', '{}', 1, now(), now())
        """)
      end
    end
  end

  describe "append_event/2" do
    test "accepts every supported event type and makes rows readable through history/3" do
      event_types = [
        :spawned,
        :reasoning_line,
        :tool_call,
        :tool_error,
        :tool_hallucination,
        :findings,
        :final_state
      ]

      for {event_type, sequence} <- Enum.with_index(event_types, 1) do
        attrs = event_attrs(event_type, sequence: sequence)

        assert {:ok, event} = AgentState.append_event(Repo, attrs)
        assert event.event_type == event_type
      end

      history = AgentState.history(Repo, "agent-1")

      assert Enum.map(history, & &1.event_type) == event_types
      assert Enum.map(history, & &1.sequence) == Enum.to_list(1..7)
    end

    test "rejects invalid event_type without inserting a row" do
      attrs = event_attrs(:spawned, agent_id: "agent-invalid", event_type: :bogus)

      assert {:error, changeset} = AgentState.append_event(Repo, attrs)
      assert %{event_type: [_ | _]} = errors_on(changeset)
      assert AgentState.history(Repo, "agent-invalid") == []
    end

    test "rejects missing agent_id without inserting a row" do
      attrs = event_attrs(:spawned, agent_id: nil)

      assert {:error, changeset} = AgentState.append_event(Repo, attrs)
      assert %{agent_id: [_ | _]} = errors_on(changeset)
      assert AgentState.history(Repo, nil) == []
    end

    test "rejects non-map payload without inserting a row" do
      attrs = event_attrs(:reasoning_line, agent_id: "agent-bad-payload", payload: "not-a-map")

      assert {:error, changeset} = AgentState.append_event(Repo, attrs)
      assert %{payload: [_ | _]} = errors_on(changeset)
      assert AgentState.history(Repo, "agent-bad-payload") == []
    end

    test "keeps per-agent histories isolated when two agents append concurrently", %{
      sandbox_owner: sandbox_owner
    } do
      parent = self()
      alert_id = "alert-concurrent"

      task_a =
        Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.allow(Pageless.Repo, sandbox_owner, self())
          append_many(parent, alert_id, "agent-a", 1..3)
        end)

      task_b =
        Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.allow(Pageless.Repo, sandbox_owner, self())
          append_many(parent, alert_id, "agent-b", 1..3)
        end)

      assert :ok = Task.await(task_a, 5_000)
      assert :ok = Task.await(task_b, 5_000)

      assert Enum.map(AgentState.history(Repo, "agent-a"), & &1.sequence) == [1, 2, 3]
      assert Enum.map(AgentState.history(Repo, "agent-b"), & &1.sequence) == [1, 2, 3]
      assert Enum.all?(AgentState.history(Repo, "agent-a"), &(&1.agent_id == "agent-a"))
      assert Enum.all?(AgentState.history(Repo, "agent-b"), &(&1.agent_id == "agent-b"))
    end
  end

  describe "history/3" do
    test "returns one agent's events in ascending sequence order" do
      insert_event!(:tool_call, agent_id: "agent-history", sequence: 3)
      insert_event!(:spawned, agent_id: "agent-history", sequence: 1)
      insert_event!(:reasoning_line, agent_id: "agent-history", sequence: 2)
      insert_event!(:spawned, agent_id: "other-agent", sequence: 1)

      history = AgentState.history(Repo, "agent-history")

      assert Enum.map(history, & &1.sequence) == [1, 2, 3]

      assert Enum.map(history, & &1.agent_id) == [
               "agent-history",
               "agent-history",
               "agent-history"
             ]
    end

    test "filters to a single event type" do
      insert_event!(:spawned, agent_id: "agent-filter", sequence: 1)
      insert_event!(:tool_call, agent_id: "agent-filter", sequence: 2)
      insert_event!(:tool_error, agent_id: "agent-filter", sequence: 3)

      assert [:tool_call] =
               AgentState.history(Repo, "agent-filter", event_type: :tool_call)
               |> Enum.map(& &1.event_type)
    end

    test "filters to a union of event types" do
      insert_event!(:spawned, agent_id: "agent-union", sequence: 1)
      insert_event!(:tool_call, agent_id: "agent-union", sequence: 2)
      insert_event!(:tool_error, agent_id: "agent-union", sequence: 3)
      insert_event!(:findings, agent_id: "agent-union", sequence: 4)

      assert [:tool_call, :tool_error] =
               AgentState.history(Repo, "agent-union", event_type: [:tool_call, :tool_error])
               |> Enum.map(& &1.event_type)
    end

    test "supports since and limit options" do
      older = insert_event!(:spawned, agent_id: "agent-window", sequence: 1)
      insert_event!(:reasoning_line, agent_id: "agent-window", sequence: 2)
      insert_event!(:tool_call, agent_id: "agent-window", sequence: 3)

      window = AgentState.history(Repo, "agent-window", since: older.inserted_at, limit: 2)

      assert Enum.map(window, & &1.sequence) == [2, 3]
    end
  end

  describe "history_for_alert/2" do
    test "returns rows for every agent in an alert ordered by inserted_at" do
      first = insert_event!(:spawned, alert_id: "alert-1", agent_id: "agent-a", sequence: 1)
      second = insert_event!(:tool_call, alert_id: "alert-1", agent_id: "agent-b", sequence: 1)
      insert_event!(:spawned, alert_id: "alert-2", agent_id: "agent-c", sequence: 1)

      history = AgentState.history_for_alert(Repo, "alert-1")

      assert Enum.map(history, & &1.id) == [first.id, second.id]
      assert Enum.map(history, & &1.alert_id) == ["alert-1", "alert-1"]
    end
  end

  describe "final_state/2" do
    test "returns nil before final_state is appended" do
      insert_event!(:spawned, agent_id: "agent-no-final", sequence: 1)

      assert AgentState.final_state(Repo, "agent-no-final") == nil
    end

    test "returns the latest final_state event for the agent" do
      insert_event!(:spawned, agent_id: "agent-final", sequence: 1)
      first_final = insert_event!(:final_state, agent_id: "agent-final", sequence: 2)
      latest_final = insert_event!(:final_state, agent_id: "agent-final", sequence: 3)
      insert_event!(:final_state, agent_id: "other-final", sequence: 1)

      assert AgentState.final_state(Repo, "agent-final").id == latest_final.id
      refute AgentState.final_state(Repo, "agent-final").id == first_final.id
    end
  end

  defp append_many(parent, alert_id, agent_id, range) do
    Enum.each(range, fn sequence ->
      assert {:ok, _event} =
               AgentState.append_event(
                 Repo,
                 event_attrs(:reasoning_line,
                   alert_id: alert_id,
                   agent_id: agent_id,
                   sequence: sequence
                 )
               )

      send(parent, {:appended, agent_id, sequence})
    end)

    :ok
  end

  defp insert_event!(event_type, overrides) do
    attrs = event_attrs(event_type, overrides)

    assert {:ok, event} = AgentState.append_event(Repo, attrs)

    event
  end

  defp event_attrs(event_type, overrides) do
    base = %{
      alert_id: "alert-1",
      agent_id: "agent-1",
      agent_type: :investigator,
      profile: "deploys",
      event_type: event_type,
      payload: payload_for(event_type),
      sequence: 1
    }

    Enum.reduce(overrides, base, fn {key, value}, attrs -> Map.put(attrs, key, value) end)
  end

  defp payload_for(:spawned), do: %{parent: inspect(self()), opts_digest: "opts-v1"}
  defp payload_for(:reasoning_line), do: %{line: "checking recent deploys"}

  defp payload_for(:tool_call),
    do: %{tool: "query_db", args: %{}, result: %{}, classification: "read_only"}

  defp payload_for(:tool_error), do: %{tool: "query_db", args: %{}, reason: "timeout"}
  defp payload_for(:tool_hallucination), do: %{attempted_tool: "shell"}
  defp payload_for(:findings), do: %{findings: %{root_cause: "deploy_correlated"}}
  defp payload_for(:final_state), do: %{status: "completed", reason: nil}
end
