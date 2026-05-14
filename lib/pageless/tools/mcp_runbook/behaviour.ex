defmodule Pageless.Tools.MCPRunbook.Behaviour do
  @moduledoc "Behaviour for injectable MCP runbook tool implementations."

  alias Pageless.Governance.ToolCall

  @type ok_result :: %{
          output: String.t(),
          exit_status: 0,
          command: [String.t()],
          duration_ms: non_neg_integer()
        }

  @type error_reason ::
          :invalid_args
          | :mcp_domain_error
          | {:mcp_error, term(), String.t()}
          | :mcp_unexpected

  @type error_result :: %{
          output: String.t() | nil,
          exit_status: 0 | 1 | nil,
          command: [String.t()],
          duration_ms: non_neg_integer(),
          reason: error_reason()
        }

  @type exec_opts :: [
          mcp_client: module(),
          client: GenServer.server() | nil,
          timeout: pos_integer() | nil
        ]

  @doc "Executes an MCP runbook tool call with default runtime options."
  @callback exec(ToolCall.t()) :: {:ok, ok_result()} | {:error, error_result()}

  @doc "Executes an MCP runbook tool call with explicit options."
  @callback exec(ToolCall.t(), exec_opts()) :: {:ok, ok_result()} | {:error, error_result()}

  @doc "Returns the Gemini function declaration for this tool."
  @callback function_call_definition() :: map()
end
