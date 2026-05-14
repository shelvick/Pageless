defmodule Pageless.Tools.Kubectl.Behaviour do
  @moduledoc "Behaviour for injectable kubectl tool implementations."

  alias Pageless.Governance.ToolCall

  @type ok_result :: %{
          output: String.t(),
          exit_status: non_neg_integer(),
          command: [String.t()],
          duration_ms: non_neg_integer()
        }

  @type error_reason :: :invalid_args | :kubectl_not_found | :nonzero_exit

  @type error_result :: %{
          output: String.t() | nil,
          exit_status: integer() | nil,
          command: term(),
          duration_ms: non_neg_integer(),
          reason: error_reason()
        }

  @type exec_opts :: [
          binary: String.t(),
          kubeconfig: Path.t() | nil,
          timeout_ms: pos_integer()
        ]

  @doc "Executes a kubectl tool call with default runtime options."
  @callback exec(ToolCall.t()) :: {:ok, ok_result()} | {:error, error_result()}

  @doc "Executes a kubectl tool call with explicit options."
  @callback exec(ToolCall.t(), exec_opts()) :: {:ok, ok_result()} | {:error, error_result()}
end
