defmodule Pageless.Governance.ToolCall do
  @moduledoc """
  Envelope for agent-emitted tool calls sent through the capability gate.
  """

  @type tool_name :: :kubectl | :prometheus_query | :query_db | :mcp_runbook | atom()

  @type t :: %__MODULE__{
          tool: tool_name(),
          args: term(),
          agent_id: String.t(),
          agent_pid_inspect: String.t() | nil,
          alert_id: String.t(),
          request_id: String.t(),
          reasoning_context: %{summary: String.t(), evidence_link: String.t() | nil} | map()
        }

  @enforce_keys [:tool, :args, :agent_id, :alert_id, :request_id]
  defstruct [
    :tool,
    :args,
    :agent_id,
    :agent_pid_inspect,
    :alert_id,
    :request_id,
    reasoning_context: %{}
  ]
end
