defmodule Pageless.Tools.QueryDBTest do
  @moduledoc "Tests the query_db read-only PostgreSQL wrapper."

  use Pageless.DataCase, async: true

  import Hammox

  alias Pageless.AuditTrail
  alias Pageless.AuditTrail.Decision
  alias Pageless.Config.Rules
  alias Pageless.Data.DeployLedger
  alias Pageless.Governance.CapabilityGate
  alias Pageless.Governance.ToolCall
  alias Pageless.Tools.QueryDB

  setup :verify_on_exit!

  setup do
    pubsub = unique_atom("query_db_pubsub")
    start_supervised!({Phoenix.PubSub, name: pubsub})

    %{pubsub: pubsub, rules: default_rules()}
  end

  describe "function_call_definition/0" do
    test "exposes a Gemini function-call declaration for profile-scoped catalogs" do
      declaration = QueryDB.function_call_definition()

      assert declaration["name"] == "query_db"
      assert declaration["parameters"]["type"] == "object"
      assert declaration["parameters"]["required"] == ["sql"]
      assert declaration["parameters"]["properties"]["sql"]["type"] == "string"
    end
  end

  describe "query/2" do
    test "returns the B4 deploy row from the literal demo SQL" do
      DeployLedger.seed_demo!(Repo, date: ~D[2026-05-13])
      sql = deploys_sql()

      assert {:ok, result} = QueryDB.query(tool_call(sql), repo: Repo)
      assert [["v2.4.1", deployed_at, "alex@"]] = result.rows
      assert DateTime.to_time(deployed_at) == ~T[03:43:58.000000]
      assert result.columns == ["version", "deployed_at", "deployed_by"]
      assert result.num_rows == 1
      assert result.truncated == false
      assert result.duration_ms >= 0
      assert result.command == sql
    end

    test "truncates rows when the query returns more than max_rows" do
      insert_deploy_versions(~w(v2.4.1 v2.4.2 v2.4.3 v2.4.4 v2.4.5))
      sql = "SELECT version FROM deploys WHERE service='payments-api' ORDER BY version"

      assert {:ok, result} = QueryDB.query(tool_call(sql), repo: Repo, max_rows: 3)

      assert result.rows == [["v2.4.1"], ["v2.4.2"], ["v2.4.3"]]
      assert result.columns == ["version"]
      assert result.num_rows == 3
      assert result.truncated == true
      assert result.command == sql
    end

    test "outer LIMIT caps relation-free result buffering before truncation" do
      sql = "SELECT * FROM generate_series(1, 1000000) AS s"

      assert {:ok, result} = QueryDB.query(tool_call(sql), repo: Repo, max_rows: 1_000)

      assert length(result.rows) == 1_000
      assert result.num_rows == 1_000
      assert result.truncated == true
      assert result.command == sql
    end

    test "wrapped query executes when inner SQL has a trailing single-line comment" do
      sql = "SELECT 1 -- trailing comment"

      assert {:ok, result} = QueryDB.query(tool_call(sql), repo: Repo, allowed_tables: :all)

      assert result.rows == [[1]]
      assert result.columns == ["?column?"]
      assert result.num_rows == 1
      assert result.truncated == false
      assert result.command == sql
    end

    test "plumbs allowed_tables into parser and rejects relation-free SQL" do
      sql = "SELECT * FROM generate_series(1, 100) AS s"

      assert {:error, result} =
               QueryDB.query(tool_call(sql), repo: Repo, allowed_tables: ["deploys"])

      assert result.reason == {:sql_blocked, :no_rangetable}
      assert result.rows == nil
      assert result.columns == nil
      assert result.num_rows == nil
      assert result.truncated == false
      assert result.command == sql
    end

    test "returns all rows when result count is below max_rows" do
      versions = ~w(v2.4.1 v2.4.2 v2.4.3 v2.4.4 v2.4.5)
      insert_deploy_versions(versions)
      sql = "SELECT version FROM deploys WHERE service='payments-api' ORDER BY version"

      assert {:ok, result} = QueryDB.query(tool_call(sql), repo: Repo, max_rows: 100)

      assert result.rows == Enum.map(versions, &[&1])
      assert result.num_rows == 5
      assert result.truncated == false
    end

    test "rejects DROP before touching the repo" do
      assert {:error, result} = QueryDB.query(tool_call("DROP TABLE deploys"), repo: Repo)
      assert result.reason == {:sql_blocked, :not_select}
      assert result.rows == nil
      assert result.columns == nil
      assert result.num_rows == nil
      assert result.truncated == false
      assert result.duration_ms >= 0
      assert result.command == "DROP TABLE deploys"

      assert Repo.query!("SELECT to_regclass('public.deploys')::text").rows == [["deploys"]]
    end

    test "rejects blocklisted state-modifying functions" do
      sql = "SELECT pg_terminate_backend(12345)"

      assert {:error, result} =
               QueryDB.query(tool_call(sql),
                 repo: Repo,
                 function_blocklist: ["pg_terminate_backend"]
               )

      assert result.reason == {:sql_blocked, {:state_modifying_function, "pg_terminate_backend"}}
      assert result.rows == nil
      assert result.columns == nil
      assert result.num_rows == nil
      assert result.truncated == false
      assert result.command == sql
    end

    test "rejects multi-statement SQL" do
      sql = "SELECT 1; DROP TABLE deploys"

      assert {:error, result} = QueryDB.query(tool_call(sql), repo: Repo)
      assert result.reason == {:sql_blocked, :multiple_statements}
      assert result.command == sql
    end

    test "rejects empty or non-binary args without touching the repo" do
      for args <- ["", "   ", "\n\t\n", nil, 123, ["SELECT", "1"]] do
        assert {:error, result} = QueryDB.query(tool_call(args), repo: Repo)
        assert result.reason == :invalid_args
        assert result.rows == nil
        assert result.columns == nil
        assert result.num_rows == nil
        assert result.truncated == false
        assert result.duration_ms == 0
        assert result.command == args
      end
    end

    test "raises FunctionClauseError for non-query_db tool calls" do
      assert_raise FunctionClauseError, fn ->
        QueryDB.query(tool_call(:kubectl, ["get", "pods"]), repo: Repo)
      end
    end

    test "returns statement_timeout for slow queries" do
      sql = "SELECT count(*) FROM generate_series(1, 100000000)"

      assert {:error, result} =
               QueryDB.query(tool_call(sql),
                 repo: Repo,
                 statement_timeout_ms: 50,
                 function_blocklist: []
               )

      assert result.reason == :statement_timeout
      assert is_binary(result.message)
      assert result.duration_ms >= 0
      assert result.command == sql
    end

    test "returns query_failed for missing tables" do
      sql = "SELECT * FROM nonexistent_table_xyz"

      assert {:error, result} = QueryDB.query(tool_call(sql), repo: Repo)
      assert result.reason == :query_failed
      assert result.message =~ "nonexistent_table_xyz"
      assert result.duration_ms >= 0
      assert result.command == sql
    end
  end

  describe "CapabilityGate integration" do
    @tag :acceptance
    test "B4 deploys query executes through the real wrapper and updates audit", %{
      pubsub: pubsub,
      rules: rules
    } do
      DeployLedger.seed_demo!(Repo, date: ~D[2026-05-13])
      sql = deploys_sql()
      call = tool_call(sql)
      Phoenix.PubSub.subscribe(pubsub, topic(call))

      dispatch = fn dispatched_call -> QueryDB.query(dispatched_call, repo: Repo) end

      assert {:ok, result} = CapabilityGate.request(call, rules, opts(pubsub, dispatch))
      assert [["v2.4.1", _deployed_at, "alex@"]] = result.rows
      assert result.columns == ["version", "deployed_at", "deployed_by"]
      assert result.truncated == false

      assert %Decision{
               decision: "executed",
               classification: "read",
               result_status: "ok",
               args: %{"sql" => ^sql}
             } = Repo.get_by(Decision, request_id: call.request_id)

      assert_receive {:gate_decision, :execute, ^call, :read, nil}
      assert_receive {:gate_decision, :executed, _gate_id, ^call, ^result}
      refute_received {:gate_fired, _, _, _, _, _}
    end

    @tag :acceptance
    test "DROP is rejected at the gate layer and never reaches the wrapper", %{
      pubsub: pubsub,
      rules: rules
    } do
      call = tool_call("DROP TABLE deploys")
      Phoenix.PubSub.subscribe(pubsub, topic(call))
      parent = self()

      dispatch = fn dispatched_call ->
        send(parent, {:dispatch, dispatched_call})
        QueryDB.query(dispatched_call, repo: Repo)
      end

      assert CapabilityGate.request(call, rules, opts(pubsub, dispatch)) == {:error, :not_select}

      assert %Decision{
               decision: "rejected",
               classification: "read",
               result_status: "error",
               args: %{"sql" => "DROP TABLE deploys"}
             } = decision = Repo.get_by(Decision, request_id: call.request_id)

      assert decision.result_summary =~ ":not_select"
      assert_receive {:gate_decision, :rejected, ^call, :read, :not_select}
      refute_received {:dispatch, _call}
      assert Repo.query!("SELECT to_regclass('public.deploys')::text").rows == [["deploys"]]
    end

    @tag :acceptance
    test "pg_terminate_backend is rejected at the gate before wrapper dispatch", %{
      pubsub: pubsub,
      rules: rules
    } do
      sql = "SELECT pg_terminate_backend(12345)"
      call = tool_call(sql)
      Phoenix.PubSub.subscribe(pubsub, topic(call))
      parent = self()

      dispatch = fn dispatched_call ->
        send(parent, {:dispatch, dispatched_call})
        QueryDB.query(dispatched_call, repo: Repo)
      end

      assert CapabilityGate.request(call, rules, opts(pubsub, dispatch)) ==
               {:error, {:state_modifying_function, "pg_terminate_backend"}}

      assert %Decision{
               decision: "rejected",
               classification: "read",
               result_status: "error",
               args: %{"sql" => ^sql}
             } = decision = Repo.get_by(Decision, request_id: call.request_id)

      assert decision.result_summary =~ "pg_terminate_backend"

      assert_receive {:gate_decision, :rejected, ^call, :read,
                      {:state_modifying_function, "pg_terminate_backend"}}

      refute_received {:dispatch, _call}
    end
  end

  describe "Hammox mock" do
    test "mock obeys the query_db behaviour contract" do
      call = tool_call("SELECT version FROM deploys")

      expected =
        {:ok,
         %{
           rows: [["fake"]],
           columns: ["version"],
           num_rows: 1,
           truncated: false,
           duration_ms: 0,
           command: "SELECT version FROM deploys"
         }}

      Pageless.Tools.QueryDB.Mock
      |> expect(:query, fn ^call -> expected end)

      assert Pageless.Tools.QueryDB.Mock.query(call) == expected
    end
  end

  defp opts(pubsub, dispatch) do
    [tool_dispatch: dispatch, pubsub: pubsub, repo: AuditTrail]
  end

  defp default_rules do
    Rules.load!(Path.expand("../../fixtures/pageless_rules/default.yaml", __DIR__))
  end

  defp deploys_sql do
    "SELECT version, deployed_at, deployed_by FROM deploys WHERE service='payments-api' ORDER BY deployed_at DESC LIMIT 5"
  end

  defp insert_deploy_versions(versions) do
    versions
    |> Enum.with_index(1)
    |> Enum.each(fn {version, index} ->
      Repo.insert!(%DeployLedger{
        service: "payments-api",
        version: version,
        deployed_at: DateTime.add(~U[2026-05-13 03:43:58.000000Z], index, :second),
        deployed_by: "alex@"
      })
    end)
  end

  defp tool_call(args), do: tool_call(:query_db, args)

  defp tool_call(tool, args) do
    struct(ToolCall, %{
      tool: tool,
      args: args,
      agent_id: Ecto.UUID.generate(),
      agent_pid_inspect: inspect(self()),
      alert_id: unique("alert"),
      request_id: unique("req"),
      reasoning_context: %{summary: "deploy lookup", evidence_link: "runbook://payments"}
    })
  end

  defp topic(%ToolCall{alert_id: alert_id}), do: "alert:#{alert_id}"

  defp unique(prefix), do: "#{prefix}_#{System.unique_integer([:positive])}"

  defp unique_atom(prefix), do: :erlang.binary_to_atom(unique(prefix), :utf8)
end
