defmodule Pageless.Proc.Investigator.Audit do
  @moduledoc "Audit-row helpers for investigator profile violations and budget exhaustion."

  alias Pageless.Governance.VerbTableClassifier
  alias Pageless.Proc.Investigator.ToolArgs

  @type state :: map()

  @doc "Writes a terminal investigator audit row and logs failures without crashing the agent."
  @spec record_terminal(state(), atom(), term(), String.t(), String.t()) :: :ok
  def record_terminal(state, tool, args, decision, result_summary) do
    attrs = %{
      request_id: request_id(),
      alert_id: state.alert_id,
      agent_id: state.audit_agent_id,
      agent_pid_inspect: inspect(self()),
      tool: Atom.to_string(tool),
      args: ToolArgs.encode(tool, args),
      classification: best_effort_classify(state, tool, args),
      decision: decision,
      result_status: "error",
      result_summary: result_summary
    }

    case state.gate_repo.record_decision(attrs) do
      {:ok, _row} ->
        :ok

      {:error, reason} ->
        require Logger
        Logger.warning("failed to record investigator terminal audit: #{inspect(reason)}")
        :ok
    end
  end

  @doc "Writes the terminal audit row for an unknown Gemini tool call."
  @spec record_unknown_tool(state(), String.t(), map()) :: :ok
  def record_unknown_tool(state, name, args) do
    attrs = %{
      request_id: request_id(),
      alert_id: state.alert_id,
      agent_id: state.audit_agent_id,
      agent_pid_inspect: inspect(self()),
      tool: "unknown",
      args: %{"function_name" => name, "raw_args" => args},
      classification: "read",
      decision: "profile_violation",
      result_status: "error",
      result_summary: inspect({:out_of_scope_tool, name})
    }

    case state.gate_repo.record_decision(attrs) do
      {:ok, _row} ->
        :ok

      {:error, reason} ->
        require Logger
        Logger.warning("failed to record unknown-tool profile violation: #{inspect(reason)}")
        :ok
    end
  end

  @spec best_effort_classify(state(), atom(), term()) :: String.t()
  defp best_effort_classify(_state, :kubectl, {:malformed, _args}), do: "write_prod_high"

  defp best_effort_classify(state, :kubectl, args) do
    case VerbTableClassifier.classify(args, state.rules.kubectl_verbs) do
      {:ok, class, _verb} -> Atom.to_string(class)
      {:error, _reason} -> "write_prod_high"
    end
  end

  defp best_effort_classify(_state, _tool, _args), do: "read"

  @spec request_id() :: String.t()
  defp request_id, do: "investigator-req-#{System.unique_integer([:positive])}"
end
