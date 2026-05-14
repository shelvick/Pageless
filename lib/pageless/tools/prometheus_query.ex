defmodule Pageless.Tools.PrometheusQuery do
  @moduledoc "Prometheus HTTP API wrapper for read-only instant queries."

  @behaviour Pageless.Tools.PrometheusQuery.Behaviour

  alias Pageless.Governance.ToolCall
  alias Pageless.Tools.PrometheusQuery.Behaviour

  @default_base_url "http://prometheus.monitoring.svc:9090"
  @default_timeout_ms 5_000

  @doc "Executes a Prometheus query tool call with application defaults."
  @impl true
  @spec exec(ToolCall.t()) :: {:ok, Behaviour.ok_result()} | {:error, Behaviour.error_result()}
  def exec(%ToolCall{tool: :prometheus_query} = call) do
    exec(call, Application.get_env(:pageless, :prometheus_query, []))
  end

  @doc "Executes a Prometheus query tool call with explicit options."
  @impl true
  @spec exec(ToolCall.t(), Behaviour.exec_opts()) ::
          {:ok, Behaviour.ok_result()} | {:error, Behaviour.error_result()}
  def exec(%ToolCall{tool: :prometheus_query, args: promql}, opts) do
    case validate_promql(promql) do
      {:ok, query} -> query_prometheus(query, opts)
      :error -> {:error, invalid_args()}
    end
  end

  @doc "Returns the Gemini function declaration for Prometheus instant queries."
  @impl true
  @spec function_call_definition() :: map()
  def function_call_definition do
    %{
      "name" => "prometheus_query",
      "description" => "Run a read-only PromQL instant query through the capability gate.",
      "parameters" => %{
        "type" => "object",
        "required" => ["promql"],
        "properties" => %{"promql" => %{"type" => "string"}}
      }
    }
  end

  @spec validate_promql(term()) :: {:ok, String.t()} | :error
  defp validate_promql(promql) when is_binary(promql) do
    if String.trim(promql) == "", do: :error, else: {:ok, promql}
  end

  defp validate_promql(_promql), do: :error

  @spec query_prometheus(String.t(), keyword()) ::
          {:ok, Behaviour.ok_result()} | {:error, Behaviour.error_result()}
  defp query_prometheus(promql, opts) do
    start_ms = System.monotonic_time(:millisecond)
    req_module = Keyword.get(opts, :req_module, Req)

    do_query_prometheus(req_module, promql, opts, start_ms)
  end

  @spec do_query_prometheus(module(), String.t(), keyword(), integer()) ::
          {:ok, Behaviour.ok_result()} | {:error, Behaviour.error_result()}
  defp do_query_prometheus(req_module, promql, opts, start_ms) do
    case post_query(req_module, url(opts), request_opts(promql, opts)) do
      {:ok, response} -> handle_response(response, promql, start_ms)
      {:error, reason} -> {:error, network_error(promql, reason, start_ms)}
    end
  rescue
    error in Req.TransportError ->
      {:error, network_error(promql, error.reason, start_ms)}

    error ->
      {:error, network_error(promql, Exception.message(error), start_ms)}
  end

  @spec post_query(module(), String.t(), keyword()) :: {:ok, Req.Response.t()} | {:error, term()}
  defp post_query(req_module, url, opts), do: req_module.post(url, opts)

  @spec url(keyword()) :: String.t()
  defp url(opts) do
    opts
    |> Keyword.get(:base_url, @default_base_url)
    |> String.trim_trailing("/")
    |> Kernel.<>("/api/v1/query")
  end

  @spec request_opts(String.t(), keyword()) :: keyword()
  defp request_opts(promql, opts) do
    [
      form: [query: promql],
      headers: headers(Keyword.get(opts, :auth_token)),
      receive_timeout: Keyword.get(opts, :timeout_ms, @default_timeout_ms),
      retry: false
    ]
    |> maybe_put(:plug, Keyword.get(opts, :plug))
    |> maybe_put(:caller, Keyword.get(opts, :caller))
    |> maybe_put(:response, Keyword.get(opts, :response))
  end

  @spec headers(String.t() | nil) :: [{String.t(), String.t()}]
  defp headers(nil), do: [{"accept", "application/json"}]
  defp headers(token), do: [{"accept", "application/json"}, {"authorization", "Bearer #{token}"}]

  @spec maybe_put(keyword(), atom(), term()) :: keyword()
  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  @spec handle_response(Req.Response.t(), String.t(), integer()) ::
          {:ok, Behaviour.ok_result()} | {:error, Behaviour.error_result()}
  defp handle_response(%{status: status, body: body}, promql, start_ms) when status in 200..299 do
    case body do
      %{"status" => "success", "data" => %{"resultType" => result_type, "result" => result}} ->
        success_result(result_type, result, body, promql, start_ms)

      %{"status" => "error"} ->
        {:error, prometheus_error(:promql_error, status, body, promql, start_ms)}

      _other ->
        {:error, decode_error(status, body, promql, start_ms)}
    end
  end

  defp handle_response(%{status: status, body: body}, promql, start_ms) do
    {:error, prometheus_error(:http_error, status, body, promql, start_ms)}
  end

  @spec success_result(String.t(), term(), map(), String.t(), integer()) ::
          {:ok, Behaviour.ok_result()} | {:error, Behaviour.error_result()}
  defp success_result(result_type, result, raw, promql, start_ms) do
    with {:ok, type} <- result_type(result_type),
         {:ok, samples} <- normalize_samples(type, result) do
      {:ok,
       %{
         result_type: type,
         samples: samples,
         raw: Map.take(raw, ["status"]),
         duration_ms: duration_since(start_ms),
         promql: promql
       }}
    else
      :error -> {:error, decode_error(200, raw, promql, start_ms)}
    end
  end

  @spec result_type(String.t()) :: {:ok, Behaviour.result_type()} | :error
  defp result_type("vector"), do: {:ok, :vector}
  defp result_type("matrix"), do: {:ok, :matrix}
  defp result_type("scalar"), do: {:ok, :scalar}
  defp result_type("string"), do: {:ok, :string}
  defp result_type(_type), do: :error

  @spec normalize_samples(Behaviour.result_type(), term()) :: {:ok, [Behaviour.sample()]} | :error
  defp normalize_samples(:vector, results) when is_list(results) do
    results
    |> Enum.map(&normalize_vector_sample/1)
    |> collect_samples()
  end

  defp normalize_samples(:matrix, results) when is_list(results) do
    results
    |> Enum.map(&normalize_matrix_sample/1)
    |> collect_samples()
  end

  defp normalize_samples(type, [timestamp, value]) when type in [:scalar, :string] do
    {:ok, [%{metric: %{}, value: {timestamp, value}, values: nil}]}
  end

  defp normalize_samples(_type, _result), do: :error

  @spec normalize_vector_sample(term()) :: {:ok, Behaviour.sample()} | :error
  defp normalize_vector_sample(%{"metric" => metric, "value" => [timestamp, value]})
       when is_map(metric) do
    {:ok, %{metric: metric, value: {timestamp, value}, values: nil}}
  end

  defp normalize_vector_sample(_sample), do: :error

  @spec normalize_matrix_sample(term()) :: {:ok, Behaviour.sample()} | :error
  defp normalize_matrix_sample(%{"metric" => metric, "values" => values})
       when is_map(metric) and is_list(values) do
    with {:ok, normalized_values} <- normalize_values(values) do
      {:ok, %{metric: metric, value: nil, values: normalized_values}}
    end
  end

  defp normalize_matrix_sample(_sample), do: :error

  @spec normalize_values([term()]) :: {:ok, [{number(), String.t()}]} | :error
  defp normalize_values(values) do
    values
    |> Enum.map(&normalize_value/1)
    |> collect_values()
  end

  @spec normalize_value(term()) :: {:ok, {number(), String.t()}} | :error
  defp normalize_value([timestamp, value]), do: {:ok, {timestamp, value}}
  defp normalize_value(_value), do: :error

  @spec collect_samples([{:ok, Behaviour.sample()} | :error]) ::
          {:ok, [Behaviour.sample()]} | :error
  defp collect_samples(samples), do: collect(samples, [])

  @spec collect_values([{:ok, {number(), String.t()}} | :error]) ::
          {:ok, [{number(), String.t()}]} | :error
  defp collect_values(values), do: collect(values, [])

  @spec collect([{:ok, term()} | :error], [term()]) :: {:ok, [term()]} | :error
  defp collect([], acc), do: {:ok, Enum.reverse(acc)}
  defp collect([{:ok, value} | rest], acc), do: collect(rest, [value | acc])
  defp collect([:error | _rest], _acc), do: :error

  @spec prometheus_error(atom(), pos_integer(), term(), String.t(), integer()) ::
          Behaviour.error_result()
  defp prometheus_error(reason, status, body, promql, start_ms) when is_map(body) do
    %{
      reason: reason,
      promql: promql,
      http_status: status,
      error_type: Map.get(body, "errorType"),
      error: Map.get(body, "error") || inspect(body),
      duration_ms: duration_since(start_ms)
    }
  end

  defp prometheus_error(reason, status, body, promql, start_ms) do
    %{
      reason: reason,
      promql: promql,
      http_status: status,
      error_type: nil,
      error: inspect(body),
      duration_ms: duration_since(start_ms)
    }
  end

  @spec invalid_args() :: Behaviour.error_result()
  defp invalid_args do
    %{
      reason: :invalid_args,
      promql: nil,
      http_status: nil,
      error_type: nil,
      error: nil,
      duration_ms: 0
    }
  end

  @spec network_error(String.t(), term(), integer()) :: Behaviour.error_result()
  defp network_error(promql, reason, start_ms) do
    %{
      reason: :network_error,
      promql: promql,
      http_status: nil,
      error_type: nil,
      error: inspect(reason),
      duration_ms: duration_since(start_ms)
    }
  end

  @spec decode_error(pos_integer() | nil, term(), String.t(), integer()) ::
          Behaviour.error_result()
  defp decode_error(status, body, promql, start_ms) do
    %{
      reason: :decode_error,
      promql: promql,
      http_status: status,
      error_type: nil,
      error: inspect(body),
      duration_ms: duration_since(start_ms)
    }
  end

  @spec duration_since(integer()) :: non_neg_integer()
  defp duration_since(start_ms), do: max(System.monotonic_time(:millisecond) - start_ms, 0)
end
