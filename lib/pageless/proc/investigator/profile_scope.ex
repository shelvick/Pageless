defmodule Pageless.Proc.Investigator.ProfileScope do
  @moduledoc "Checks whether investigator tool calls fit a profile's tool scope."

  alias Pageless.Governance.SqlSelectOnlyParser
  alias Pageless.Governance.VerbTableClassifier
  alias Pageless.Proc.Investigator.Profile

  @doc "Returns :ok when a normalized tool call is permitted by the profile scope."
  @spec allowed?(Profile.t(), atom(), term()) ::
          :ok
          | {:error, {:out_of_scope_tool, atom()}}
          | {:error, {:verb_not_in_profile, String.t()}}
          | {:error, {:table_not_in_profile_allowlist, String.t()}}
  def allowed?(%Profile{} = profile, :kubectl, args) do
    case profile.tool_scope.kubectl do
      nil ->
        {:error, {:out_of_scope_tool, :kubectl}}

      %{verbs: :all} ->
        :ok

      %{verbs: verbs} ->
        kubectl_verb_allowed?(args, verbs)
    end
  end

  def allowed?(%Profile{} = profile, :prometheus_query, _args) do
    if profile.tool_scope.prometheus_query,
      do: :ok,
      else: {:error, {:out_of_scope_tool, :prometheus_query}}
  end

  def allowed?(%Profile{} = profile, :query_db, sql) do
    case profile.tool_scope.query_db do
      nil ->
        {:error, {:out_of_scope_tool, :query_db}}

      %{tables: :all} ->
        :ok

      %{tables: tables} ->
        query_tables_allowed?(sql, tables)
    end
  end

  def allowed?(%Profile{} = profile, :mcp_runbook, _args) do
    if profile.tool_scope.mcp_runbook,
      do: :ok,
      else: {:error, {:out_of_scope_tool, :mcp_runbook}}
  end

  def allowed?(%Profile{}, tool, _args) when is_atom(tool) do
    {:error, {:out_of_scope_tool, tool}}
  end

  @spec kubectl_verb_allowed?(term(), [String.t()]) ::
          :ok | {:error, {:verb_not_in_profile, String.t()}}
  defp kubectl_verb_allowed?(args, verbs) do
    case VerbTableClassifier.extract_verb(args) do
      {:ok, verb} -> if verb in verbs, do: :ok, else: {:error, {:verb_not_in_profile, verb}}
      {:error, _reason} -> {:error, {:verb_not_in_profile, "<unknown>"}}
    end
  end

  @spec query_tables_allowed?(String.t(), [String.t()]) ::
          :ok | {:error, {:table_not_in_profile_allowlist, String.t()}}
  defp query_tables_allowed?(sql, tables) do
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
