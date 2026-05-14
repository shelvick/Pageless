defmodule Pageless.Tools.PrometheusQuery.Behaviour do
  @moduledoc "Behaviour for injectable Prometheus query tool implementations."

  alias Pageless.Governance.ToolCall

  @type result_type :: :vector | :matrix | :scalar | :string

  @type sample :: %{
          metric: %{String.t() => String.t()},
          value: {number(), String.t()} | nil,
          values: [{number(), String.t()}] | nil
        }

  @type ok_result :: %{
          result_type: result_type(),
          samples: [sample()],
          raw: map(),
          duration_ms: non_neg_integer(),
          promql: String.t()
        }

  @type error_reason ::
          :invalid_args | :promql_error | :http_error | :network_error | :decode_error

  @type error_result :: %{
          reason: error_reason(),
          promql: String.t() | nil,
          http_status: pos_integer() | nil,
          error_type: String.t() | nil,
          error: String.t() | nil,
          duration_ms: non_neg_integer()
        }

  @type exec_opts :: [
          base_url: String.t(),
          timeout_ms: pos_integer(),
          auth_token: String.t() | nil,
          req_module: module()
        ]

  @doc "Executes a Prometheus query tool call with default runtime options."
  @callback exec(ToolCall.t()) :: {:ok, ok_result()} | {:error, error_result()}

  @doc "Executes a Prometheus query tool call with explicit options."
  @callback exec(ToolCall.t(), exec_opts()) :: {:ok, ok_result()} | {:error, error_result()}

  @doc "Returns the Gemini function declaration for this tool."
  @callback function_call_definition() :: map()
end
