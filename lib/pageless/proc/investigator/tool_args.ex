defmodule Pageless.Proc.Investigator.ToolArgs do
  @moduledoc "Normalizes and JSON-encodes investigator tool-call arguments."

  @doc "Normalizes Gemini function-call args for a specific tool surface."
  @spec normalize(atom(), map()) :: {:ok, term()} | {:error, term()}
  def normalize(:kubectl, %{"args" => args}) when is_list(args) and args != [] do
    if Enum.all?(args, &is_binary/1),
      do: {:ok, args},
      else: {:error, {:malformed_tool_args, :kubectl}}
  end

  def normalize(:prometheus_query, %{"promql" => promql}) when is_binary(promql) do
    case String.trim(promql) do
      "" -> {:error, {:malformed_tool_args, :prometheus_query}}
      trimmed -> {:ok, trimmed}
    end
  end

  def normalize(:query_db, %{"sql" => sql}) when is_binary(sql) do
    case String.trim(sql) do
      "" -> {:error, {:malformed_tool_args, :query_db}}
      trimmed -> {:ok, trimmed}
    end
  end

  def normalize(:mcp_runbook, %{"tool_name" => name, "params" => params} = args)
      when is_binary(name) and is_map(params),
      do: {:ok, args}

  def normalize(tool, _args), do: {:error, {:malformed_tool_args, tool}}

  @doc "Encodes normalized tool args into the audit-row JSON shape."
  @spec encode(atom(), term()) :: map()
  def encode(_tool, {:malformed, raw_args}), do: %{"raw_args" => raw_args}
  def encode(:kubectl, args), do: %{"argv" => args}
  def encode(:query_db, sql), do: %{"sql" => sql}
  def encode(:prometheus_query, promql), do: %{"promql" => promql}
  def encode(:mcp_runbook, args) when is_map(args), do: args
  def encode(:mcp_runbook, args), do: %{"tool_name" => nil, "params" => args}
end
