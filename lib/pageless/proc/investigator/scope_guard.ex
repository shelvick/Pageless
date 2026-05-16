defmodule Pageless.Proc.Investigator.ScopeGuard do
  @moduledoc "Profile-scope and tool-call helpers for investigator agents."

  alias Pageless.Config.Rules
  alias Pageless.Governance.SqlSelectOnlyParser
  alias Pageless.Governance.VerbTableClassifier
  alias Pageless.Proc.Investigator.Profile

  @doc "Checks whether a profile permits a normalized tool call before it reaches the gate."
  @spec tool_call_in_profile_scope?(Profile.t(), atom(), term()) ::
          :ok
          | {:error, {:out_of_scope_tool, atom()}}
          | {:error, {:verb_not_in_profile, String.t()}}
          | {:error, {:table_not_in_profile_allowlist, String.t()}}
  def tool_call_in_profile_scope?(%Profile{} = profile, :kubectl, args) do
    case profile.tool_scope.kubectl do
      nil ->
        {:error, {:out_of_scope_tool, :kubectl}}

      %{verbs: :all} ->
        :ok

      %{verbs: verbs} ->
        case VerbTableClassifier.extract_verb(args) do
          {:ok, verb} -> if verb in verbs, do: :ok, else: {:error, {:verb_not_in_profile, verb}}
          {:error, _reason} -> {:error, {:verb_not_in_profile, "<unknown>"}}
        end
    end
  end

  def tool_call_in_profile_scope?(%Profile{} = profile, :prometheus_query, _args) do
    if profile.tool_scope.prometheus_query,
      do: :ok,
      else: {:error, {:out_of_scope_tool, :prometheus_query}}
  end

  def tool_call_in_profile_scope?(%Profile{} = profile, :query_db, sql) do
    case profile.tool_scope.query_db do
      nil ->
        {:error, {:out_of_scope_tool, :query_db}}

      %{tables: :all} ->
        :ok

      %{tables: tables} ->
        allowed = tables |> Enum.map(&String.downcase/1) |> MapSet.new()

        case SqlSelectOnlyParser.extract_relations(sql) do
          {:ok, relations} ->
            case Enum.find(relations, &(not MapSet.member?(allowed, String.downcase(&1)))) do
              nil -> :ok
              relation -> {:error, {:table_not_in_profile_allowlist, relation}}
            end

          {:error, _reason} ->
            {:error, {:table_not_in_profile_allowlist, "<unparseable>"}}
        end
    end
  end

  def tool_call_in_profile_scope?(%Profile{} = profile, :mcp_runbook, _args) do
    if profile.tool_scope.mcp_runbook,
      do: :ok,
      else: {:error, {:out_of_scope_tool, :mcp_runbook}}
  end

  def tool_call_in_profile_scope?(%Profile{}, tool, _args) when is_atom(tool) do
    {:error, {:out_of_scope_tool, tool}}
  end

  @doc "Normalizes Gemini function-call argument maps into the tool-specific payload shape."
  @spec normalize_tool_call_args(atom(), map()) :: {:ok, term()} | {:error, term()}
  def normalize_tool_call_args(:kubectl, %{"args" => args})
      when is_list(args) and args != [] do
    if Enum.all?(args, &is_binary/1),
      do: {:ok, args},
      else: {:error, {:malformed_tool_args, :kubectl}}
  end

  def normalize_tool_call_args(:prometheus_query, %{"promql" => promql})
      when is_binary(promql) do
    case String.trim(promql) do
      "" -> {:error, {:malformed_tool_args, :prometheus_query}}
      trimmed -> {:ok, trimmed}
    end
  end

  def normalize_tool_call_args(:query_db, %{"sql" => sql}) when is_binary(sql) do
    case String.trim(sql) do
      "" -> {:error, {:malformed_tool_args, :query_db}}
      trimmed -> {:ok, trimmed}
    end
  end

  def normalize_tool_call_args(:mcp_runbook, %{"tool_name" => name, "params" => params} = args)
      when is_binary(name) and is_map(params),
      do: {:ok, args}

  def normalize_tool_call_args(tool, _args), do: {:error, {:malformed_tool_args, tool}}

  @doc "Produces a conservative classification string for audit rows written before gate dispatch."
  @spec best_effort_classify(Rules.t(), atom(), term()) :: String.t()
  def best_effort_classify(_rules, :kubectl, {:malformed, _args}), do: "write_prod_high"

  def best_effort_classify(%Rules{} = rules, :kubectl, args) do
    case VerbTableClassifier.classify(args, rules.kubectl_verbs) do
      {:ok, class, _verb} -> Atom.to_string(class)
      {:error, _reason} -> "write_prod_high"
    end
  end

  def best_effort_classify(_rules, _tool, _args), do: "read"

  @doc "Encodes normalized tool arguments into the audit-trail shape for that tool."
  @spec encode_args(atom(), term()) :: map()
  def encode_args(_tool, {:malformed, raw_args}), do: %{"raw_args" => raw_args}
  def encode_args(:kubectl, args), do: %{"argv" => args}
  def encode_args(:query_db, sql), do: %{"sql" => sql}
  def encode_args(:prometheus_query, promql), do: %{"promql" => promql}
  def encode_args(:mcp_runbook, args) when is_map(args), do: args
  def encode_args(:mcp_runbook, args), do: %{"tool_name" => nil, "params" => args}

  @doc "Extracts the tool classification from a gate response for agent-state events."
  @spec classification({:ok, term()} | {:gated, String.t()} | {:error, term()}) :: atom()
  def classification({:ok, %{classification: class}}), do: class
  def classification({:ok, _result}), do: :read
  def classification({:gated, _gate_id}), do: :write_prod_high
  def classification({:error, _reason}), do: :read

  @doc "Extracts the event payload value from a gate response."
  @spec result_value({:ok, term()} | {:gated, String.t()} | {:error, term()}) :: term()
  def result_value({:ok, result}), do: result
  def result_value({:gated, gate_id}), do: %{status: :gated, gate_id: gate_id}
  def result_value({:error, reason}), do: %{status: :error, reason: reason}
end
