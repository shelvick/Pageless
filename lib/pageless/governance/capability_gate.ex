defmodule Pageless.Governance.CapabilityGate do
  @moduledoc """
  Policy gate for classifying, auditing, and dispatching agent tool calls.
  """

  alias Pageless.AuditTrail.Decision
  alias Pageless.Config.Rules
  alias Pageless.Governance.SqlSelectOnlyParser
  alias Pageless.Governance.ToolCall
  alias Pageless.Governance.VerbTableClassifier

  @type classification :: :read | :write_dev | :write_prod_low | :write_prod_high
  @type opts :: [
          tool_dispatch: (ToolCall.t() -> {:ok, term()} | {:error, term()}),
          pubsub: atom(),
          repo: module(),
          reply_to: pid() | nil
        ]
  @type request_result :: {:ok, term()} | {:gated, String.t()} | {:error, term()}
  @type approve_error :: :no_pending_gate | :tool_dispatch_failed | :audit_write_failed | term()

  @gate_id_attempts 3
  @context_metadata_prefix "pageless:gate-context:"

  @doc "Classifies and handles a tool call according to the supplied rules."
  @spec request(ToolCall.t(), Rules.t(), opts()) :: request_result()
  def request(%ToolCall{} = tool_call, %Rules{} = rules, opts) do
    with {:ok, class, verb} <- classify(tool_call, rules),
         {:ok, policy} <- fetch_policy(rules, class, tool_call, opts) do
      record_and_continue(tool_call, class, verb, policy, opts, @gate_id_attempts)
    else
      {:rejected, class, reason} -> record_rejection(tool_call, class, reason, opts)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Approves a pending gate and dispatches the deferred tool call exactly once."
  @spec approve(String.t(), String.t(), opts()) :: {:ok, term()} | {:error, approve_error()}
  def approve(gate_id, operator_ref, opts) when is_binary(gate_id) and is_binary(operator_ref) do
    repo = Keyword.fetch!(opts, :repo)

    case pending_gate(repo, gate_id) do
      {:ok, pending} -> claim_approval(pending, gate_id, operator_ref, opts)
      {:error, :no_pending_gate} -> {:error, :no_pending_gate}
    end
  end

  @doc "Denies a pending gate without dispatching the deferred tool call."
  @spec deny(String.t(), String.t(), String.t(), opts()) :: :ok | {:error, atom()}
  def deny(gate_id, operator_ref, reason, opts)
      when is_binary(gate_id) and is_binary(operator_ref) and is_binary(reason) do
    repo = Keyword.fetch!(opts, :repo)

    with {:ok, pending} <- pending_gate(repo, gate_id),
         {:ok, decision} <- claim_denial(pending, gate_id, operator_ref, reason, opts) do
      broadcast(opts, decision.alert_id, {:gate_decision, :denied, gate_id, operator_ref, reason})
      maybe_reply(opts, gate_id, {:error, :denied, reason})
      :ok
    end
  end

  defp classify(%ToolCall{tool: :kubectl, args: args}, %Rules{} = rules) do
    case VerbTableClassifier.classify(args, rules.kubectl_verbs) do
      {:ok, class, verb} -> {:ok, class, verb}
      {:error, reason} -> {:rejected, :write_prod_high, reason}
    end
  end

  defp classify(%ToolCall{tool: :query_db, args: sql}, %Rules{} = rules) do
    case SqlSelectOnlyParser.validate(sql, function_blocklist: rules.function_blocklist) do
      {:ok, :read} -> {:ok, :read, nil}
      {:error, reason} -> {:rejected, :read, reason}
    end
  end

  defp classify(%ToolCall{tool: tool}, _rules) when tool in [:prometheus_query, :mcp_runbook],
    do: {:ok, :read, nil}

  defp classify(%ToolCall{}, _rules), do: {:error, :unknown_tool}

  defp fetch_policy(%Rules{} = rules, class, tool_call, opts) do
    case Map.fetch(rules.capability_classes, class) do
      {:ok, policy} ->
        {:ok, policy}

      :error ->
        broadcast(opts, tool_call.alert_id, {:gate_decision, :policy_missing, tool_call, class})
        {:error, :policy_missing}
    end
  end

  defp record_and_continue(tool_call, class, verb, policy, opts, attempts_left) do
    gate_id = maybe_gate_id(policy)
    decision = initial_decision(policy)

    attrs =
      tool_call
      |> initial_decision_attrs(class, verb, decision, gate_id)
      |> maybe_mark_policy_denial(policy)

    case Keyword.fetch!(opts, :repo).record_decision(attrs) do
      {:ok, row} ->
        after_initial_record(row, tool_call, class, verb, policy, opts)

      {:error, changeset} ->
        handle_record_error(changeset, tool_call, class, verb, policy, opts, attempts_left)
    end
  end

  defp handle_record_error(changeset, tool_call, class, verb, policy, opts, attempts_left) do
    if gate_id_collision?(changeset) do
      case attempts_left do
        attempts when attempts > 1 ->
          record_and_continue(tool_call, class, verb, policy, opts, attempts - 1)

        _attempts ->
          {:error, :gate_id_collision}
      end
    else
      broadcast(
        opts,
        tool_call.alert_id,
        {:gate_decision, :audit_failed, tool_call, :record_decision}
      )

      {:error, :audit_write_failed}
    end
  end

  defp after_initial_record(%Decision{} = row, tool_call, class, verb, %{gated: true}, opts) do
    broadcast(opts, tool_call.alert_id, {
      :gate_fired,
      row.gate_id,
      tool_call,
      class,
      verb,
      tool_call.reasoning_context
    })

    {:gated, row.gate_id}
  end

  defp after_initial_record(%Decision{} = row, tool_call, class, verb, %{auto: true}, opts) do
    broadcast(
      opts,
      tool_call.alert_id,
      {:gate_decision, decision_event(row.decision), tool_call, class, verb}
    )

    dispatch_and_update(row, tool_call, opts)
  end

  defp after_initial_record(%Decision{} = _row, tool_call, class, _verb, _policy, opts) do
    broadcast(opts, tool_call.alert_id, {:gate_decision, :policy_denied, tool_call, class})
    {:error, :policy_denied}
  end

  defp record_rejection(tool_call, class, reason, opts) do
    attrs =
      tool_call
      |> initial_decision_attrs(class, nil, "rejected", nil)
      |> Map.merge(%{result_status: "error", result_summary: summarize(reason)})

    case Keyword.fetch!(opts, :repo).record_decision(attrs) do
      {:ok, _row} ->
        broadcast(opts, tool_call.alert_id, {:gate_decision, :rejected, tool_call, class, reason})
        {:error, reason}

      {:error, _changeset} ->
        broadcast(
          opts,
          tool_call.alert_id,
          {:gate_decision, :audit_failed, tool_call, :record_decision}
        )

        {:error, :audit_write_failed}
    end
  end

  defp claim_approval(%Decision{} = pending, gate_id, operator_ref, opts) do
    case Keyword.fetch!(opts, :repo).claim_gate_for_approval(gate_id, operator_ref) do
      {:ok, decision} ->
        broadcast(opts, decision.alert_id, {:gate_decision, :approved, gate_id, operator_ref})
        dispatch_and_update(decision, tool_call_from_decision(decision, opts), opts)

      {:error, :no_pending_gate} ->
        {:error, :no_pending_gate}

      {:error, _reason} ->
        broadcast(
          opts,
          pending.alert_id,
          {:gate_decision, :audit_failed, gate_id, :approve_failed}
        )

        {:error, :audit_write_failed}
    end
  end

  defp claim_denial(%Decision{} = pending, gate_id, operator_ref, reason, opts) do
    case Keyword.fetch!(opts, :repo).claim_gate_for_denial(gate_id, operator_ref, reason) do
      {:ok, decision} ->
        {:ok, decision}

      {:error, :no_pending_gate} ->
        {:error, :no_pending_gate}

      {:error, _reason} ->
        broadcast(opts, pending.alert_id, {:gate_decision, :audit_failed, gate_id, :deny_failed})
        {:error, :audit_write_failed}
    end
  end

  defp pending_gate(repo, gate_id) do
    case repo.get_by_gate_id(gate_id) do
      %Decision{decision: "gated"} = decision -> {:ok, decision}
      _other -> {:error, :no_pending_gate}
    end
  end

  defp dispatch_and_update(%Decision{} = row, %ToolCall{} = tool_call, opts) do
    result = safe_dispatch(tool_call, Keyword.fetch!(opts, :tool_dispatch))
    update_attrs = result_attrs(result)

    case Keyword.fetch!(opts, :repo).update_decision(row, update_attrs) do
      {:ok, updated} ->
        broadcast_dispatch_result(opts, updated.gate_id, tool_call, result)
        maybe_reply(opts, updated.gate_id, result)
        result

      {:error, _changeset} ->
        gate_id = row.gate_id
        broadcast(opts, row.alert_id, {:gate_decision, :audit_failed, gate_id, :update_decision})
        maybe_reply(opts, gate_id, {:error, :audit_write_failed})
        {:error, :audit_write_failed}
    end
  end

  defp safe_dispatch(tool_call, dispatch) do
    dispatch.(tool_call)
  rescue
    _exception -> {:error, :tool_dispatch_failed}
  catch
    _kind, _reason -> {:error, :tool_dispatch_failed}
  end

  defp result_attrs({:ok, result}) do
    %{decision: "executed", result_status: "ok", result_summary: summarize(result)}
  end

  defp result_attrs({:error, reason}) do
    %{decision: "execution_failed", result_status: "error", result_summary: summarize(reason)}
  end

  defp broadcast_dispatch_result(opts, gate_id, tool_call, {:ok, result}) do
    broadcast(opts, tool_call.alert_id, {:gate_decision, :executed, gate_id, tool_call, result})
  end

  defp broadcast_dispatch_result(opts, gate_id, tool_call, {:error, reason}) do
    broadcast(
      opts,
      tool_call.alert_id,
      {:gate_decision, :execution_failed, gate_id, tool_call, reason}
    )
  end

  defp initial_decision_attrs(%ToolCall{} = tool_call, class, verb, decision, gate_id) do
    %{}
    |> Map.merge(base_decision_attrs(tool_call, class, verb, decision, gate_id))
    |> maybe_store_context(tool_call)
  end

  defp base_decision_attrs(%ToolCall{} = tool_call, class, verb, decision, gate_id) do
    %{
      request_id: tool_call.request_id,
      alert_id: tool_call.alert_id,
      agent_id: tool_call.agent_id,
      agent_pid_inspect: tool_call.agent_pid_inspect,
      tool: Atom.to_string(tool_call.tool),
      args: args_map(tool_call),
      extracted_verb: verb,
      classification: Atom.to_string(class),
      decision: decision,
      gate_id: gate_id
    }
  end

  defp args_map(%ToolCall{tool: :kubectl, args: args}), do: %{"argv" => args}
  defp args_map(%ToolCall{tool: :query_db, args: sql}), do: %{"sql" => sql}
  defp args_map(%ToolCall{tool: :prometheus_query, args: promql}), do: %{"promql" => promql}
  defp args_map(%ToolCall{tool: :mcp_runbook, args: args}) when is_map(args), do: args
  defp args_map(%ToolCall{tool: tool, args: args}), do: %{Atom.to_string(tool) => args}

  defp tool_call_from_decision(%Decision{} = decision, _opts) do
    metadata = decode_context(decision.result_summary)

    %ToolCall{
      tool: tool_atom(decision.tool),
      args: args_from_row(decision.tool, decision.args),
      agent_id: decision.agent_id,
      agent_pid_inspect: decision.agent_pid_inspect,
      alert_id: decision.alert_id,
      request_id: decision.request_id,
      reasoning_context: Map.get(metadata, "reasoning_context", %{})
    }
  end

  defp args_from_row("kubectl", %{"argv" => args}), do: args
  defp args_from_row("query_db", %{"sql" => sql}), do: sql
  defp args_from_row("prometheus_query", %{"promql" => promql}), do: promql
  defp args_from_row("mcp_runbook", args), do: args

  defp tool_atom("kubectl"), do: :kubectl
  defp tool_atom("query_db"), do: :query_db
  defp tool_atom("prometheus_query"), do: :prometheus_query
  defp tool_atom("mcp_runbook"), do: :mcp_runbook

  defp decision_event("execute"), do: :execute
  defp decision_event("audit_and_execute"), do: :audit_and_execute

  defp maybe_store_context(attrs, %ToolCall{reasoning_context: context})
       when map_size(context) > 0 do
    Map.put(attrs, :result_summary, encode_context_metadata(context))
  end

  defp maybe_store_context(attrs, _tool_call), do: attrs

  defp maybe_mark_policy_denial(attrs, %{auto: false, gated: false}) do
    Map.merge(attrs, %{result_status: "error", result_summary: summarize(:policy_denied)})
  end

  defp maybe_mark_policy_denial(attrs, _policy), do: attrs

  defp encode_context_metadata(context) do
    @context_metadata_prefix <> Jason.encode!(%{"reasoning_context" => context})
  end

  defp decode_context(nil), do: %{}

  defp decode_context(@context_metadata_prefix <> encoded_metadata) do
    case Jason.decode(encoded_metadata) do
      {:ok, %{"reasoning_context" => context}} when is_map(context) ->
        %{"reasoning_context" => normalize_reasoning_context(context)}

      _other ->
        %{}
    end
  end

  defp decode_context(summary) when is_binary(summary) do
    case Jason.decode(summary) do
      {:ok, %{"reasoning_context" => context}} when is_map(context) ->
        %{"reasoning_context" => normalize_reasoning_context(context)}

      _other ->
        %{}
    end
  end

  defp normalize_reasoning_context(context) do
    Map.new(context, fn {key, value} ->
      {normalize_context_key(key), normalize_context_value(value)}
    end)
  end

  defp normalize_context_value(value) when is_map(value), do: normalize_reasoning_context(value)

  defp normalize_context_value(value) when is_list(value),
    do: Enum.map(value, &normalize_context_value/1)

  defp normalize_context_value(value), do: value

  defp normalize_context_key(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> key
  end

  defp normalize_context_key(key), do: key

  defp initial_decision(%{gated: true}), do: "gated"
  defp initial_decision(%{auto: false}), do: "rejected"
  defp initial_decision(%{audit: true}), do: "audit_and_execute"
  defp initial_decision(_policy), do: "execute"

  defp maybe_gate_id(%{gated: true}) do
    "gate_" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
  end

  defp maybe_gate_id(_policy), do: nil

  defp gate_id_collision?(%Ecto.Changeset{} = changeset) do
    changeset.errors
    |> Keyword.get_values(:gate_id)
    |> Enum.any?(fn {_message, metadata} -> Keyword.get(metadata, :constraint) == :unique end)
  end

  defp gate_id_collision?(_error), do: false

  defp broadcast(_opts, nil, _message), do: :ok

  defp broadcast(opts, alert_id, message) do
    Phoenix.PubSub.broadcast(Keyword.fetch!(opts, :pubsub), "alert:#{alert_id}", message)
  end

  defp maybe_reply(opts, gate_id, result) do
    case Keyword.get(opts, :reply_to) do
      pid when is_pid(pid) -> send(pid, {:gate_result, gate_id, result})
      _other -> :ok
    end
  end

  defp summarize(term) do
    term
    |> inspect()
    |> String.slice(0, 255)
  end
end
