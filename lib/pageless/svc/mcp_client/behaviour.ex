defmodule Pageless.Svc.MCPClient.Behaviour do
  @moduledoc "Callbacks for injectable MCP client implementations."

  alias Pageless.Svc.MCPClient.Tool
  alias Pageless.Svc.MCPClient.ToolResult

  @type list_opts :: keyword()

  @type call_opts :: keyword()

  @doc "Lists available MCP tools."
  @callback list_tools(list_opts()) :: {:ok, [Tool.t()]} | {:error, term()}

  @doc "Calls an MCP tool with JSON-compatible arguments."
  @callback call_tool(String.t(), map(), call_opts()) :: {:ok, ToolResult.t()} | {:error, term()}
end
