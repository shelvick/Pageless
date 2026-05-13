defmodule Pageless.Svc.MCPClientTest.FakeResponse do
  @moduledoc "Small response struct used by MCP adapter tests."
  defstruct [:result]
end

defmodule Pageless.Svc.MCPClientTest.FakeMCPError do
  @moduledoc "Small protocol error struct used by MCP adapter tests."
  defstruct [:code, :message]
end

defmodule Pageless.Svc.MCPClientTest.FakeAnubis do
  @moduledoc "Deterministic Anubis-shaped test double for MCP adapter tests."

  alias Pageless.Svc.MCPClientTest.FakeMCPError
  alias Pageless.Svc.MCPClientTest.FakeResponse

  @doc "Returns canned MCP tool lists for adapter tests."
  @spec list_tools(term(), keyword()) :: {:ok, FakeResponse.t()} | {:error, FakeMCPError.t()}
  def list_tools(client, opts) do
    send(self(), {:list_tools_called, client, opts})

    case client do
      :empty -> {:ok, %FakeResponse{result: %{"tools" => []}}}
      :malformed -> {:ok, %FakeResponse{result: %{"tools" => "not-a-list"}}}
      :timeout -> {:error, %FakeMCPError{code: :timeout, message: "timed out"}}
      _client -> {:ok, %FakeResponse{result: %{"tools" => tools_fixture()}}}
    end
  end

  @doc "Returns canned MCP tool-call results for adapter tests."
  @spec call_tool(term(), String.t(), map(), keyword()) ::
          {:ok, FakeResponse.t()} | {:error, FakeMCPError.t()}
  def call_tool(client, name, arguments, opts) do
    send(self(), {:call_tool_called, client, name, arguments, opts})

    case {name, arguments} do
      {"protocol_error", _arguments} ->
        {:error, %FakeMCPError{code: -32_001, message: "server exploded"}}

      {"domain_error", _arguments} ->
        {:ok,
         %FakeResponse{
           result: %{
             "content" => [%{"type" => "text", "text" => "file not found"}],
             "isError" => true
           }
         }}

      {"mixed_content", _arguments} ->
        {:ok,
         %FakeResponse{
           result: %{
             "content" => [
               %{"type" => "text", "text" => "runbook contents"},
               %{"type" => "image", "data" => "base64-data", "mimeType" => "image/png"},
               %{"type" => "resource", "resource" => %{"uri" => "file:///runbook.md"}},
               %{"type" => "audio", "data" => "future-content"}
             ],
             "isError" => false
           }
         }}

      {_name, _arguments} ->
        {:ok,
         %FakeResponse{
           result: %{
             "content" => [%{"type" => "text", "text" => "hello from #{name}"}],
             "isError" => false
           }
         }}
    end
  end

  defp tools_fixture do
    [
      %{
        "name" => "read_file",
        "description" => "Read a runbook.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{"path" => %{"type" => "string"}},
          "required" => ["path"]
        }
      },
      %{
        "name" => "list_directory",
        "description" => nil,
        "inputSchema" => %{"type" => "object", "properties" => %{}}
      }
    ]
  end
end

