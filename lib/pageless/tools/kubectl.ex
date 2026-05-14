defmodule Pageless.Tools.Kubectl do
  @moduledoc "Subprocess-backed kubectl tool wrapper."

  @behaviour Pageless.Tools.Kubectl.Behaviour

  alias Pageless.Governance.ToolCall
  alias Pageless.Tools.Kubectl.Behaviour

  @default_binary "kubectl"

  @doc "Executes a kubectl tool call with application defaults."
  @impl true
  @spec exec(ToolCall.t()) :: {:ok, Behaviour.ok_result()} | {:error, Behaviour.error_result()}
  def exec(%ToolCall{tool: :kubectl} = call) do
    exec(call, Application.get_env(:pageless, :kubectl, []))
  end

  @doc "Executes a kubectl tool call with explicit options."
  @impl true
  @spec exec(ToolCall.t(), Behaviour.exec_opts()) ::
          {:ok, Behaviour.ok_result()} | {:error, Behaviour.error_result()}
  def exec(%ToolCall{tool: :kubectl, args: args}, opts) do
    with :ok <- validate_args(args),
         {:ok, binary} <- executable(Keyword.get(opts, :binary, @default_binary)) do
      run(binary, args, Keyword.get(opts, :kubeconfig))
    else
      {:error, :invalid_args} -> invalid_args(args)
      {:error, :kubectl_not_found} -> kubectl_not_found(args)
    end
  end

  @doc "Returns the Gemini function declaration for kubectl calls."
  @impl true
  @spec function_call_definition() :: map()
  def function_call_definition do
    %{
      "name" => "kubectl",
      "description" => "Run a capability-gated kubectl command with argv-style arguments.",
      "parameters" => %{
        "type" => "object",
        "required" => ["args"],
        "properties" => %{
          "args" => %{"type" => "array", "items" => %{"type" => "string"}}
        }
      }
    }
  end

  defp validate_args(args) when is_list(args) and args != [] do
    if Enum.all?(args, &is_binary/1), do: :ok, else: {:error, :invalid_args}
  end

  defp validate_args(_args), do: {:error, :invalid_args}

  defp executable(binary) when is_binary(binary) do
    binary
    |> resolved_executable()
    |> executable_result()
  end

  defp executable(_binary), do: {:error, :kubectl_not_found}

  defp resolved_executable(binary) do
    if executable_path?(binary) do
      binary
    else
      :os.find_executable(String.to_charlist(binary))
    end
  end

  defp executable_result(false), do: {:error, :kubectl_not_found}
  defp executable_result(binary) when is_list(binary), do: {:ok, List.to_string(binary)}
  defp executable_result(binary) when is_binary(binary), do: {:ok, binary}

  defp executable_path?(binary) do
    String.contains?(binary, "/") and File.regular?(binary)
  end

  defp run(binary, args, kubeconfig) do
    start_ms = System.monotonic_time(:millisecond)
    env = if is_binary(kubeconfig), do: [{"KUBECONFIG", kubeconfig}], else: []

    case System.cmd(binary, args, env: env, stderr_to_stdout: true) do
      {output, 0} ->
        {:ok, result(output, 0, args, start_ms)}

      {output, exit_status} ->
        {:error, error_result(:nonzero_exit, output, exit_status, args, start_ms)}
    end
  rescue
    error in ErlangError ->
      if error.original == :enoent,
        do: kubectl_not_found(args),
        else: reraise(error, __STACKTRACE__)
  end

  defp result(output, exit_status, args, start_ms) do
    %{
      output: output,
      exit_status: exit_status,
      command: args,
      duration_ms: duration_since(start_ms)
    }
  end

  defp error_result(reason, output, exit_status, args, start_ms) do
    output
    |> result(exit_status, args, start_ms)
    |> Map.put(:reason, reason)
  end

  defp invalid_args(args) do
    {:error,
     %{reason: :invalid_args, output: nil, exit_status: nil, command: args, duration_ms: 0}}
  end

  defp kubectl_not_found(args) do
    {:error,
     %{reason: :kubectl_not_found, output: nil, exit_status: nil, command: args, duration_ms: 0}}
  end

  defp duration_since(start_ms) do
    max(System.monotonic_time(:millisecond) - start_ms, 0)
  end
end
