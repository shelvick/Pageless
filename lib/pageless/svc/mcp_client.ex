defmodule Pageless.Svc.MCPClient do
  @moduledoc "Adapter that normalizes MCP client responses for Pageless agents."

  require Logger

  @behaviour Pageless.Svc.MCPClient.Behaviour

  alias Pageless.Svc.MCPClient.Behaviour
  alias Pageless.Svc.MCPClient.Tool
  alias Pageless.Svc.MCPClient.ToolResult

  @doc "Lists available MCP tools through the configured Anubis client."
  @impl Behaviour
  @spec list_tools(Behaviour.list_opts()) :: {:ok, [Tool.t()]} | {:error, term()}
  def list_tools(opts \\ []) do
    opts
    |> anubis_module()
    |> call_list_tools(client(opts), anubis_opts(opts))
    |> normalize_tool_list_response()
  end

  @doc "Calls an MCP tool through the configured Anubis client."
  @impl Behaviour
  @spec call_tool(String.t(), map(), Behaviour.call_opts()) ::
          {:ok, ToolResult.t()} | {:error, term()}
  def call_tool(name, arguments \\ %{}, opts \\ []) when is_binary(name) and is_map(arguments) do
    opts
    |> anubis_module()
    |> call_mcp_tool(client(opts), name, arguments, anubis_opts(opts))
    |> normalize_tool_call_response()
  end

  @spec call_list_tools(module(), GenServer.server(), keyword()) ::
          {:ok, term()} | {:error, term()}
  defp call_list_tools(anubis_module, client, opts), do: anubis_module.list_tools(client, opts)

  @spec call_mcp_tool(module(), GenServer.server(), String.t(), map(), keyword()) ::
          {:ok, term()} | {:error, term()}
  defp call_mcp_tool(anubis_module, client, name, arguments, opts) do
    anubis_module.call_tool(client, name, arguments, opts)
  end

  @spec normalize_tool_list_response({:ok, term()} | {:error, term()}) ::
          {:ok, [Tool.t()]} | {:error, term()}
  defp normalize_tool_list_response({:ok, response}) do
    case response |> response_result() |> Map.get("tools", []) do
      tools when is_list(tools) -> {:ok, Enum.map(tools, &tool/1)}
      raw -> unexpected(%{"tools" => raw})
    end
  end

  defp normalize_tool_list_response({:error, reason}), do: wrap_error(reason)

  @spec normalize_tool_call_response({:ok, term()} | {:error, term()}) ::
          {:ok, ToolResult.t()} | {:error, term()}
  defp normalize_tool_call_response({:ok, response}) do
    result = response_result(response)

    if is_map(result) do
      {:ok,
       %ToolResult{
         content: result |> Map.get("content", []) |> Enum.map(&content_block/1),
         is_error: Map.get(result, "isError", false),
         raw: result
       }}
    else
      unexpected(result)
    end
  end

  defp normalize_tool_call_response({:error, reason}), do: wrap_error(reason)

  @spec tool(map()) :: Tool.t()
  defp tool(raw) do
    %Tool{
      name: Map.get(raw, "name"),
      description: Map.get(raw, "description"),
      input_schema: Map.get(raw, "inputSchema", %{})
    }
  end

  @spec content_block(map()) :: ToolResult.content_block()
  defp content_block(%{"type" => "text", "text" => text}), do: %{type: :text, text: text}

  defp content_block(%{"type" => "image", "data" => data} = block) do
    %{type: :image, data: data, mime_type: Map.get(block, "mimeType")}
  end

  defp content_block(%{"type" => "resource", "resource" => resource}) do
    %{type: :resource, resource: resource}
  end

  defp content_block(block) when is_map(block), do: %{type: :unknown, raw: block}

  @spec response_result(term()) :: map() | term()
  defp response_result(%{result: result}), do: result

  defp response_result(%{__struct__: module} = response) do
    if function_exported?(module, :get_result, 1) do
      module.get_result(response)
    else
      response
    end
  end

  defp response_result(response), do: response

  @spec wrap_error(term()) :: {:error, term()}
  defp wrap_error(%{code: code, message: message}), do: {:error, {:mcp_error, code, message}}
  defp wrap_error(reason), do: {:error, reason}

  @spec unexpected(term()) :: {:error, {:mcp_unexpected, term()}}
  defp unexpected(raw) do
    Logger.error("mcp_unexpected: #{inspect(raw)}")
    {:error, {:mcp_unexpected, raw}}
  end

  @spec client(keyword()) :: GenServer.server()
  defp client(opts) do
    Keyword.get_lazy(opts, :client, fn ->
      Application.get_env(:pageless, :mcp_filesystem_client, Pageless.MCP.Filesystem)
    end)
  end

  @spec anubis_module(keyword()) :: module()
  defp anubis_module(opts), do: Keyword.get(opts, :anubis_module, Anubis.Client)

  @spec anubis_opts(keyword()) :: keyword()
  defp anubis_opts(opts), do: Keyword.take(opts, [:timeout])
end
