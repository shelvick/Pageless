defmodule Pageless.Proc.Remediator do
  @moduledoc "Single-shot agent that proposes and gates one remediation action."

  use GenServer

  require Logger

  alias Ecto.Adapters.SQL.Sandbox
  alias Pageless.AlertEnvelope
  alias Pageless.Config.Rules
  alias Pageless.Data.AgentState
  alias Pageless.Governance.ToolCall
  alias Pageless.Sup.Alert
  alias Pageless.Svc.GeminiClient.FunctionCall
  alias Pageless.Svc.GeminiClient.Response

  @valid_actions ~w(rollout_undo rollout_restart scale_down delete apply exec other)a
  @valid_classes ~w(read write_dev write_prod_low write_prod_high)a

  defstruct [
    :agent_id,
    :alert_id,
    :envelope,
    :findings,
    :pubsub,
    :gemini_client,
    :audit_repo,
    :sandbox_owner,
    :parent,
    :alert_sup,
    :rules,
    :gate_module,
    :gate_repo,
    :escalator_module,
    :tool_dispatch,
    :proposal,
    :gate_id,
    sequence: 0
  ]

  @type proposal :: %{
          action: atom(),
          args: [String.t()],
          classification_hint: atom(),
          rationale: String.t(),
          considered_alternatives: [map()],
          request_id: String.t()
        }

  @type outcome ::
          :auto_fired
          | :gated_then_executed
          | :denied_then_escalated
          | :failed_then_escalated
          | :failed

  @type t :: %__MODULE__{
          agent_id: String.t(),
          alert_id: String.t(),
          envelope: AlertEnvelope.t(),
          findings: [map()],
          pubsub: atom(),
          gemini_client: module(),
          audit_repo: module(),
          sandbox_owner: pid() | nil,
          parent: pid() | nil,
          alert_sup: pid(),
          rules: Rules.t(),
          gate_module: module(),
          gate_repo: module(),
          escalator_module: module(),
          tool_dispatch: (ToolCall.t() -> {:ok, term()} | {:error, term()}),
          proposal: proposal() | nil,
          gate_id: String.t() | nil,
          sequence: non_neg_integer()
        }

  @type opts :: [
          alert_id: String.t(),
          envelope: AlertEnvelope.t(),
          findings: [map()],
          pubsub: atom(),
          gemini_client: module(),
          sandbox_owner: pid() | nil,
          audit_repo: module(),
          parent: pid() | nil,
          alert_sup: pid(),
          rules: Rules.t(),
          gate_module: module(),
          gate_repo: module(),
          escalator_module: module(),
          tool_dispatch: (ToolCall.t() -> {:ok, term()} | {:error, term()})
        ]

  @doc "Starts the Remediator agent."
  @spec start_link(opts()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Triggers the remediation proposal run."
  @spec kick_off(GenServer.server()) :: :ok
  def kick_off(server), do: send(server, :run) |> then(fn _ -> :ok end)

  @impl true
  def init(opts) do
    state = %__MODULE__{
      agent_id: "remediator-#{System.unique_integer([:positive])}",
      alert_id: Keyword.fetch!(opts, :alert_id),
      envelope: Keyword.fetch!(opts, :envelope),
      findings: Keyword.fetch!(opts, :findings),
      pubsub: Keyword.fetch!(opts, :pubsub),
      gemini_client: Keyword.fetch!(opts, :gemini_client),
      audit_repo: Keyword.fetch!(opts, :audit_repo),
      sandbox_owner: Keyword.get(opts, :sandbox_owner),
      parent: Keyword.get(opts, :parent),
      alert_sup: Keyword.fetch!(opts, :alert_sup),
      rules: Keyword.fetch!(opts, :rules),
      gate_module: Keyword.get(opts, :gate_module, Pageless.Governance.CapabilityGate),
      gate_repo: Keyword.get(opts, :gate_repo, Pageless.AuditTrail),
      escalator_module: Keyword.get(opts, :escalator_module, Pageless.Proc.Escalator),
      tool_dispatch: Keyword.fetch!(opts, :tool_dispatch)
    }

    {:ok, state, {:continue, :setup}}
  end

  @impl true
  def handle_continue(:setup, state) do
    allow_sandbox(state)

    state =
      state
      |> append(:spawned, %{
        envelope_summary: envelope_summary(state.envelope),
        findings_summary: findings_summary(state.findings)
      })
      |> broadcast({:remediator_spawned, state.agent_id, state.alert_id})

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
    |> propose_action()
    |> continue_from_proposal(state)
  end

  @impl true
  def handle_info({:gate_result, gate_id, result}, %{gate_id: gate_id} = state)
      when is_binary(gate_id) do
    handle_gate_result(result, state)
  end

  def handle_info({:gate_result, gate_id, _result}, state) do
    Logger.warning(
      "ignoring remediator gate result for #{inspect(gate_id)}; awaiting #{inspect(state.gate_id)}"
    )

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @spec propose_action(t()) :: {:ok, proposal()} | {:error, term()}
  defp propose_action(state) do
    case state.gemini_client.generate(gemini_opts(state)) do
      {:ok, %Response{function_calls: [%FunctionCall{name: "propose_action", args: args} | _]}} ->
        build_proposal(args)

      {:ok, %Response{function_calls: []}} ->
        {:error, :no_function_call}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec continue_from_proposal({:ok, proposal()} | {:error, term()}, t()) ::
          {:noreply, t()} | {:stop, :normal, t()}
  defp continue_from_proposal({:ok, proposal}, state) do
    state =
      state
      |> append(:reasoning_line, %{text: proposal.rationale})
      |> broadcast({:remediator_reasoning, state.agent_id, proposal.rationale})
      |> append(:findings, proposal_payload(proposal))

    state = %{state | proposal: proposal}
    tool_call = tool_call(state, proposal)

    case request_gate(state, tool_call) do
      {:ok, result} ->
        state
        |> broadcast_proposed(nil)
        |> record_tool_call(result, nil)
        |> broadcast_executed(result, nil)
        |> complete(:auto_fired, nil, nil)

      {:gated, gate_id} ->
        state = %{state | gate_id: gate_id}

        state = broadcast_proposed(state, gate_id)
        {:noreply, state}

      {:error, reason} ->
        state
        |> broadcast_proposed(nil)
        |> append(:tool_error, %{tool: "gate.request", reason: json_safe(reason), gate_id: nil})
        |> broadcast_failed(reason, nil)
        |> escalate_and_complete(reason, :failed_then_escalated, nil)
    end
  end

  defp continue_from_proposal({:error, reason}, state) do
    state
    |> append(:tool_error, %{tool: "gemini.generate", reason: json_safe(reason), gate_id: nil})
    |> broadcast_failed(reason, nil)
    |> escalate_and_complete(reason, :failed_then_escalated, nil)
  end

  @spec handle_gate_result({:ok, term()} | {:error, term()} | {:error, atom(), term()}, t()) ::
          {:stop, :normal, t()}
  defp handle_gate_result({:ok, result}, state) do
    state
    |> record_tool_call(result, state.gate_id)
    |> broadcast_executed(result, state.gate_id)
    |> complete(:gated_then_executed, state.gate_id, nil)
  end

  defp handle_gate_result({:error, :denied, reason}, state) do
    denied_reason = {:denied, reason}

    state
    |> append(:tool_error, %{
      tool: "kubectl",
      reason: json_safe(denied_reason),
      gate_id: state.gate_id
    })
    |> broadcast_failed(denied_reason, state.gate_id)
    |> escalate_and_complete(denied_reason, :denied_then_escalated, state.gate_id)
  end

  defp handle_gate_result({:error, reason}, state) do
    state
    |> append(:tool_error, %{tool: "kubectl", reason: json_safe(reason), gate_id: state.gate_id})
    |> broadcast_failed(reason, state.gate_id)
    |> escalate_and_complete(reason, :failed_then_escalated, state.gate_id)
  end

  @spec request_gate(t(), ToolCall.t()) :: {:ok, term()} | {:gated, String.t()} | {:error, term()}
  defp request_gate(state, tool_call) do
    state.gate_module.request(tool_call, state.rules,
      tool_dispatch: state.tool_dispatch,
      pubsub: state.pubsub,
      repo: state.gate_repo,
      reply_to: self()
    )
  end

  @spec record_tool_call(t(), term(), String.t() | nil) :: t()
  defp record_tool_call(state, result, gate_id) do
    append(state, :tool_call, %{
      tool: "kubectl",
      args: %{argv: state.proposal.args},
      result: %{kind: :ok, value: json_safe(result)},
      classification: state.proposal.classification_hint,
      gate_id: gate_id
    })
  end

  @spec broadcast_proposed(t(), String.t() | nil) :: t()
  defp broadcast_proposed(state, gate_id) do
    broadcast(state, {
      :remediator_action_proposed,
      state.agent_id,
      state.alert_id,
      proposal_payload(state.proposal)
      |> Map.merge(%{gate_id: gate_id, classification: nil})
    })
  end

  @spec broadcast_executed(t(), term(), String.t() | nil) :: t()
  defp broadcast_executed(state, result, gate_id) do
    broadcast(state, {
      :remediator_action_executed,
      state.agent_id,
      state.alert_id,
      %{
        action: state.proposal.action,
        args: state.proposal.args,
        result: result,
        gate_id: gate_id
      }
    })
  end

  @spec broadcast_failed(t(), term(), String.t() | nil) :: t()
  defp broadcast_failed(state, reason, gate_id) do
    proposal = state.proposal || %{}

    broadcast(state, {
      :remediator_action_failed,
      state.agent_id,
      state.alert_id,
      %{
        action: Map.get(proposal, :action),
        args: Map.get(proposal, :args),
        reason: reason,
        gate_id: gate_id
      }
    })
  end

  @spec escalate_and_complete(t(), term(), outcome(), String.t() | nil) :: {:stop, :normal, t()}
  defp escalate_and_complete(state, reason, outcome, gate_id) do
    opts = escalator_opts(reason)

    case Alert.start_agent(state.alert_sup, state.escalator_module, opts) do
      {:ok, escalator_pid} ->
        state
        |> broadcast(
          {:remediator_escalating, state.agent_id, state.alert_id, escalator_pid, reason}
        )
        |> complete(outcome, gate_id, reason)

      {:error, spawn_reason} ->
        complete(state, :failed, gate_id, {:escalator_spawn_failed, spawn_reason})
    end
  end

  @spec escalator_opts(term()) :: keyword()
  defp escalator_opts({:denied, reason}), do: [parent: self(), denial_reason: reason]
  defp escalator_opts(reason), do: [parent: self(), failure_reason: reason]

  @spec complete(t(), outcome(), String.t() | nil, term()) :: {:stop, :normal, t()}
  defp complete(state, outcome, gate_id, reason) do
    action = if state.proposal, do: state.proposal.action, else: nil

    state =
      append(state, :final_state, %{
        outcome: outcome,
        action: action,
        gate_id: gate_id,
        reason: json_safe(reason)
      })

    notify_parent(state, outcome, action, gate_id, reason)
    {:stop, :normal, state}
  end

  @spec build_proposal(map()) :: {:ok, proposal()} | {:error, atom()}
  defp build_proposal(args) when is_map(args) do
    with {:ok, argv} <- argv_arg(args),
         {:ok, alternatives} <- alternatives_arg(args) do
      {:ok,
       %{
         action: action_atom(get_arg(args, "action", :action)),
         args: argv,
         classification_hint:
           class_atom(get_arg(args, "classification_hint", :classification_hint)),
         rationale: non_empty(get_arg(args, "rationale", :rationale), "No rationale provided."),
         considered_alternatives: alternatives,
         request_id: request_id()
       }}
    end
  end

  defp build_proposal(_args), do: {:error, :invalid_proposal}

  @spec argv_arg(map()) :: {:ok, [String.t()]} | {:error, :invalid_args}
  defp argv_arg(args) do
    case get_arg(args, "args", :args) do
      argv when is_list(argv) ->
        if Enum.all?(argv, &is_binary/1) and argv != [] do
          {:ok, argv}
        else
          {:error, :invalid_args}
        end

      _other ->
        {:error, :invalid_args}
    end
  end

  @spec alternatives_arg(map()) :: {:ok, [map()]} | {:error, :invalid_considered_alternatives}
  defp alternatives_arg(args) do
    alternatives = get_arg(args, "considered_alternatives", :considered_alternatives)

    if is_list(alternatives) and alternatives != [] and
         Enum.all?(alternatives, &valid_alternative?/1) do
      {:ok, alternatives}
    else
      {:error, :invalid_considered_alternatives}
    end
  end

  @spec valid_alternative?(term()) :: boolean()
  defp valid_alternative?(%{} = alternative) do
    is_binary(get_arg(alternative, "action", :action)) and
      is_binary(get_arg(alternative, "reason_rejected", :reason_rejected))
  end

  defp valid_alternative?(_alternative), do: false

  @spec tool_call(t(), proposal()) :: ToolCall.t()
  defp tool_call(state, proposal) do
    %ToolCall{
      tool: :kubectl,
      args: proposal.args,
      agent_id: gate_agent_id(),
      agent_pid_inspect: inspect(self()),
      alert_id: state.alert_id,
      request_id: proposal.request_id,
      reasoning_context: %{
        summary: proposal.rationale,
        evidence_link: findings_link(state.findings)
      }
    }
  end

  @spec gate_agent_id() :: Ecto.UUID.t()
  defp gate_agent_id, do: Ecto.UUID.generate()

  @spec proposal_payload(proposal()) :: map()
  defp proposal_payload(proposal) do
    %{
      action: proposal.action,
      args: proposal.args,
      classification_hint: proposal.classification_hint,
      rationale: proposal.rationale,
      considered_alternatives: proposal.considered_alternatives
    }
  end

  @spec append(t(), AgentState.event_type(), map()) :: t()
  defp append(state, event_type, payload) do
    attrs = %{
      alert_id: state.alert_id,
      agent_id: state.agent_id,
      agent_type: :remediator,
      event_type: event_type,
      payload: json_safe(payload),
      sequence: state.sequence
    }

    case AgentState.append_event(state.audit_repo, attrs) do
      {:ok, _row} -> :ok
      {:error, reason} -> Logger.warning("failed to append remediator state: #{inspect(reason)}")
    end

    %{state | sequence: state.sequence + 1}
  end

  @spec broadcast(t(), tuple()) :: t()
  defp broadcast(state, event) do
    :ok = Phoenix.PubSub.broadcast(state.pubsub, "alert:#{state.alert_id}", event)
    state
  end

  @spec notify_parent(t(), outcome(), atom() | nil, String.t() | nil, term()) :: :ok
  defp notify_parent(%{parent: nil}, _outcome, _action, _gate_id, _reason), do: :ok

  defp notify_parent(state, outcome, action, gate_id, reason) do
    send(
      state.parent,
      {:remediator_complete, state.alert_id, state.agent_id,
       %{outcome: outcome, action: action, gate_id: gate_id, reason: reason}}
    )

    :ok
  end

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
      Logger.warning("failed to allow remediator sandbox access: #{inspect(error)}")
      :ok
  end

  @spec gemini_opts(t()) :: keyword()
  defp gemini_opts(state) do
    [
      model: :pro,
      temperature: 0.0,
      tool_choice: {:specific, "propose_action"},
      prompt: inspect(%{envelope: envelope_summary(state.envelope), findings: state.findings}),
      system_instruction: system_instruction(),
      tools: [propose_action_tool()]
    ]
  end

  @spec system_instruction() :: String.t()
  defp system_instruction do
    """
    You are an incident remediator. You receive an alert and structured investigator findings,
    and you propose ONE concrete kubectl action to remediate.

    Reasoning protocol (FOLLOW EXACTLY):
      1. Identify the cheapest reversible action that could plausibly remediate
         (e.g., kubectl rollout restart). Add it to considered_alternatives with
         a one-sentence reason it MIGHT work.
      2. Critique that action against the findings -- does it address the root cause?
         If the findings indicate the deployed code itself is bad, restart loops
         back into the same broken code. Add the rejection reason to that
         considered_alternatives entry.
      3. Propose the action that DOES address the root cause (e.g., kubectl
         rollout undo). This is your final proposal.

    You MUST emit exactly one function call to propose_action with at least
    one entry in considered_alternatives. The propose_action.args field must
    be a complete kubectl argv array starting with the verb (no leading "kubectl").
    """
  end

  @spec propose_action_tool() :: map()
  defp propose_action_tool do
    %{
      function_declarations: [
        %{
          name: "propose_action",
          parameters: %{
            type: "object",
            required: [
              "action",
              "args",
              "classification_hint",
              "rationale",
              "considered_alternatives"
            ],
            properties: %{
              action: %{type: "string"},
              args: %{type: "array", items: %{type: "string"}, minItems: 1},
              classification_hint: %{
                type: "string",
                enum: Enum.map(@valid_classes, &Atom.to_string/1)
              },
              rationale: %{type: "string"},
              considered_alternatives: %{
                type: "array",
                minItems: 1,
                items: %{
                  type: "object",
                  required: ["action", "reason_rejected"],
                  properties: %{
                    action: %{type: "string"},
                    reason_rejected: %{type: "string"}
                  }
                }
              }
            }
          }
        }
      ]
    }
  end

  @spec action_atom(term()) :: atom()
  defp action_atom(value) when is_atom(value) and value in @valid_actions, do: value

  defp action_atom(value) when is_binary(value) do
    Enum.find(@valid_actions, :other, &(Atom.to_string(&1) == value))
  end

  defp action_atom(_value), do: :other

  @spec class_atom(term()) :: atom()
  defp class_atom(value) when is_atom(value) and value in @valid_classes, do: value

  defp class_atom(value) when is_binary(value) do
    Enum.find(@valid_classes, :write_prod_high, &(Atom.to_string(&1) == value))
  end

  defp class_atom(_value), do: :write_prod_high

  @spec get_arg(map(), String.t(), atom()) :: term()
  defp get_arg(args, string_key, atom_key) do
    Map.get(args, string_key) || Map.get(args, atom_key)
  end

  @spec request_id() :: String.t()
  defp request_id do
    "rem_req_" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
  end

  @spec envelope_summary(AlertEnvelope.t()) :: map()
  defp envelope_summary(envelope) do
    %{
      alert_id: envelope.alert_id,
      source: envelope.source,
      severity: envelope.severity,
      alert_class: envelope.alert_class,
      title: envelope.title,
      service: envelope.service,
      fingerprint: envelope.fingerprint,
      started_at: envelope.started_at,
      labels: envelope.labels
    }
  end

  @spec findings_summary([map()]) :: map()
  defp findings_summary(findings) do
    %{
      count: length(findings),
      hypothesis: findings |> List.first() |> hypothesis()
    }
  end

  @spec hypothesis(map() | nil) :: String.t() | nil
  defp hypothesis(%{} = finding),
    do: Map.get(finding, :hypothesis) || Map.get(finding, "hypothesis")

  defp hypothesis(_finding), do: nil

  @spec findings_link([map()]) :: String.t() | nil
  defp findings_link([]), do: nil
  defp findings_link(findings), do: "agent_state:findings:#{length(findings)}"

  @spec non_empty(term(), String.t()) :: String.t()
  defp non_empty(value, fallback) when value in [nil, ""], do: fallback
  defp non_empty(value, _fallback) when is_binary(value), do: value
  defp non_empty(_value, fallback), do: fallback

  @spec json_safe(term()) :: term()
  defp json_safe(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp json_safe(%{} = map) do
    Map.new(map, fn {key, value} -> {key, json_safe(value)} end)
  end

  defp json_safe(value) when is_list(value), do: Enum.map(value, &json_safe/1)
  defp json_safe(value) when is_tuple(value), do: inspect(value)
  defp json_safe(value), do: value
end
