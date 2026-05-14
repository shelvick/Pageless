defmodule Pageless.Tools.MCPRunbookTest do
  @moduledoc "Tests the MCP runbook dispatch wrapper without a live MCP server."

  use Pageless.DataCase, async: true

  import Hammox

  alias Pageless.AuditTrail
  alias Pageless.AuditTrail.Decision
  alias Pageless.Config.Rules
  alias Pageless.Governance.CapabilityGate
  alias Pageless.Governance.ToolCall
  alias Pageless.Repo
  alias Pageless.Svc.MCPClient.ToolResult
  alias Pageless.Tools.MCPRunbook

  setup :verify_on_exit!

  setup do
    pubsub = unique_atom("mcp_runbook_pubsub")
    start_supervised!({Phoenix.PubSub, name: pubsub})

    %{pubsub: pubsub, rules: default_rules()}
  end

  describe "function_call_definition/0" do
    test "exposes a Gemini function-call declaration for profile-scoped catalogs" do
      declaration = MCPRunbook.function_call_definition()

      assert declaration["name"] == "mcp_runbook"
      assert declaration["parameters"]["type"] == "object"
      assert declaration["parameters"]["required"] == ["tool_name", "params"]
      assert declaration["parameters"]["properties"]["tool_name"]["type"] == "string"
      assert declaration["parameters"]["properties"]["params"]["type"] == "object"
    end
  end

  describe "exec/2" do
    test "reads the B4 runbook path through the injected MCP client" do
      path = "runbooks/payments-api/connection-errors.md"
      output = "# Payments-API: Connection Errors\n\n1. Check upstream payments-db..."
      call = tool_call(%{"tool_name" => "read_file", "params" => %{"path" => path}})

      expect_mcp_call("read_file", %{"path" => path}, fn opts ->
        assert opts == []
        {:ok, tool_result([text_block(output)])}
      end)

      assert {:ok, result} = MCPRunbook.exec(call, mcp_client: Pageless.Svc.MCPClient.Mock)
      assert result.output == output
      assert result.exit_status == 0
      assert result.command == ["read_file", "path=#{path}"]
      assert result.duration_ms >= 0
    end

    test "passes explicit client and timeout options to the MCP adapter" do
      call = tool_call(%{"tool_name" => "list_directory", "params" => %{"path" => "runbooks"}})

      expect_mcp_call("list_directory", %{"path" => "runbooks"}, fn opts ->
        assert opts == [client: :filesystem_client, timeout: 1_500]
        {:ok, tool_result([text_block("payments-api")])}
      end)

      assert {:ok, %{output: "payments-api"}} =
               MCPRunbook.exec(call,
                 mcp_client: Pageless.Svc.MCPClient.Mock,
                 client: :filesystem_client,
                 timeout: 1_500
               )
    end

    test "concatenates text blocks without separators" do
      call = tool_call(%{"tool_name" => "read_file", "params" => %{"path" => "runbook.md"}})

      expect_mcp_call("read_file", %{"path" => "runbook.md"}, fn _opts ->
        {:ok,
         tool_result([
           text_block("Header\n"),
           text_block("Body line 1\n"),
           text_block("Body line 2")
         ])}
      end)

      assert {:ok, %{output: "Header\nBody line 1\nBody line 2"}} =
               MCPRunbook.exec(call, mcp_client: Pageless.Svc.MCPClient.Mock)
    end

    test "drops non-text blocks from output" do
      call = tool_call(%{"tool_name" => "read_file", "params" => %{"path" => "runbook.md"}})

      expect_mcp_call("read_file", %{"path" => "runbook.md"}, fn _opts ->
        {:ok,
         tool_result([
           text_block("lead\n"),
           %{type: :image, data: <<1, 2, 3>>, mime_type: "image/png"},
           %{type: :resource, resource: %{"uri" => "file:///runbook.md"}},
           text_block("tail")
         ])}
      end)

      assert {:ok, %{output: "lead\ntail"}} =
               MCPRunbook.exec(call, mcp_client: Pageless.Svc.MCPClient.Mock)
    end

    test "returns an empty output string for an empty content list" do
      call = tool_call(%{"tool_name" => "read_file", "params" => %{"path" => "empty.md"}})

      expect_mcp_call("read_file", %{"path" => "empty.md"}, fn _opts ->
        {:ok, tool_result([])}
      end)

      assert {:ok, %{output: "", exit_status: 0}} =
               MCPRunbook.exec(call, mcp_client: Pageless.Svc.MCPClient.Mock)
    end

    test "maps MCP domain errors to execution errors with text output" do
      call = tool_call(%{"tool_name" => "read_file", "params" => %{"path" => "missing.md"}})

      expect_mcp_call("read_file", %{"path" => "missing.md"}, fn _opts ->
        {:ok, tool_result([text_block("File not found: missing.md")], is_error: true)}
      end)

      assert {:error, result} = MCPRunbook.exec(call, mcp_client: Pageless.Svc.MCPClient.Mock)
      assert result.reason == :mcp_domain_error
      assert result.exit_status == 1
      assert result.output == "File not found: missing.md"
      assert result.command == ["read_file", "path=missing.md"]
      assert result.duration_ms >= 0
    end

    test "maps protocol-level MCP errors" do
      call = tool_call(%{"tool_name" => "read_file", "params" => %{"path" => "runbook.md"}})

      expect_mcp_call("read_file", %{"path" => "runbook.md"}, fn _opts ->
        {:error, {:mcp_error, :timeout, "stdio transport timeout"}}
      end)

      assert {:error, result} = MCPRunbook.exec(call, mcp_client: Pageless.Svc.MCPClient.Mock)
      assert result.reason == {:mcp_error, :timeout, "stdio transport timeout"}
      assert result.output == nil
      assert result.exit_status == nil
      assert result.command == ["read_file", "path=runbook.md"]
      assert result.duration_ms >= 0
    end

    test "maps unexpected MCP adapter responses" do
      call = tool_call(%{"tool_name" => "read_file", "params" => %{"path" => "runbook.md"}})

      expect_mcp_call("read_file", %{"path" => "runbook.md"}, fn _opts ->
        {:error, {:mcp_unexpected, %{"weird" => "shape"}}}
      end)

      assert {:error, result} = MCPRunbook.exec(call, mcp_client: Pageless.Svc.MCPClient.Mock)
      assert result.reason == :mcp_unexpected
      assert result.output == nil
      assert result.exit_status == nil
      assert result.duration_ms >= 0
    end

    test "wraps unknown adapter error tuples in the gate-compatible error envelope" do
      call = tool_call(%{"tool_name" => "read_file", "params" => %{"path" => "runbook.md"}})

      expect_mcp_call("read_file", %{"path" => "runbook.md"}, fn _opts ->
        {:error, :something_unexpected}
      end)

      assert {:error, result} = MCPRunbook.exec(call, mcp_client: Pageless.Svc.MCPClient.Mock)
      assert result.reason == {:mcp_error, :unexpected, ":something_unexpected"}
      assert result.output == nil
      assert result.exit_status == nil
      assert result.command == ["read_file", "path=runbook.md"]
      assert result.duration_ms >= 0
    end

    test "rejects non-map args without invoking the MCP client" do
      expect(Pageless.Svc.MCPClient.Mock, :call_tool, 0, fn _name, _params, _opts ->
        flunk("invalid args must not call MCP")
      end)

      assert {:error, result} =
               MCPRunbook.exec(tool_call("not a map"), mcp_client: Pageless.Svc.MCPClient.Mock)

      assert result == %{
               reason: :invalid_args,
               output: nil,
               exit_status: nil,
               command: [],
               duration_ms: 0
             }
    end

    test "rejects maps missing required keys without invoking the MCP client" do
      for args <- [%{}, %{"tool_name" => "read_file"}, %{"params" => %{}}] do
        expect(Pageless.Svc.MCPClient.Mock, :call_tool, 0, fn _name, _params, _opts ->
          flunk("invalid args must not call MCP")
        end)

        assert {:error, result} =
                 MCPRunbook.exec(tool_call(args), mcp_client: Pageless.Svc.MCPClient.Mock)

        assert result.reason == :invalid_args
        assert result.output == nil
        assert result.exit_status == nil
        assert result.command == []
        assert result.duration_ms == 0
      end
    end

    test "rejects wrong required key types without invoking the MCP client" do
      for args <- [
            %{"tool_name" => :read_file, "params" => %{}},
            %{"tool_name" => "read_file", "params" => "not a map"}
          ] do
        expect(Pageless.Svc.MCPClient.Mock, :call_tool, 0, fn _name, _params, _opts ->
          flunk("invalid args must not call MCP")
        end)

        assert {:error, result} =
                 MCPRunbook.exec(tool_call(args), mcp_client: Pageless.Svc.MCPClient.Mock)

        assert result.reason == :invalid_args
        assert result.output == nil
        assert result.exit_status == nil
        assert result.command == []
        assert result.duration_ms == 0
      end
    end
  end

  describe "CapabilityGate integration" do
    @tag :acceptance
    test "read runbook request auto-executes through the real gate and audit trail", %{
      pubsub: pubsub,
      rules: rules
    } do
      path = "runbooks/payments-api/connection-errors.md"
      output = "# Payments-API: Connection Errors\n\n1. Check upstream payments-db..."
      call = tool_call(%{"tool_name" => "read_file", "params" => %{"path" => path}})
      Phoenix.PubSub.subscribe(pubsub, topic(call))

      expect_mcp_call("read_file", %{"path" => path}, fn _opts ->
        {:ok, tool_result([text_block(output)])}
      end)

      dispatch = fn dispatched_call ->
        MCPRunbook.exec(dispatched_call, mcp_client: Pageless.Svc.MCPClient.Mock)
      end

      assert {:ok, result} = CapabilityGate.request(call, rules, opts(pubsub, dispatch))
      assert result.output == output
      assert result.exit_status == 0
      assert result.command == ["read_file", "path=#{path}"]

      assert %Decision{
               decision: "executed",
               tool: "mcp_runbook",
               args: %{"tool_name" => "read_file", "params" => %{"path" => ^path}},
               extracted_verb: nil,
               classification: "read",
               result_status: "ok"
             } = decision = Repo.get_by(Decision, request_id: call.request_id)

      assert decision.result_summary =~ "Payments-API"
      assert_receive {:gate_decision, :execute, ^call, :read, nil}
      assert_receive {:gate_decision, :executed, _gate_id, ^call, ^result}
      refute_received {:gate_fired, _, _, _, _, _}
    end

    @tag :acceptance
    test "MCP domain errors update the real audit row as execution_failed", %{
      pubsub: pubsub,
      rules: rules
    } do
      path = "missing.md"
      call = tool_call(%{"tool_name" => "read_file", "params" => %{"path" => path}})
      Phoenix.PubSub.subscribe(pubsub, topic(call))

      expect_mcp_call("read_file", %{"path" => path}, fn _opts ->
        {:ok, tool_result([text_block("File not found")], is_error: true)}
      end)

      dispatch = fn dispatched_call ->
        MCPRunbook.exec(dispatched_call, mcp_client: Pageless.Svc.MCPClient.Mock)
      end

      assert {:error, %{reason: :mcp_domain_error} = result} =
               CapabilityGate.request(call, rules, opts(pubsub, dispatch))

      assert result.output == "File not found"
      assert result.exit_status == 1

      assert %Decision{
               decision: "execution_failed",
               tool: "mcp_runbook",
               args: %{"tool_name" => "read_file", "params" => %{"path" => ^path}},
               extracted_verb: nil,
               classification: "read",
               result_status: "error"
             } = decision = Repo.get_by(Decision, request_id: call.request_id)

      assert decision.result_summary =~ ":mcp_domain_error"
      assert_receive {:gate_decision, :execute, ^call, :read, nil}
      assert_receive {:gate_decision, :execution_failed, _gate_id, ^call, ^result}
      refute_received {:gate_fired, _, _, _, _, _}
    end
  end

  describe "Hammox mock" do
    test "mock obeys the MCP runbook behaviour contract" do
      call = tool_call(%{"tool_name" => "read_file", "params" => %{"path" => "runbook.md"}})
      expected = {:ok, %{output: "fake", exit_status: 0, command: ["fake"], duration_ms: 0}}

      Pageless.Tools.MCPRunbook.Mock
      |> expect(:exec, fn ^call -> expected end)

      assert Pageless.Tools.MCPRunbook.Mock.exec(call) == expected
    end
  end

  defp opts(pubsub, dispatch) do
    [tool_dispatch: dispatch, pubsub: pubsub, repo: AuditTrail]
  end

  defp expect_mcp_call(name, params, result_fun) do
    Pageless.Svc.MCPClient.Mock
    |> expect(:call_tool, fn ^name, ^params, opts -> result_fun.(opts) end)
  end

  defp tool_result(content, opts \\ []) do
    %ToolResult{content: content, is_error: Keyword.get(opts, :is_error, false), raw: %{}}
  end

  defp text_block(text), do: %{type: :text, text: text}

  defp default_rules do
    Rules.load!(Path.expand("../../fixtures/pageless_rules/default.yaml", __DIR__))
  end

  defp tool_call(args), do: tool_call(:mcp_runbook, args)

  defp tool_call(tool, args) do
    struct(ToolCall, %{
      tool: tool,
      args: args,
      agent_id: Ecto.UUID.generate(),
      agent_pid_inspect: inspect(self()),
      alert_id: unique("alert"),
      request_id: unique("req"),
      reasoning_context: %{summary: "read runbook", evidence_link: "runbook://payments"}
    })
  end

  defp topic(%ToolCall{alert_id: alert_id}), do: "alert:#{alert_id}"

  defp unique(prefix), do: "#{prefix}_#{System.unique_integer([:positive])}"

  defp unique_atom(prefix), do: :erlang.binary_to_atom(unique(prefix), :utf8)
end