defmodule Pageless.Svc.MCPClientTest do
  @moduledoc "Tests the MCP client adapter contract and normalization rules."
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Hammox

  alias Pageless.Svc.MCPClient
  alias Pageless.Svc.MCPClient.Behaviour
  alias Pageless.Svc.MCPClient.Tool
  alias Pageless.Svc.MCPClient.ToolResult
  alias Pageless.Svc.MCPClientTest.FakeAnubis

  setup :verify_on_exit!

  describe "behaviour and structs" do
    test "behaviour exposes only list_tools/1 and call_tool/3" do
      callbacks = Behaviour.behaviour_info(:callbacks)

      assert Enum.sort(callbacks) == [call_tool: 3, list_tools: 1]
    end

    test "tool and result structs define the adapter contract" do
      tool =
        struct(Tool,
          name: "read_file",
          description: nil,
          input_schema: %{"type" => "object"}
        )

      result =
        struct(ToolResult,
          content: [%{type: :text, text: "contents"}],
          is_error: false,
          raw: %{"isError" => false}
        )

      assert tool.name == "read_file"
      assert tool.description == nil
      assert tool.input_schema == %{"type" => "object"}
      assert result.content == [%{type: :text, text: "contents"}]
      assert result.is_error == false
      assert result.raw == %{"isError" => false}
    end

    test "Hammox mock supports list and call callbacks" do
      Pageless.Svc.MCPClient.Mock
      |> stub(:list_tools, fn opts ->
        assert Keyword.fetch!(opts, :profile) == :runbook
        {:ok, [struct(Tool, name: "read_file", description: "Read.", input_schema: %{})]}
      end)
      |> stub(:call_tool, fn name, arguments, opts ->
        assert name == "read_file"
        assert arguments == %{"path" => "/runbooks/payments.md"}
        assert Keyword.fetch!(opts, :profile) == :runbook

        {:ok,
         struct(ToolResult,
           content: [%{type: :text, text: "runbook"}],
           is_error: false,
           raw: %{}
         )}
      end)

      alias Pageless.Svc.MCPClient.Mock

      assert {:ok, [%Tool{name: "read_file"}]} = Mock.list_tools(profile: :runbook)

      assert {:ok, %ToolResult{content: [%{type: :text, text: "runbook"}]}} =
               Mock.call_tool("read_file", %{"path" => "/runbooks/payments.md"},
                 profile: :runbook
               )
    end
  end

  describe "list_tools/1" do
    test "normalizes upstream MCP tools into Pageless tool structs" do
      assert {:ok, tools} =
               MCPClient.list_tools(
                 client: :fake_client,
                 timeout: 250,
                 anubis_module: FakeAnubis
               )

      assert [read_file, list_directory] = tools
      assert %Tool{} = read_file
      assert read_file.name == "read_file"
      assert read_file.description == "Read a runbook."

      assert read_file.input_schema == %{
               "type" => "object",
               "properties" => %{"path" => %{"type" => "string"}},
               "required" => ["path"]
             }

      assert %Tool{name: "list_directory", description: nil} = list_directory

      assert_received {:list_tools_called, :fake_client, anubis_opts}
      assert anubis_opts[:timeout] == 250
    end

    test "returns an empty list for an empty upstream tool catalog" do
      assert {:ok, []} = MCPClient.list_tools(client: :empty, anubis_module: FakeAnubis)
    end

    test "wraps upstream protocol errors without raising" do
      assert {:error, {:mcp_error, :timeout, "timed out"}} =
               MCPClient.list_tools(client: :timeout, anubis_module: FakeAnubis)
    end

    test "returns generic errors and logs malformed upstream shapes" do
      log =
        capture_log(fn ->
          assert {:error, {:mcp_unexpected, %{"tools" => "not-a-list"}}} =
                   MCPClient.list_tools(client: :malformed, anubis_module: FakeAnubis)
        end)

      assert log =~ "mcp_unexpected"
    end
  end

  describe "call_tool/3" do
    test "normalizes text tool results and passes arguments through" do
      assert {:ok, result} =
               MCPClient.call_tool(
                 "read_file",
                 %{"path" => "/runbooks/payments.md"},
                 client: :fake_client,
                 timeout: 500,
                 anubis_module: FakeAnubis
               )

      assert %ToolResult{} = result
      assert result.content == [%{type: :text, text: "hello from read_file"}]
      assert result.is_error == false
      assert result.raw["isError"] == false

      assert_received {:call_tool_called, :fake_client, "read_file",
                       %{"path" => "/runbooks/payments.md"}, anubis_opts}

      assert anubis_opts[:timeout] == 500
    end

    test "accepts an empty arguments map" do
      assert {:ok, %ToolResult{content: [%{type: :text, text: "hello from list_directory"}]}} =
               MCPClient.call_tool("list_directory", %{},
                 client: :fake_client,
                 anubis_module: FakeAnubis
               )

      assert_received {:call_tool_called, :fake_client, "list_directory", %{}, _opts}
    end

    test "normalizes all supported content block types" do
      assert {:ok, %ToolResult{} = result} =
               MCPClient.call_tool("mixed_content", %{},
                 client: :fake_client,
                 anubis_module: FakeAnubis
               )

      assert result.content == [
               %{type: :text, text: "runbook contents"},
               %{type: :image, data: "base64-data", mime_type: "image/png"},
               %{type: :resource, resource: %{"uri" => "file:///runbook.md"}},
               %{type: :unknown, raw: %{"type" => "audio", "data" => "future-content"}}
             ]
    end

    test "keeps domain-level MCP tool errors inside ToolResult" do
      assert {:ok, %ToolResult{is_error: true, content: [%{type: :text, text: "file not found"}]}} =
               MCPClient.call_tool("domain_error", %{},
                 client: :fake_client,
                 anubis_module: FakeAnubis
               )
    end

    test "wraps protocol-level MCP errors" do
      assert {:error, {:mcp_error, -32_001, "server exploded"}} =
               MCPClient.call_tool("protocol_error", %{},
                 client: :fake_client,
                 anubis_module: FakeAnubis
               )
    end
  end
end
