defmodule Pageless.Proc.Escalator do
  @moduledoc "Single-shot agent that drafts and sends a structured page-out for an alert."

  use GenServer

  require Logger

  alias Ecto.Adapters.SQL.Sandbox
  alias Pageless.AlertEnvelope
  alias Pageless.Data.AgentState
  alias Pageless.Svc.GeminiClient.FunctionCall
  alias Pageless.Svc.GeminiClient.Response

  defstruct [
    :agent_id,
    :alert_id,
    :envelope,
    :pubsub,
    :gemini_client,
    :resolve_client,
    :audit_repo,
    :sandbox_owner,
    :parent,
    :routing_key,
    sequence: 0
  ]

  @type t :: %__MODULE__{
          agent_id: String.t(),
          alert_id: String.t(),
          envelope: AlertEnvelope.t(),
          pubsub: atom(),
          gemini_client: module(),
          resolve_client: module(),
          audit_repo: module(),
          sandbox_owner: pid() | nil,
          parent: pid() | nil,
          routing_key: String.t() | nil,
          sequence: non_neg_integer()
        }

  @type opts :: [
          alert_id: String.t(),
          envelope: AlertEnvelope.t(),
          pubsub: atom(),
          gemini_client: module(),
          resolve_client: module(),
          sandbox_owner: pid() | nil,
          audit_repo: module(),
          parent: pid() | nil,
          routing_key: String.t() | nil
        ]

  @doc "Starts the Escalator agent."
  @spec start_link(opts()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    state = %__MODULE__{
      agent_id: "escalator-#{System.unique_integer([:positive])}",
      alert_id: Keyword.fetch!(opts, :alert_id),
      envelope: Keyword.fetch!(opts, :envelope),
      pubsub: Keyword.fetch!(opts, :pubsub),
      gemini_client: Keyword.fetch!(opts, :gemini_client),
      resolve_client: Keyword.fetch!(opts, :resolve_client),
      audit_repo: Keyword.fetch!(opts, :audit_repo),
      sandbox_owner: Keyword.get(opts, :sandbox_owner),
      parent: Keyword.get(opts, :parent),
      routing_key: Keyword.get(opts, :routing_key)
    }

    {:ok, state, {:continue, :setup}}
  end

  @impl true
  def handle_continue(:setup, state) do
    allow_sandbox(state)

    state =
      state
      |> append(:spawned, %{envelope_summary: envelope_summary(state.envelope)})
      |> broadcast({:escalator_spawned, state.agent_id, state.alert_id})

    send(self(), :run)
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
    |> build_page_payload()
    |> finish_run(state)
  end

  @spec build_page_payload(t()) :: {:ok, String.t(), map()} | {:error, term()}
  defp build_page_payload(state) do
    case state.gemini_client.generate(gemini_opts(state)) do
      {:ok,
       %Response{function_calls: [%FunctionCall{name: "page_out", args: args} | _], text: text}} ->
        summary_text =
          non_empty(
            text,
            Map.get(args, "summary") || Map.get(args, :summary) || state.envelope.title
          )

        {:ok, summary_text, page_from_args(state.envelope, args)}

      {:ok, %Response{function_calls: []}} ->
        {:ok, "fallback: Gemini did not emit a function call; synthesized page from envelope",
         fallback_page(state.envelope)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec finish_run({:ok, String.t(), map()} | {:error, term()}, t()) :: {:stop, :normal, t()}
  defp finish_run({:ok, reasoning, page_payload}, state) do
    state =
      state
      |> append(:reasoning_line, %{text: reasoning})
      |> broadcast({:escalator_reasoning, state.agent_id, reasoning})

    case state.resolve_client.escalate(state.envelope, page_payload,
           routing_key: state.routing_key,
           metadata: %{alert_id: state.alert_id}
         ) do
      {:ok, %{status: status, dedup_key: dedup_key}} ->
        state
        |> append(:tool_call, %{
          tool: "resolve_client.escalate",
          args: page_payload,
          result: %{status: status, dedup_key: dedup_key},
          classification: :write_prod_high
        })
        |> broadcast({:page_out_sent, state.agent_id, state.alert_id, page_payload})
        |> complete(:sent, page_payload, nil)

      {:ok, :noop} ->
        state
        |> append(:tool_call, %{
          tool: "resolve_client.escalate",
          args: page_payload,
          result: :noop,
          classification: :write_prod_high
        })
        |> broadcast({:page_out_sent, state.agent_id, state.alert_id, page_payload})
        |> complete(:noop, page_payload, nil)

      {:error, reason} ->
        state
        |> append(:tool_error, %{
          tool: "resolve_client.escalate",
          args: page_payload,
          reason: reason
        })
        |> broadcast({:page_out_failed, state.agent_id, state.alert_id, reason})
        |> complete(:failed, page_payload, reason)
    end
  end

  defp finish_run({:error, reason}, state) do
    state
    |> append(:tool_error, %{tool: "gemini.generate", reason: reason})
    |> broadcast({:page_out_failed, state.agent_id, state.alert_id, reason})
    |> complete(:failed, %{}, reason)
  end

  @spec complete(t(), :sent | :noop | :failed, map(), term()) :: {:stop, :normal, t()}
  defp complete(state, outcome, page_payload, reason) do
    state =
      append(state, :final_state, %{outcome: outcome, page_payload: page_payload, reason: reason})

    notify_parent(state, outcome, reason)
    {:stop, :normal, state}
  end

  @spec append(t(), AgentState.event_type(), map()) :: t()
  defp append(state, event_type, payload) do
    attrs = %{
      alert_id: state.alert_id,
      agent_id: state.agent_id,
      agent_type: :escalator,
      event_type: event_type,
      payload: payload,
      sequence: state.sequence
    }

    case AgentState.append_event(state.audit_repo, attrs) do
      {:ok, _row} -> :ok
      {:error, reason} -> Logger.warning("failed to append escalator state: #{inspect(reason)}")
    end

    %{state | sequence: state.sequence + 1}
  end

  @spec broadcast(t(), tuple()) :: t()
  defp broadcast(state, event) do
    :ok = Phoenix.PubSub.broadcast(state.pubsub, "alert:#{state.alert_id}", event)
    state
  end

  @spec notify_parent(t(), :sent | :noop | :failed, term()) :: :ok
  defp notify_parent(%{parent: nil}, _outcome, _reason), do: :ok

  defp notify_parent(state, outcome, reason) do
    send(
      state.parent,
      {:escalator_complete, state.alert_id, state.agent_id, %{outcome: outcome, reason: reason}}
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
      Logger.warning("failed to allow escalator sandbox access: #{inspect(error)}")
      :ok
  end

  @spec gemini_opts(t()) :: keyword()
  defp gemini_opts(state) do
    [
      model: :flash,
      temperature: 0.0,
      tool_choice: {:specific, "page_out"},
      prompt: inspect(envelope_summary(state.envelope)),
      system_instruction:
        "You are an on-call escalation drafter. Compose a single concise page-out for a human operator.",
      tools: [page_out_tool()]
    ]
  end

  @spec page_out_tool() :: map()
  defp page_out_tool do
    %{
      function_declarations: [
        %{
          name: "page_out",
          parameters: %{
            type: "object",
            required: ["summary", "severity"],
            properties: %{
              summary: %{type: "string"},
              severity: %{type: "string", enum: ["critical", "error", "warning", "info"]},
              dedup_key: %{type: "string"},
              runbook_link: %{type: "string"},
              extra: %{type: "object"}
            }
          }
        }
      ]
    }
  end

  @spec page_from_args(AlertEnvelope.t(), map()) :: map()
  defp page_from_args(envelope, args) do
    %{
      summary: Map.get(args, "summary") || Map.get(args, :summary) || envelope.title,
      severity:
        normalize_severity(
          Map.get(args, "severity") || Map.get(args, :severity),
          envelope.severity
        ),
      dedup_key: Map.get(args, "dedup_key") || Map.get(args, :dedup_key) || envelope.alert_id,
      runbook_link: Map.get(args, "runbook_link") || Map.get(args, :runbook_link),
      extra: Map.get(args, "extra") || Map.get(args, :extra) || %{}
    }
  end

  @spec fallback_page(AlertEnvelope.t()) :: map()
  defp fallback_page(envelope) do
    %{
      summary: envelope.title,
      severity: envelope.severity,
      dedup_key: envelope.alert_id,
      runbook_link: nil,
      extra: %{}
    }
  end

  @spec normalize_severity(term(), atom()) :: :critical | :error | :warning | :info
  defp normalize_severity(severity, _fallback)
       when severity in [:critical, :error, :warning, :info],
       do: severity

  defp normalize_severity(severity, fallback) when is_binary(severity) do
    case severity do
      "critical" -> :critical
      "error" -> :error
      "warning" -> :warning
      "info" -> :info
      _other -> normalize_severity(fallback, :critical)
    end
  end

  defp normalize_severity(_severity, fallback), do: normalize_severity(fallback, :critical)

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

  @spec non_empty(String.t() | nil, String.t()) :: String.t()
  defp non_empty("", fallback), do: fallback
  defp non_empty(nil, fallback), do: fallback
  defp non_empty(value, _fallback), do: value
end
