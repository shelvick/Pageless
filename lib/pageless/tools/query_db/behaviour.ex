defmodule Pageless.Tools.QueryDB.Behaviour do
  @moduledoc "Behaviour for injectable query_db tool implementations."

  alias Pageless.Governance.ToolCall

  @type ok_result :: %{
          rows: [list(term())],
          columns: [String.t()],
          num_rows: non_neg_integer(),
          truncated: boolean(),
          duration_ms: non_neg_integer(),
          command: String.t()
        }

  @type error_reason ::
          :invalid_args
          | {:sql_blocked, atom() | {atom(), String.t()}}
          | :statement_timeout
          | :query_failed

  @type error_result :: %{
          rows: nil,
          columns: nil,
          num_rows: nil,
          truncated: false,
          duration_ms: non_neg_integer(),
          command: String.t() | term(),
          reason: error_reason(),
          message: String.t() | nil
        }

  @type exec_opts :: [
          repo: module(),
          statement_timeout_ms: pos_integer(),
          max_rows: pos_integer(),
          function_blocklist: [String.t()],
          allowed_tables: [String.t()] | :all
        ]

  @doc "Executes a query_db tool call with default runtime options."
  @callback query(ToolCall.t()) :: {:ok, ok_result()} | {:error, error_result()}

  @doc "Executes a query_db tool call with explicit options."
  @callback query(ToolCall.t(), exec_opts()) :: {:ok, ok_result()} | {:error, error_result()}

  @doc "Returns the Gemini function declaration for this tool."
  @callback function_call_definition() :: map()
end
