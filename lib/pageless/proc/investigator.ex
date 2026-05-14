defmodule Pageless.Proc.Investigator do
  @moduledoc "Profile-scoped investigator agent that reasons with Gemini and gated tools."

  use GenServer

  require Logger

  alias Ecto.Adapters.SQL.Sandbox
  alias Pageless.AlertEnvelope
  alias Pageless.Config.Rules
  alias Pageless.Data.AgentState
  alias Pageless.Governance.ToolCall
  alias Pageless.Proc.Investigator.Profile
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
          tool_dispatch: (ToolCall.t() -> {:ok, term()} | {:error, term()})
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
      tools: Profile.build_gemini_function_schema(profile, @tool_modules)
    }

    {:ok, state, {:continue, :setup}}
  end

  @impl true
  def handle_continue(:setup, state) do
    allow_sandbox(state)

    state =
      state
      |> append(:spawned, %{profile: state.profile.name, label: state.profile.label})
      |> broadcast({:investigator_spawned, state.alert_id, state.profile.name, self()})

    {:noreply, state}
  end

  @impl true
  def handle_call(:get_state, {caller, _tag}, state) do
    maybe_allow_hammox(state.gemini_client, caller)
    {:reply, {:ok, state}, state}
  end

  @impl true
  def handle_info(:run, state) do
    state
    |> initial_prompt()
    |> start_turn()
  end

  def handle_info(
        {:gemini_chunk, ref, %Chunk{type: :text, text: text}},
        %{active_ref: ref} = state
      ) do
    state =
      state
      |> append_text(text)
      |> append(:reasoning_line, %{text: text})
      |> broadcast({:reasoning_line, state.agent_id, text})

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
    |> append(:tool_error, %{tool: "gemini.start_stream", reason: json_safe(reason)})
    |> broadcast({:investigation_failed, state.alert_id, state.profile.name, :gemini_unavailable})
    |> notify_parent(%{status: :failed, reason: reason})
    |> append(:final_state, %{outcome: :failed, reason: json_safe(reason)})
    |> then(&{:stop, :normal, &1})
  end

  def handle_info({:gemini_chunk, _ref, _chunk}, state), do: {:noreply, state}
  def handle_info({:gemini_done, _ref, _final}, state), do: {:noreply, state}
  def handle_info({:gemini_error, _ref, _reason}, state), do: {:noreply, state}
  def handle_info({:gate_result, _gate_id, _result}, state), do: {:noreply, state}
  def handle_info(_message, state), do: {:noreply, state}

  @spec initial_prompt(t()) :: t()
  defp initial_prompt(state) do
    %{state | prompt: render_prompt(state), current_text: ""}
  end

  @spec start_turn(t()) :: {:noreply, t()} | {:stop, :normal, t()}
  defp start_turn(%{steps: steps, profile: %{step_limit: limit}} = state) when steps >= limit do
    no_findings(state)
  end

  defp start_turn(state) do
    case state.gemini_client.start_stream(gemini_opts(state)) do
      {:ok, ref} ->
        {:noreply, %{state | active_ref: ref, current_text: "", steps: state.steps + 1}}

      {:error, reason} ->
        state
        |> append(:tool_error, %{tool: "gemini.start_stream", reason: json_safe(reason)})
        |> broadcast(
          {:investigation_failed, state.alert_id, state.profile.name, :gemini_unavailable}
        )
        |> notify_parent(%{status: :failed, reason: reason})
        |> append(:final_state, %{outcome: :failed, reason: json_safe(reason)})
        |> then(&{:stop, :normal, &1})
    end
  end

  @spec handle_function_call(FunctionCall.t() | nil, t()) ::
          {:noreply, t()} | {:stop, :normal, t()}
  defp handle_function_call(%FunctionCall{name: name, args: args}, state) when is_map(args) do
    tool = tool_atom(name)

    if tool && scoped?(state.profile, tool) do
      call_args = tool_call_args(tool, args)
      result = request_gate(state, tool, call_args)
      class = classification(result)

      state =
        state
        |> append(:tool_call, %{
          tool: Atom.to_string(tool),
          args: args,
          result: json_safe(result_value(result)),
          classification: class
        })
        |> broadcast({:tool_call, state.agent_id, tool, args, result_value(result), class})
        |> continue_prompt(tool, result_value(result))

      start_turn(state)
    else
      state =
        state
        |> append(:tool_hallucination, %{attempted_tool: name})
        |> broadcast({:tool_hallucination, state.agent_id, name})
        |> continue_prompt(:tool_hallucination, %{error: "tool #{name} is not available"})

      start_turn(state)
    end
  end

  defp handle_function_call(_call, state), do: start_turn(state)

  @spec complete_turn(t()) :: {:stop, :normal, t()}
  defp complete_turn(state) do
    case decode_findings(state.current_text) do
      {:ok, findings} -> complete_success(state, findings)
      :error -> no_findings(state)
    end
  end

  @spec complete_success(t(), map()) :: {:stop, :normal, t()}
  defp complete_success(state, findings) do
    state =
      state
      |> append(:findings, findings)
      |> broadcast({:investigation_complete, state.alert_id, state.profile.name, findings})
      |> notify_parent(findings)
      |> append(:final_state, %{outcome: :complete})

    {:stop, :normal, state}
  end

  @spec no_findings(t()) :: {:stop, :normal, t()}
  defp no_findings(state) do
    findings = %{status: :no_findings, reason: :step_limit}

    state =
      state
      |> append(:findings, findings)
      |> notify_parent(findings)
      |> append(:final_state, %{outcome: :no_findings, reason: :step_limit})

    {:stop, :normal, state}
  end

  @spec request_gate(t(), atom(), term()) ::
          {:ok, term()} | {:gated, String.t()} | {:error, term()}
  defp request_gate(state, tool, args) do
    tool_call = %ToolCall{
      tool: tool,
      args: args,
      agent_id: state.agent_id,
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

  @spec gemini_opts(t()) :: keyword()
  defp gemini_opts(state) do
    [
      model: :pro,
      temperature: 0.0,
      tool_choice: :auto,
      prompt: state.prompt,
      tools: state.tools,
      caller: self(),
      metadata: %{alert_id: state.alert_id, agent_id: state.agent_id, profile: state.profile.name}
    ]
  end

  @spec render_prompt(t()) :: String.t()
  defp render_prompt(state) do
    assigns = [
      alert_id: state.envelope.alert_id,
      service: state.envelope.service,
      title: state.envelope.title,
      severity: state.envelope.severity,
      labels: state.envelope.labels,
      annotations: state.envelope.annotations
    ]

    EEx.eval_string(state.profile.prompt_template, assigns: assigns)
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
      payload: json_safe(payload),
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

  @spec decode_findings(String.t()) :: {:ok, map()} | :error
  defp decode_findings(text) do
    with {:ok, decoded} <- Jason.decode(text),
         true <- is_map(decoded) do
      {:ok, atomize_known_keys(decoded)}
    else
      _other -> :error
    end
  end

  @spec atomize_known_keys(map()) :: map()
  defp atomize_known_keys(map) do
    Map.new(map, fn
      {"hypothesis", value} -> {:hypothesis, value}
      {"confidence", value} -> {:confidence, value}
      {"evidence", value} -> {:evidence, value}
      {key, value} -> {key, value}
    end)
  end

  @spec tool_atom(String.t()) :: atom() | nil
  defp tool_atom("kubectl"), do: :kubectl
  defp tool_atom("prometheus_query"), do: :prometheus_query
  defp tool_atom("query_db"), do: :query_db
  defp tool_atom("mcp_runbook"), do: :mcp_runbook
  defp tool_atom(_name), do: nil

  @spec scoped?(Profile.t(), atom()) :: boolean()
  defp scoped?(profile, :kubectl), do: not is_nil(profile.tool_scope.kubectl)
  defp scoped?(profile, :prometheus_query), do: profile.tool_scope.prometheus_query == true
  defp scoped?(profile, :query_db), do: not is_nil(profile.tool_scope.query_db)
  defp scoped?(profile, :mcp_runbook), do: profile.tool_scope.mcp_runbook == true
  defp scoped?(_profile, _tool), do: false

  @spec tool_call_args(atom(), map()) :: term()
  defp tool_call_args(:kubectl, %{"args" => args}), do: args
  defp tool_call_args(:prometheus_query, %{"promql" => promql}), do: promql
  defp tool_call_args(:query_db, %{"sql" => sql}), do: sql
  defp tool_call_args(:mcp_runbook, args), do: args
  defp tool_call_args(_tool, args), do: args

  @spec classification({:ok, term()} | {:gated, String.t()} | {:error, term()}) :: atom()
  defp classification({:ok, %{classification: class}}), do: class
  defp classification({:ok, _result}), do: :read
  defp classification({:gated, _gate_id}), do: :write_prod_high
  defp classification({:error, _reason}), do: :read

  @spec result_value({:ok, term()} | {:gated, String.t()} | {:error, term()}) :: term()
  defp result_value({:ok, result}), do: result
  defp result_value({:gated, gate_id}), do: %{status: :gated, gate_id: gate_id}
  defp result_value({:error, reason}), do: %{status: :error, reason: reason}

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

  @spec json_safe(term()) :: term()
  defp json_safe(value) when is_atom(value), do: Atom.to_string(value)

  defp json_safe(value) when is_map(value),
    do: Map.new(value, fn {key, val} -> {json_key(key), json_safe(val)} end)

  defp json_safe(value) when is_list(value), do: Enum.map(value, &json_safe/1)
  defp json_safe(value), do: value

  defp json_key(key) when is_atom(key), do: Atom.to_string(key)
  defp json_key(key), do: key
end
