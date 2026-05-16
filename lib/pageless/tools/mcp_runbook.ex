defmodule Pageless.Tools.MCPRunbook do
  @moduledoc "MCP-backed runbook dispatch wrapper for capability-gated tool calls."

  @behaviour Pageless.Tools.MCPRunbook.Behaviour

  alias Pageless.Governance.ToolCall
  alias Pageless.Svc.MCPClient.ToolResult
  alias Pageless.Tools.MCPRunbook.Behaviour

  @default_mcp_client Pageless.Svc.MCPClient
  @allowed_tools ~w(read_file list_directory list_allowed_directories)

  @doc "Executes an MCP runbook tool call with application defaults."
  @impl true
  @spec exec(ToolCall.t()) :: {:ok, Behaviour.ok_result()} | {:error, Behaviour.error_result()}
  def exec(%ToolCall{tool: :mcp_runbook} = call) do
    exec(call, Application.get_env(:pageless, :mcp_runbook, []))
  end

  @doc "Executes an MCP runbook tool call with explicit options."
  @impl true
  @spec exec(ToolCall.t(), Behaviour.exec_opts()) ::
          {:ok, Behaviour.ok_result()} | {:error, Behaviour.error_result()}
  def exec(%ToolCall{tool: :mcp_runbook, args: args}, opts) do
    case validate_args(args) do
      {:ok, name, params} ->
        command = command_summary(name, params)
        start_ms = System.monotonic_time(:millisecond)

        opts
        |> Keyword.get(:mcp_client, @default_mcp_client)
        |> call_mcp_tool(name, params, adapter_opts(opts))
        |> normalize_result(command, start_ms)

      {:error, :invalid_args} ->
        invalid_args()

      {:error, :invalid_args, _name} ->
        invalid_args()

      {:error, reason, name} when reason in [:tool_not_allowed, :path_escape] ->
        rejected_call(reason, name)
    end
  end

  @doc "Returns the Gemini function declaration for MCP runbook calls."
  @impl true
  @spec function_call_definition() :: map()
  def function_call_definition do
    %{
      "name" => "mcp_runbook",
      "description" => "Read runbook material through a configured MCP tool.",
      "parameters" => %{
        "type" => "object",
        "required" => ["tool_name", "params"],
        "properties" => %{
          "tool_name" => %{"type" => "string"},
          "params" => %{"type" => "object"}
        }
      }
    }
  end

  defp validate_args(%{"tool_name" => name, "params" => params})
       when is_binary(name) and is_map(params) do
    validate_allowed_tool(name, params)
  end

  defp validate_args(_args), do: {:error, :invalid_args}

  @spec validate_allowed_tool(String.t(), map()) ::
          {:ok, String.t(), map()}
          | {:error, :tool_not_allowed | :path_escape | :invalid_args, String.t()}
  defp validate_allowed_tool(name, _params) when name not in @allowed_tools do
    {:error, :tool_not_allowed, name}
  end

  defp validate_allowed_tool("read_file" = name, params),
    do: validate_read_file_path(name, params)

  defp validate_allowed_tool(name, params), do: {:ok, name, params}

  @spec validate_read_file_path(String.t(), map()) ::
          {:ok, String.t(), map()} | {:error, :invalid_args | :path_escape, String.t()}
  defp validate_read_file_path(name, %{"path" => path} = params) when is_binary(path) do
    if safe_runbook_path?(path) do
      {:ok, name, params}
    else
      {:error, :path_escape, name}
    end
  end

  defp validate_read_file_path(name, _params), do: {:error, :invalid_args, name}

  @spec safe_runbook_path?(String.t()) :: boolean()
  defp safe_runbook_path?(path) do
    Path.type(path) != :absolute and not parent_segment?(path) and under_runbook_root?(path)
  end

  @spec parent_segment?(String.t()) :: boolean()
  defp parent_segment?(path) do
    path
    |> Path.split()
    |> Enum.any?(&(&1 == ".."))
  end

  @spec under_runbook_root?(String.t()) :: boolean()
  defp under_runbook_root?(path) do
    root = runbook_root()

    path
    |> Path.expand(root)
    |> path_under?(root)
  end

  @spec runbook_root() :: String.t()
  defp runbook_root do
    :pageless
    |> :code.priv_dir()
    |> to_string()
    |> Path.join("runbooks")
    |> Path.expand()
  end

  @spec path_under?(String.t(), String.t()) :: boolean()
  defp path_under?(path, root) do
    path == root or String.starts_with?(path, root <> "/")
  end

  @spec call_mcp_tool(module(), String.t(), map(), keyword()) ::
          {:ok, ToolResult.t()} | {:error, term()}
  defp call_mcp_tool(mcp_client, name, params, opts) do
    mcp_client.call_tool(name, params, opts)
  end

  @spec adapter_opts(keyword()) :: keyword()
  defp adapter_opts(opts) do
    []
    |> maybe_put_opt(:client, Keyword.get(opts, :client))
    |> maybe_put_opt(:timeout, Keyword.get(opts, :timeout))
  end

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, key, value), do: opts ++ [{key, value}]

  @spec normalize_result(
          {:ok, ToolResult.t()} | {:error, term()},
          [String.t()],
          integer()
        ) :: {:ok, Behaviour.ok_result()} | {:error, Behaviour.error_result()}
  defp normalize_result({:ok, %ToolResult{is_error: false, content: content}}, command, start_ms) do
    {:ok, base_result(concat_text(content), 0, command, start_ms)}
  end

  defp normalize_result({:ok, %ToolResult{is_error: true, content: content}}, command, start_ms) do
    {:error,
     content
     |> concat_text()
     |> base_result(1, command, start_ms)
     |> Map.put(:reason, :mcp_domain_error)}
  end

  defp normalize_result({:error, {:mcp_error, code, message}}, command, start_ms) do
    {:error, error_result({:mcp_error, code, message}, command, start_ms)}
  end

  defp normalize_result({:error, {:mcp_unexpected, _raw}}, command, start_ms) do
    {:error, error_result(:mcp_unexpected, command, start_ms)}
  end

  defp normalize_result({:error, reason}, command, start_ms) do
    {:error, error_result({:mcp_error, :unexpected, inspect(reason)}, command, start_ms)}
  end

  @spec concat_text([ToolResult.content_block()]) :: String.t()
  defp concat_text(content) do
    content
    |> Enum.filter(&text_block?/1)
    |> Enum.map_join(&Map.fetch!(&1, :text))
  end

  defp text_block?(%{type: :text, text: text}) when is_binary(text), do: true
  defp text_block?(_block), do: false

  @spec base_result(String.t(), 0 | 1, [String.t()], integer()) :: Behaviour.ok_result()
  defp base_result(output, exit_status, command, start_ms) do
    %{
      output: output,
      exit_status: exit_status,
      command: command,
      duration_ms: duration_since(start_ms)
    }
  end

  @spec error_result(Behaviour.error_reason(), [String.t()], integer()) ::
          Behaviour.error_result()
  defp error_result(reason, command, start_ms) do
    %{
      reason: reason,
      output: nil,
      exit_status: nil,
      command: command,
      duration_ms: duration_since(start_ms)
    }
  end

  @spec invalid_args() :: {:error, Behaviour.error_result()}
  defp invalid_args do
    {:error, %{reason: :invalid_args, output: nil, exit_status: nil, command: [], duration_ms: 0}}
  end

  @spec rejected_call(:tool_not_allowed | :path_escape, String.t()) ::
          {:error, Behaviour.error_result()}
  defp rejected_call(reason, name) do
    {:error, %{reason: reason, output: nil, exit_status: nil, command: [name], duration_ms: 0}}
  end

  @spec command_summary(String.t(), map()) :: [String.t()]
  defp command_summary(name, params) do
    [name | params |> Enum.map(&param_summary/1) |> Enum.sort()]
  end

  defp param_summary({key, value}), do: "#{key}=#{stringify(value)}"

  defp stringify(value) when is_binary(value), do: value
  defp stringify(value), do: inspect(value)

  @spec duration_since(integer()) :: non_neg_integer()
  defp duration_since(start_ms) do
    max(System.monotonic_time(:millisecond) - start_ms, 0)
  end
end
