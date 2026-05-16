defmodule Pageless.Proc.Investigator do
  @moduledoc "Profile-scoped investigator agent that reasons with Gemini and gated tools."

  use GenServer

  require Logger

  alias Ecto.Adapters.SQL.Sandbox
  alias Pageless.AlertEnvelope
  alias Pageless.Config.Rules
  alias Pageless.Data.AgentState
  alias Pageless.Governance.ToolCall
  alias Pageless.Proc.Investigator.Audit
  alias Pageless.Proc.Investigator.Events
  alias Pageless.Proc.Investigator.Gemini
  alias Pageless.Proc.Investigator.JsonSafe
  alias Pageless.Proc.Investigator.Profile
  alias Pageless.Proc.Investigator.ProfileScope
  alias Pageless.Proc.Investigator.Prompt
  alias Pageless.Proc.Investigator.ScopeGuard
  alias Pageless.Proc.Investigator.ToolArgs
  alias Pageless.Sup.Alert.State, as: AlertState
  alias Pageless.Svc.GeminiClient.Chunk
  alias Pageless.Svc.GeminiClient.FunctionCall

  defstruct [
    :agent_id,
    :alert_id,
    :envelope,
    :profile,
    :pubsub,
    :gemini_client,
    :sandbox_owner,
    :audit_repo,
    :parent,
    :rules,
    :gate_module,
    :gate_repo,
    :tool_dispatch,
    :alert_state_pid,
    :audit_agent_id,
    :tools,
    :active_ref,
    :prompt,
    current_text: "",
    sequence: 0,
    steps: 0
  ]

  @type opts :: [
          alert_id: String.t(),
          envelope: AlertEnvelope.t(),
          profile: Profile.t(),
          pubsub: atom(),
          gemini_client: module(),
          sandbox_owner: pid() | nil,
          audit_repo: module(),
          parent: pid() | nil,
          rules: Rules.t(),
          gate_module: module(),
          gate_repo: module(),
          tool_dispatch: (ToolCall.t() -> {:ok, term()} | {:error, term()}),
          alert_state_pid: pid() | nil
        ]

  @type t :: %__MODULE__{
          agent_id: String.t(),
          alert_id: String.t(),
          envelope: AlertEnvelope.t(),
          profile: Profile.t(),
          pubsub: atom(),
          gemini_client: module(),
          sandbox_owner: pid() | nil,
          audit_repo: module(),
          parent: pid() | nil,
          rules: Rules.t(),
          gate_module: module(),
          gate_repo: module(),
          tool_dispatch: (ToolCall.t() -> {:ok, term()} | {:error, term()}),
          alert_state_pid: pid() | nil,
          audit_agent_id: Ecto.UUID.t(),
          tools: [map()],
          active_ref: reference() | nil,
          prompt: String.t() | nil,
          current_text: String.t(),
          sequence: non_neg_integer(),
          steps: non_neg_integer()
        }

  @tool_modules %{
    kubectl: Pageless.Tools.Kubectl,
    prometheus_query: Pageless.Tools.PrometheusQuery,
    query_db: Pageless.Tools.QueryDB,
    mcp_runbook: Pageless.Tools.MCPRunbook
  }

  @doc "Starts an investigator process."
  @spec start_link(opts()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Triggers the explicit investigation run after setup and test-double allowance."
  @spec kick_off(GenServer.server()) :: :ok
  def kick_off(server), do: send(server, :run) |> then(fn _ -> :ok end)

  @doc "Checks whether a profile permits a tool call before it reaches the gate."
  @spec tool_call_in_profile_scope?(Profile.t(), atom(), term()) ::
          :ok
          | {:error, {:out_of_scope_tool, atom()}}
          | {:error, {:verb_not_in_profile, String.t()}}
          | {:error, {:table_not_in_profile_allowlist, String.t()}}
  def tool_call_in_profile_scope?(%Profile{} = profile, tool, args) do
    ProfileScope.allowed?(profile, tool, args)
  end

  @impl true
  def init(opts) do
    profile = Keyword.fetch!(opts, :profile)

    state = %__MODULE__{
      agent_id: "investigator-#{System.unique_integer([:positive])}",
      alert_id: Keyword.fetch!(opts, :alert_id),
      envelope: Keyword.fetch!(opts, :envelope),
      profile: profile,
      pubsub: Keyword.fetch!(opts, :pubsub),
      gemini_client: Keyword.fetch!(opts, :gemini_client),
      sandbox_owner: Keyword.get(opts, :sandbox_owner),
      audit_repo: Keyword.fetch!(opts, :audit_repo),
      parent: Keyword.get(opts, :parent),
      rules: Keyword.fetch!(opts, :rules),
      gate_module: Keyword.get(opts, :gate_module, Pageless.Governance.CapabilityGate),
      gate_repo: Keyword.get(opts, :gate_repo, Pageless.AuditTrail),
      tool_dispatch: Keyword.fetch!(opts, :tool_dispatch),
      alert_state_pid: Keyword.get(opts, :alert_state_pid),
      audit_agent_id: Ecto.UUID.generate(),
      tools: Profile.build_gemini_function_schema(profile, @tool_modules)
    }

    {:ok, state, {:continue, :setup}}
  end

  @impl true
  def handle_continue(:setup, state) do
    allow_sandbox(state)

    state =
      state
      |> Events.append(:spawned, %{profile: state.profile.name, label: state.profile.label})
      |> Events.broadcast({:investigator_spawned, state.alert_id, state.profile.name, self()})

    {:noreply, state}
  end

  @impl true
  def handle_call(:get_state, {caller, _tag}, state) do
    maybe_allow_hammox(state.gemini_client, caller)
    maybe_allow_hammox(state.gate_repo, caller)
    {:reply, {:ok, state}, state}
  end

  @impl true
  def handle_info(:run, state) do
    state
    |> Map.put(:prompt, Gemini.render_prompt(state.profile, state.envelope))
    |> Map.put(:current_text, "")
    |> start_turn()
  end

  def handle_info(
        {:gemini_chunk, ref, %Chunk{type: :text, text: text}},
        %{active_ref: ref} = state
      ) do
    state =
      state
      |> append_text(text)
      |> Events.append(:reasoning_line, %{text: text})
      |> Events.broadcast({:reasoning_line, state.agent_id, state.alert_id, text})

    {:noreply, state}
  end

  def handle_info(
        {:gemini_chunk, ref, %Chunk{type: :function_call, function_call: call}},
        %{active_ref: ref} = state
      ) do
    handle_function_call(call, state)
  end

  def handle_info({:gemini_done, ref, _final}, %{active_ref: ref} = state) do
    complete_turn(state)
  end

  def handle_info({:gemini_error, ref, reason}, %{active_ref: ref} = state) do
    state
    |> append(:tool_error, %{tool: "gemini.start_stream", reason: JsonSafe.convert(reason)})
    |> broadcast({:investigation_failed, state.alert_id, state.profile.name, :gemini_unavailable})
    |> notify_parent(%{status: :failed, reason: reason})
    |> append(:final_state, %{outcome: :failed, reason: JsonSafe.convert(reason)})
    |> then(&{:stop, :normal, &1})
  end

  def handle_info({:gemini_chunk, _ref, _chunk}, state), do: {:noreply, state}
  def handle_info({:gemini_done, _ref, _final}, state), do: {:noreply, state}
  def handle_info({:gemini_error, _ref, _reason}, state), do: {:noreply, state}
  def handle_info({:gate_result, _gate_id, _result}, state), do: {:noreply, state}
  def handle_info(_message, state), do: {:noreply, state}

  @spec start_turn(t()) :: {:noreply, t()} | {:stop, :normal, t()}
  defp start_turn(%{steps: steps, profile: %{step_limit: limit}} = state) when steps >= limit do
    no_findings(state)
  end

  defp start_turn(state) do
    case state.gemini_client.start_stream(Prompt.gemini_opts(state)) do
      {:ok, ref} ->
        {:noreply, %{state | active_ref: ref, current_text: "", steps: state.steps + 1}}

      {:error, reason} ->
        state
        |> append(:tool_error, %{tool: "gemini.start_stream", reason: JsonSafe.convert(reason)})
        |> broadcast(
          {:investigation_failed, state.alert_id, state.profile.name, :gemini_unavailable}
        )
        |> notify_parent(%{status: :failed, reason: reason})
        |> append(:final_state, %{outcome: :failed, reason: JsonSafe.convert(reason)})
        |> then(&{:stop, :normal, &1})
    end
  end

  @spec handle_function_call(FunctionCall.t() | nil, t()) ::
          {:noreply, t()} | {:stop, :normal, t()}
  defp handle_function_call(%FunctionCall{name: name, args: args}, state) when is_map(args) do
    case tool_atom(name) do
      nil ->
        handle_unknown_tool(name, args, state)

      tool ->
        case ToolArgs.normalize(tool, args) do
          {:ok, call_args} ->
            case ProfileScope.allowed?(state.profile, tool, call_args) do
              :ok -> handle_in_scope_tool_call(tool, args, call_args, state)
              {:error, reason} -> handle_profile_violation(tool, args, call_args, reason, state)
            end

          {:error, reason} ->
            handle_profile_violation(tool, args, {:malformed, args}, reason, state)
        end
    end
  end

  defp handle_function_call(_call, state), do: start_turn(state)

  @spec complete_turn(t()) :: {:stop, :normal, t()}
  defp complete_turn(state) do
    case Gemini.decode_findings(state.current_text) do
      {:ok, findings} -> complete_success(state, findings)
      :error -> no_findings(state)
    end
  end

  @spec complete_success(t(), map()) :: {:stop, :normal, t()}
  defp complete_success(state, findings) do
    state =
      state
      |> Events.append(:findings, findings)
      |> Events.broadcast({:investigation_complete, state.alert_id, state.profile.name, findings})
      |> Events.notify_parent(findings)
      |> Events.append(:final_state, %{outcome: :complete})

    {:stop, :normal, state}
  end

  @spec no_findings(t()) :: {:stop, :normal, t()}
  defp no_findings(state) do
    findings = %{status: :no_findings, reason: :step_limit}

    state =
      state
      |> Events.append(:findings, findings)
      |> Events.notify_parent(findings)
      |> Events.append(:final_state, %{outcome: :no_findings, reason: :step_limit})

    {:stop, :normal, state}
  end

  @spec handle_unknown_tool(String.t(), map(), t()) :: {:noreply, t()}
  defp handle_unknown_tool(name, args, state) do
    :ok = Audit.record_unknown_tool(state, name, args)

    state =
      state
      |> Events.append(:tool_hallucination, %{attempted_tool: name})
      |> Events.broadcast(
        {:profile_violation, state.agent_id, :unknown, {:out_of_scope_tool, name}}
      )

    {:noreply, %{state | active_ref: nil}}
  end

  @spec handle_profile_violation(atom(), map(), term(), term(), t()) :: {:noreply, t()}
  defp handle_profile_violation(tool, _raw_args, call_args, reason, state) do
    :ok = Audit.record_terminal(state, tool, call_args, "profile_violation", inspect(reason))

    state =
      state
      |> append(:tool_hallucination, %{
        attempted_tool: Atom.to_string(tool),
        reason: JsonSafe.convert(reason)
      })
      |> broadcast({:profile_violation, state.agent_id, tool, reason})

    {:noreply, %{state | active_ref: nil}}
  end

  @spec handle_in_scope_tool_call(atom(), map(), term(), t()) ::
          {:noreply, t()} | {:stop, :normal, t()}
  defp handle_in_scope_tool_call(tool, raw_args, call_args, state) do
    case claim_tool_budget(state) do
      :ok ->
        result = request_gate(state, tool, call_args)
        class = ScopeGuard.classification(result)
        result_value = ScopeGuard.result_value(result)

        state =
          state
          |> Events.append(:tool_call, %{
            tool: Atom.to_string(tool),
            args: raw_args,
            result: Events.json_safe(result_value),
            classification: class
          })
          |> Events.broadcast(
            {:tool_call, state.agent_id, state.alert_id, tool, raw_args, result_value, class}
          )
          |> continue_prompt(tool, result_value)

        start_turn(state)

      {:error, :budget_exhausted} ->
        :ok =
          Audit.record_terminal(state, tool, call_args, "budget_exhausted", ":budget_exhausted")

        state =
          state
          |> Events.append(:tool_error, %{tool: Atom.to_string(tool), reason: "budget_exhausted"})
          |> Events.broadcast({:budget_exhausted, state.agent_id, tool})
          |> Events.append(:final_state, %{outcome: :budget_exhausted})

        {:stop, :normal, state}
    end
  end

  @spec claim_tool_budget(t()) :: :ok | {:error, :budget_exhausted}
  defp claim_tool_budget(%{alert_state_pid: pid}) when is_pid(pid),
    do: AlertState.inc_tool_call(pid)

  defp claim_tool_budget(_state) do
    Logger.warning("investigator missing alert_state_pid; failing closed before tool dispatch")
    {:error, :budget_exhausted}
  end

  @spec request_gate(t(), atom(), term()) ::
          {:ok, term()} | {:gated, String.t()} | {:error, term()}
  defp request_gate(state, tool, args) do
    tool_call = %ToolCall{
      tool: tool,
      args: args,
      agent_id: state.audit_agent_id,
      agent_pid_inspect: inspect(self()),
      alert_id: state.alert_id,
      request_id: request_id(),
      reasoning_context: %{
        summary: "#{state.profile.name} investigator tool call",
        evidence_link: nil
      }
    }

    state.gate_module.request(tool_call, state.rules,
      tool_dispatch: state.tool_dispatch,
      pubsub: state.pubsub,
      repo: state.gate_repo,
      reply_to: self()
    )
  end

  @spec append_text(t(), String.t() | nil) :: t()
  defp append_text(state, nil), do: state
  defp append_text(state, text), do: %{state | current_text: state.current_text <> text}

  @spec continue_prompt(t(), atom(), term()) :: t()
  defp continue_prompt(state, tool, result) do
    prompt =
      [state.prompt, "\nTool ", Atom.to_string(tool), " result: ", inspect(result)]
      |> IO.iodata_to_binary()

    %{state | prompt: prompt, current_text: ""}
  end

  @spec append(t(), AgentState.event_type(), map()) :: t()
  defp append(state, event_type, payload) do
    attrs = %{
      alert_id: state.alert_id,
      agent_id: state.agent_id,
      agent_type: :investigator,
      profile: Atom.to_string(state.profile.name),
      event_type: event_type,
      payload: JsonSafe.convert(payload),
      sequence: state.sequence
    }

    case AgentState.append_event(state.audit_repo, attrs) do
      {:ok, _row} ->
        :ok

      {:error, reason} ->
        Logger.warning("failed to append investigator state: #{inspect(reason)}")
    end

    %{state | sequence: state.sequence + 1}
  end

  @spec broadcast(t(), tuple()) :: t()
  defp broadcast(state, event) do
    :ok = Phoenix.PubSub.broadcast(state.pubsub, "alert:#{state.alert_id}", event)
    state
  end

  @spec notify_parent(t(), map()) :: t()
  defp notify_parent(%{parent: nil} = state, _findings), do: state

  defp notify_parent(state, findings) do
    send(state.parent, {:investigation_findings, state.alert_id, state.profile.name, findings})
    state
  end

  @spec tool_atom(String.t()) :: atom() | nil
  defp tool_atom("kubectl"), do: :kubectl
  defp tool_atom("prometheus_query"), do: :prometheus_query
  defp tool_atom("query_db"), do: :query_db
  defp tool_atom("mcp_runbook"), do: :mcp_runbook
  defp tool_atom(_name), do: nil

  @spec request_id() :: String.t()
  defp request_id, do: "investigator-req-#{System.unique_integer([:positive])}"

  @spec maybe_allow_hammox(module(), pid()) :: :ok
  defp maybe_allow_hammox(client, caller) do
    hammox = :"Elixir.Hammox"

    if Code.ensure_loaded?(hammox) and function_exported?(hammox, :allow, 3) do
      apply(hammox, :allow, [client, caller, self()])
    end

    :ok
  rescue
    _error -> :ok
  end

  @spec allow_sandbox(t()) :: :ok
  defp allow_sandbox(%{sandbox_owner: nil}), do: :ok

  defp allow_sandbox(state) do
    Sandbox.allow(state.audit_repo, state.sandbox_owner, self())
  rescue
    error ->
      Logger.warning("failed to allow investigator sandbox access: #{inspect(error)}")
      :ok
  end
end
