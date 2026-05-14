defmodule Pageless.Proc.Triager do
  @moduledoc "Single-shot agent that classifies an alert and dispatches investigators."

  use GenServer

  require Logger

  alias Ecto.Adapters.SQL.Sandbox
  alias Pageless.AlertEnvelope
  alias Pageless.Config.Rules
  alias Pageless.Data.AgentState
  alias Pageless.Sup.Alert
  alias Pageless.Svc.GeminiClient.FunctionCall
  alias Pageless.Svc.GeminiClient.Response

  @valid_topologies ~w(fan_out chain single)a
  @valid_profiles ~w(logs metrics deploys latency db_load pool_state generic)a

  defstruct [
    :agent_id,
    :alert_id,
    :envelope,
    :pubsub,
    :gemini_client,
    :audit_repo,
    :sandbox_owner,
    :parent,
    :alert_sup,
    :rules,
    :investigator_module,
    sequence: 0
  ]

  @type topology :: :fan_out | :chain | :single
  @type profile_name ::
          :logs | :metrics | :deploys | :latency | :db_load | :pool_state | :generic
  @type alert_class ::
          :service_down_with_recent_deploy | :latency_creep | :db_pool_exhaustion | :unknown

  @type t :: %__MODULE__{
          agent_id: String.t(),
          alert_id: String.t(),
          envelope: AlertEnvelope.t(),
          pubsub: atom(),
          gemini_client: module(),
          audit_repo: module(),
          sandbox_owner: pid() | nil,
          parent: pid() | nil,
          alert_sup: pid(),
          rules: Rules.t(),
          investigator_module: module(),
          sequence: non_neg_integer()
        }

  @type opts :: [
          alert_id: String.t(),
          envelope: AlertEnvelope.t(),
          pubsub: atom(),
          gemini_client: module(),
          sandbox_owner: pid() | nil,
          audit_repo: module(),
          parent: pid() | nil,
          alert_sup: pid(),
          rules: Rules.t(),
          investigator_module: module()
        ]

  @doc "Starts the Triager agent."
  @spec start_link(opts()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc """
  Triggers the classification + dispatch run.

  Setup work (`allow_sandbox`, audit `:spawned` row, `:triager_spawned` broadcast)
  completes during `handle_continue/2` before this returns. The caller is
  expected to invoke `kick_off/1` only after any out-of-band setup the
  Triager process needs is in place — most importantly any test-double
  allowances (`Mox.allow/3`) on the configured `gemini_client`.
  """
  @spec kick_off(GenServer.server()) :: :ok
  def kick_off(server), do: send(server, :run) |> then(fn _ -> :ok end)

  @impl true
  def init(opts) do
    state = %__MODULE__{
      agent_id: "triager-#{System.unique_integer([:positive])}",
      alert_id: Keyword.fetch!(opts, :alert_id),
      envelope: Keyword.fetch!(opts, :envelope),
      pubsub: Keyword.fetch!(opts, :pubsub),
      gemini_client: Keyword.fetch!(opts, :gemini_client),
      audit_repo: Keyword.fetch!(opts, :audit_repo),
      sandbox_owner: Keyword.get(opts, :sandbox_owner),
      parent: Keyword.get(opts, :parent),
      alert_sup: Keyword.fetch!(opts, :alert_sup),
      rules: Keyword.fetch!(opts, :rules),
      investigator_module: Keyword.get(opts, :investigator_module, Pageless.Proc.Investigator)
    }

    {:ok, state, {:continue, :setup}}
  end

  @impl true
  def handle_continue(:setup, state) do
    allow_sandbox(state)

    state =
      state
      |> append(:spawned, %{envelope_summary: envelope_summary(state.envelope)})
      |> broadcast({:triager_spawned, state.agent_id, state.alert_id})

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
    |> classify_alert()
    |> finish_run(state)
  end

  @spec classify_alert(t()) :: {:ok, map()} | {:error, term()}
  defp classify_alert(state) do
    case state.gemini_client.generate(gemini_opts(state)) do
      {:ok,
       %Response{function_calls: [%FunctionCall{name: "classify_and_dispatch", args: args} | _]}} ->
        {:ok, args}

      {:ok, %Response{function_calls: []}} ->
        {:ok,
         %{
           "class" => "unknown",
           "confidence" => 0.0,
           "rationale" => "fallback: Gemini did not emit a function call; routing to :unknown"
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec finish_run({:ok, map()} | {:error, term()}, t()) :: {:stop, :normal, t()}
  defp finish_run({:ok, args}, state) do
    case route_classification(state, args) do
      {:ok, classification} ->
        state
        |> record_classification(classification)
        |> dispatch_profiles(classification)
        |> finalize_dispatch(classification)

      {:error, reason} ->
        fail_run(state, "rules.lookup", reason, nil)
    end
  end

  defp finish_run({:error, reason}, state), do: fail_run(state, "gemini.generate", reason, nil)

  @spec record_classification(t(), map()) :: t()
  defp record_classification(state, classification) do
    state
    |> append(:reasoning_line, %{text: classification.rationale})
    |> broadcast({:triager_reasoning, state.agent_id, classification.rationale})
    |> append(:findings, %{
      class: classification.class,
      confidence: classification.confidence,
      topology: classification.topology,
      profiles: classification.profiles,
      rationale: classification.rationale
    })
    |> broadcast({
      :triager_classified,
      state.agent_id,
      state.alert_id,
      %{
        class: classification.class,
        confidence: classification.confidence,
        topology: classification.topology,
        profiles: classification.profiles
      }
    })
  end

  @spec dispatch_profiles(t(), map()) :: {t(), [map()]}
  defp dispatch_profiles(state, classification) do
    classification.profiles
    |> Enum.with_index()
    |> Enum.reduce({state, []}, fn {profile, index}, {current_state, dispatched} ->
      chain_position = chain_position(classification.topology, index)

      args = %{
        profile: profile,
        chain_position: chain_position,
        topology: classification.topology
      }

      opts = [
        profile: profile,
        chain_position: chain_position,
        topology: classification.topology,
        parent: self()
      ]

      case Alert.start_agent(current_state.alert_sup, current_state.investigator_module, opts) do
        {:ok, pid} ->
          current_state =
            append(current_state, :tool_call, %{
              tool: "sup_alert.start_agent",
              args: args,
              result: %{pid: inspect(pid)},
              classification: :read
            })

          {current_state,
           [%{profile: profile, pid: pid, chain_position: chain_position} | dispatched]}

        {:error, reason} ->
          current_state =
            append(current_state, :tool_error, %{
              tool: "sup_alert.start_agent",
              args: args,
              reason: reason
            })

          {current_state, dispatched}
      end
    end)
    |> then(fn {current_state, dispatched} -> {current_state, Enum.reverse(dispatched)} end)
  end

  @spec finalize_dispatch({t(), [map()]}, map()) :: {:stop, :normal, t()}
  defp finalize_dispatch({state, dispatched}, classification) do
    state = broadcast(state, {:triager_dispatched, state.agent_id, state.alert_id, dispatched})
    outcome = dispatch_outcome(dispatched)
    class = final_class(outcome, classification.class)

    state =
      append(state, :final_state, %{
        outcome: outcome,
        class: class,
        dispatched_count: length(dispatched),
        reason: nil
      })

    notify_parent(state, outcome, class, length(dispatched))
    {:stop, :normal, state}
  end

  @spec fail_run(t(), String.t(), term(), alert_class() | nil) :: {:stop, :normal, t()}
  defp fail_run(state, tool, reason, class) do
    state =
      state
      |> append(:tool_error, %{tool: tool, reason: reason})
      |> broadcast({:triager_failed, state.agent_id, state.alert_id, reason})
      |> append(:final_state, %{
        outcome: :failed,
        class: class,
        dispatched_count: 0,
        reason: reason
      })

    notify_parent(state, :failed, class, 0)
    {:stop, :normal, state}
  end

  @spec dispatch_outcome([map()]) :: :dispatched | :failed
  defp dispatch_outcome([]), do: :failed
  defp dispatch_outcome(_dispatched), do: :dispatched

  @spec final_class(:dispatched | :failed, alert_class()) :: alert_class() | nil
  defp final_class(:dispatched, class), do: class
  defp final_class(:failed, _class), do: nil

  @spec chain_position(topology(), non_neg_integer()) :: non_neg_integer()
  defp chain_position(:chain, index), do: index + 1
  defp chain_position(_topology, _index), do: 0

  @spec route_classification(t(), map()) :: {:ok, map()} | {:error, term()}
  defp route_classification(state, args) do
    class_string = args |> get_arg("class") |> non_empty("unknown")
    routing = state.rules.alert_class_routing

    with {:ok, class_string, entry} <- lookup_route(routing, class_string),
         {:ok, topology} <- topology_from_entry(entry),
         {:ok, profiles} <- profiles_from_entry(entry) do
      {:ok,
       %{
         class: class_atom(class_string),
         confidence: confidence(args),
         rationale:
           args |> get_arg("rationale") |> non_empty("fallback: missing Gemini rationale"),
         topology: topology,
         profiles: profiles
       }}
    end
  end

  @spec lookup_route(map(), String.t()) :: {:ok, String.t(), map()} | {:error, atom()}
  defp lookup_route(routing, class_string) do
    cond do
      is_map_key(routing, class_string) ->
        {:ok, class_string, Map.fetch!(routing, class_string)}

      is_map_key(routing, "unknown") ->
        {:ok, "unknown", Map.fetch!(routing, "unknown")}

      true ->
        {:error, :missing_unknown_fallback}
    end
  end

  @spec topology_from_entry(map()) :: {:ok, topology()} | {:error, atom()}
  defp topology_from_entry(entry) do
    entry
    |> Map.get("topology")
    |> topology_atom()
    |> case do
      nil -> {:error, :invalid_topology}
      topology -> {:ok, topology}
    end
  end

  @spec profiles_from_entry(map()) :: {:ok, [profile_name()]} | {:error, atom()}
  defp profiles_from_entry(entry) do
    profiles = entry |> Map.get("profiles", []) |> Enum.map(&profile_atom/1)

    if Enum.any?(profiles, &is_nil/1) do
      {:error, :invalid_profile}
    else
      {:ok, profiles}
    end
  end

  @spec topology_atom(String.t() | atom() | nil) :: topology() | nil
  defp topology_atom(topology) when topology in @valid_topologies, do: topology
  defp topology_atom("fan_out"), do: :fan_out
  defp topology_atom("chain"), do: :chain
  defp topology_atom("single"), do: :single
  defp topology_atom(_topology), do: nil

  @spec profile_atom(String.t() | atom()) :: profile_name() | nil
  defp profile_atom(profile) when profile in @valid_profiles, do: profile
  defp profile_atom("logs"), do: :logs
  defp profile_atom("metrics"), do: :metrics
  defp profile_atom("deploys"), do: :deploys
  defp profile_atom("latency"), do: :latency
  defp profile_atom("db_load"), do: :db_load
  defp profile_atom("pool_state"), do: :pool_state
  defp profile_atom("generic"), do: :generic
  defp profile_atom(_profile), do: nil

  @spec class_atom(String.t()) :: alert_class()
  defp class_atom("service_down_with_recent_deploy"), do: :service_down_with_recent_deploy
  defp class_atom("latency_creep"), do: :latency_creep
  defp class_atom("db_pool_exhaustion"), do: :db_pool_exhaustion
  defp class_atom(_class), do: :unknown

  @spec confidence(map()) :: float()
  defp confidence(args) do
    case get_arg(args, "confidence") do
      value when is_float(value) -> value
      value when is_integer(value) -> value / 1
      _value -> 0.0
    end
  end

  @spec get_arg(map(), String.t()) :: term()
  defp get_arg(args, key), do: Map.get(args, key) || Map.get(args, String.to_existing_atom(key))

  @spec append(t(), AgentState.event_type(), map()) :: t()
  defp append(state, event_type, payload) do
    attrs = %{
      alert_id: state.alert_id,
      agent_id: state.agent_id,
      agent_type: :triager,
      event_type: event_type,
      payload: payload,
      sequence: state.sequence
    }

    case AgentState.append_event(state.audit_repo, attrs) do
      {:ok, _row} -> :ok
      {:error, reason} -> Logger.warning("failed to append triager state: #{inspect(reason)}")
    end

    %{state | sequence: state.sequence + 1}
  end

  @spec broadcast(t(), tuple()) :: t()
  defp broadcast(state, event) do
    :ok = Phoenix.PubSub.broadcast(state.pubsub, "alert:#{state.alert_id}", event)
    state
  end

  @spec notify_parent(t(), :dispatched | :failed, alert_class() | nil, non_neg_integer()) :: :ok
  defp notify_parent(%{parent: nil}, _outcome, _class, _dispatched), do: :ok

  defp notify_parent(state, outcome, class, dispatched) do
    send(
      state.parent,
      {:triager_complete, state.alert_id, state.agent_id,
       %{outcome: outcome, class: class, dispatched: dispatched}}
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
      Logger.warning("failed to allow triager sandbox access: #{inspect(error)}")
      :ok
  end

  @spec gemini_opts(t()) :: keyword()
  defp gemini_opts(state) do
    [
      model: :flash,
      temperature: 0.0,
      tool_choice: {:specific, "classify_and_dispatch"},
      prompt: inspect(envelope_summary(state.envelope)),
      system_instruction:
        "You are an alert triage classifier. Given an incoming alert envelope, choose the single best-matching alert class from the provided enum and explain your reasoning briefly. Always return exactly one function call to classify_and_dispatch.",
      tools: [classify_and_dispatch_tool(state.rules)]
    ]
  end

  @spec classify_and_dispatch_tool(Rules.t()) :: map()
  defp classify_and_dispatch_tool(rules) do
    %{
      function_declarations: [
        %{
          name: "classify_and_dispatch",
          parameters: %{
            type: "object",
            required: ["class", "confidence", "rationale"],
            properties: %{
              class: %{type: "string", enum: class_enum(rules)},
              confidence: %{type: "number", minimum: 0.0, maximum: 1.0},
              rationale: %{type: "string"}
            }
          }
        }
      ]
    }
  end

  @spec class_enum(Rules.t()) :: [String.t()]
  defp class_enum(rules) do
    rules.alert_class_routing
    |> Map.keys()
    |> Enum.uniq()
    |> then(fn keys -> if "unknown" in keys, do: keys, else: ["unknown" | keys] end)
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
      labels: envelope.labels,
      annotations: envelope.annotations
    }
  end

  @spec non_empty(term(), String.t()) :: term()
  defp non_empty("", fallback), do: fallback
  defp non_empty(nil, fallback), do: fallback
  defp non_empty(value, _fallback), do: value
end
