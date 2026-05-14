defmodule Pageless.Tools.PrometheusQueryTest.CapturingReq do
  @moduledoc "Req-shaped test double that sends the outbound request back to the test process."

  @doc "Posts a captured request back to the caller and returns the configured response."
  @spec post(String.t(), keyword()) :: {:ok, Req.Response.t()} | no_return()
  def post(url, opts) do
    caller = Keyword.fetch!(opts, :caller)
    send(caller, {:req_post, url, opts})

    case Keyword.fetch!(opts, :response) do
      {:raise, exception} -> raise exception
      response -> response
    end
  end
end

defmodule Pageless.Tools.PrometheusQueryTest.UncalledReq do
  @moduledoc "Req-shaped test double that fails if invalid args attempt HTTP traffic."

  @doc "Raises because invalid argument paths must not attempt HTTP traffic."
  @spec post(String.t(), keyword()) :: no_return()
  def post(_url, _opts), do: raise("PrometheusQuery attempted HTTP for invalid args")
end

defmodule Pageless.Tools.PrometheusQueryTest do
  @moduledoc "Tests the Prometheus HTTP API wrapper and gate read-path integration."

  use Pageless.DataCase, async: true

  import Hammox
  import ReqCassette

  alias Pageless.AuditTrail
  alias Pageless.AuditTrail.Decision
  alias Pageless.Config.Rules
  alias Pageless.Governance.CapabilityGate
  alias Pageless.Governance.ToolCall
  alias Pageless.Repo
  alias Pageless.Tools.PrometheusQuery
  alias Pageless.Tools.PrometheusQuery.Behaviour
  alias Pageless.Tools.PrometheusQueryTest.{CapturingReq, UncalledReq}

  setup :verify_on_exit!

  setup do
    pubsub = unique_atom("prometheus_pubsub")
    start_supervised!({Phoenix.PubSub, name: pubsub})

    %{pubsub: pubsub, rules: default_rules()}
  end

  describe "behaviour" do
    test "exposes exec/1 and exec/2 callbacks" do
      callbacks = Behaviour.behaviour_info(:callbacks)

      assert Enum.sort(callbacks) == [exec: 1, exec: 2]
    end
  end

  describe "exec/2" do
    test "posts an instant vector query and normalizes samples" do
      promql = "rate(http_errors[5m])"

      response =
        success_response("vector", [
          %{"metric" => %{"service" => "payments-api"}, "value" => [1_715_647_641.123, "0.05"]}
        ])

      assert {:ok, result} =
               PrometheusQuery.exec(tool_call(promql),
                 req_module: CapturingReq,
                 base_url: "http://prometheus.test",
                 timeout_ms: 1_234,
                 caller: self(),
                 response: response
               )

      assert result.result_type == :vector

      assert result.samples == [
               %{
                 metric: %{"service" => "payments-api"},
                 value: {1_715_647_641.123, "0.05"},
                 values: nil
               }
             ]

      assert result.promql == promql
      assert result.raw["status"] == "success"
      assert result.duration_ms >= 0

      assert_receive {:req_post, "http://prometheus.test/api/v1/query", opts}
      assert Keyword.fetch!(opts, :form) == [query: promql]
      assert Keyword.fetch!(opts, :receive_timeout) == 1_234
      assert Keyword.fetch!(opts, :retry) == false
    end

    test "normalizes matrix samples" do
      response =
        success_response("matrix", [
          %{
            "metric" => %{"service" => "payments-api"},
            "values" => [[1_715_647_641.0, "1"], [1_715_647_701.0, "2"]]
          }
        ])

      assert {:ok, result} = exec_with_response("up{service=\"payments-api\"}[5m]", response)
      assert result.result_type == :matrix

      assert result.samples == [
               %{
                 metric: %{"service" => "payments-api"},
                 value: nil,
                 values: [{1_715_647_641.0, "1"}, {1_715_647_701.0, "2"}]
               }
             ]
    end

    test "wraps scalar results in the uniform samples shape" do
      response = success_response("scalar", [1_715_647_641.0, "42"])

      assert {:ok, result} = exec_with_response("count(up)", response)
      assert result.result_type == :scalar
      assert result.samples == [%{metric: %{}, value: {1_715_647_641.0, "42"}, values: nil}]
    end

    test "returns promql_error for a 200 response with an error envelope" do
      promql = "rate("
      response = {:ok, %Req.Response{status: 200, body: promql_error_body()}}

      assert {:error, error} = exec_with_response(promql, response)
      assert error.reason == :promql_error
      assert error.promql == promql
      assert error.http_status == 200
      assert error.error_type == "bad_data"
      assert error.error == "parse error: unexpected EOF"
      assert error.duration_ms >= 0
    end

    test "returns http_error for non-2xx Prometheus responses" do
      response =
        {:ok,
         %Req.Response{
           status: 503,
           body: %{"status" => "error", "error" => "service unavailable"}
         }}

      assert {:error, error} = exec_with_response("up", response)
      assert error.reason == :http_error
      assert error.http_status == 503
      assert error.error == "service unavailable"
      assert error.duration_ms >= 0
    end

    test "returns typed http_error for malformed-request 4xx responses" do
      response =
        {:ok,
         %Req.Response{
           status: 400,
           body: %{
             "status" => "error",
             "errorType" => "bad_data",
             "error" => "invalid parameter 'query'"
           }
         }}

      assert {:error, error} = exec_with_response("up", response)
      assert error.reason == :http_error
      assert error.http_status == 400
      assert error.error_type == "bad_data"
      assert error.error == "invalid parameter 'query'"
    end

    test "returns network_error for Req transport failures without raising" do
      exception = Req.TransportError.exception(reason: :timeout)

      assert {:error, error} =
               PrometheusQuery.exec(tool_call("up"),
                 req_module: CapturingReq,
                 caller: self(),
                 response: {:raise, exception}
               )

      assert error.reason == :network_error
      assert error.promql == "up"
      assert error.http_status == nil
      assert error.error =~ "timeout"
      assert error.duration_ms >= 0
    end

    test "returns decode_error for unexpected response bodies" do
      response = {:ok, %Req.Response{status: 200, body: "not-a-map"}}

      assert {:error, error} = exec_with_response("up", response)
      assert error.reason == :decode_error
      assert error.promql == "up"
      assert error.http_status == 200
      assert error.duration_ms >= 0
    end

    test "rejects invalid args without invoking the request module" do
      for args <- [nil, "", 42, ["up"], %{}] do
        assert {:error, error} = PrometheusQuery.exec(tool_call(args), req_module: UncalledReq)
        assert error.reason == :invalid_args
        assert error.promql == nil
        assert error.http_status == nil
        assert error.duration_ms == 0
      end
    end

    test "attaches authorization header only when auth_token is set" do
      response = success_response("vector", [])

      assert {:ok, _result} =
               PrometheusQuery.exec(tool_call("up"),
                 req_module: CapturingReq,
                 auth_token: "secret-token",
                 caller: self(),
                 response: response
               )

      assert_receive {:req_post, _url, with_token_opts}
      assert header_value(with_token_opts, "authorization") == "Bearer secret-token"

      assert {:ok, _result} =
               PrometheusQuery.exec(tool_call("up"),
                 req_module: CapturingReq,
                 auth_token: nil,
                 caller: self(),
                 response: response
               )

      assert_receive {:req_post, _url, without_token_opts}
      refute header_value(without_token_opts, "authorization")
    end

    test "honors custom base_url" do
      assert {:ok, _result} =
               PrometheusQuery.exec(tool_call("up"),
                 req_module: CapturingReq,
                 base_url: "http://localhost:9999",
                 caller: self(),
                 response: success_response("vector", [])
               )

      assert_receive {:req_post, "http://localhost:9999/api/v1/query", _opts}
    end

    test "raises FunctionClauseError for non-prometheus tool calls" do
      assert_raise FunctionClauseError, fn ->
        PrometheusQuery.exec(tool_call(:kubectl, ["get", "pods"]), req_module: UncalledReq)
      end
    end
  end

  describe "CapabilityGate integration" do
    @tag :acceptance
    test "prometheus read request executes through the wrapper and updates audit", %{
      pubsub: pubsub,
      rules: rules
    } do
      promql = "up{service=\"payments-api\"}"
      call = tool_call(promql)
      Phoenix.PubSub.subscribe(pubsub, topic(call))

      dispatch = fn dispatched_call ->
        PrometheusQuery.exec(dispatched_call,
          req_module: CapturingReq,
          base_url: "http://stub:9090",
          caller: self(),
          response:
            success_response("vector", [
              %{"metric" => %{"service" => "payments-api"}, "value" => [1_715_647_641.123, "1"]}
            ])
        )
      end

      assert {:ok, result} = CapabilityGate.request(call, rules, opts(pubsub, dispatch))
      assert result.result_type == :vector
      assert [%{metric: %{"service" => "payments-api"}}] = result.samples

      assert %Decision{
               decision: "executed",
               classification: "read",
               extracted_verb: nil,
               args: %{"promql" => ^promql},
               result_status: "ok"
             } = Repo.get_by(Decision, request_id: call.request_id)

      assert_receive {:gate_decision, :execute, ^call, :read, nil}
      assert_receive {:gate_decision, :executed, _gate_id, ^call, ^result}
    end

    @tag :acceptance
    test "prometheus 200 error envelope returns error through gate and audit", %{
      pubsub: pubsub,
      rules: rules
    } do
      call = tool_call("rate(")
      Phoenix.PubSub.subscribe(pubsub, topic(call))

      dispatch = fn dispatched_call ->
        PrometheusQuery.exec(dispatched_call,
          req_module: CapturingReq,
          caller: self(),
          response: {:ok, %Req.Response{status: 200, body: promql_error_body()}}
        )
      end

      assert {:error, error} = CapabilityGate.request(call, rules, opts(pubsub, dispatch))
      assert error.reason == :promql_error

      assert %Decision{decision: "execution_failed", result_status: "error"} =
               decision = Repo.get_by(Decision, request_id: call.request_id)

      assert decision.classification == "read"
      assert decision.result_summary =~ ":promql_error"
      assert_receive {:gate_decision, :execution_failed, _gate_id, ^call, ^error}
    end
  end

  describe "Hammox mock" do
    test "mock obeys the prometheus query behaviour contract" do
      call = tool_call("up")

      expected =
        {:ok, %{result_type: :vector, samples: [], raw: %{}, duration_ms: 0, promql: "up"}}

      Pageless.Tools.PrometheusQuery.Mock
      |> expect(:exec, fn ^call -> expected end)

      assert Pageless.Tools.PrometheusQuery.Mock.exec(call) == expected
    end
  end

  describe "ReqCassette" do
    test "replays a recorded instant vector response through the real Req stack" do
      with_cassette(
        "prometheus_query_instant_vector",
        [
          cassette_dir: "test/fixtures/cassettes",
          mode: :replay,
          match_requests_on: [:method, :uri, :body]
        ],
        fn plug ->
          assert {:ok, result} =
                   PrometheusQuery.exec(tool_call("up{service=\"payments-api\"}"),
                     base_url: "http://prometheus.test",
                     plug: plug
                   )

          assert result.result_type == :vector

          assert result.samples == [
                   %{
                     metric: %{"service" => "payments-api"},
                     value: {1_715_647_641.123, "1"},
                     values: nil
                   }
                 ]
        end
      )
    end
  end

  defp exec_with_response(promql, response) do
    PrometheusQuery.exec(tool_call(promql),
      req_module: CapturingReq,
      caller: self(),
      response: response
    )
  end

  defp opts(pubsub, dispatch) do
    [tool_dispatch: dispatch, pubsub: pubsub, repo: AuditTrail]
  end

  defp success_response(result_type, result) do
    {:ok,
     %Req.Response{
       status: 200,
       body: %{
         "status" => "success",
         "data" => %{"resultType" => result_type, "result" => result}
       }
     }}
  end

  defp promql_error_body do
    %{
      "status" => "error",
      "errorType" => "bad_data",
      "error" => "parse error: unexpected EOF"
    }
  end

  defp header_value(opts, name) do
    opts
    |> Keyword.fetch!(:headers)
    |> Enum.find_value(fn
      {^name, value} ->
        value

      {header, value} when is_binary(header) ->
        if String.downcase(header) == name, do: value

      _other ->
        nil
    end)
  end

  defp default_rules do
    Rules.load!(Path.expand("../../fixtures/pageless_rules/default.yaml", __DIR__))
  end

  defp tool_call(args), do: tool_call(:prometheus_query, args)

  defp tool_call(tool, args) do
    struct(ToolCall, %{
      tool: tool,
      args: args,
      agent_id: Ecto.UUID.generate(),
      agent_pid_inspect: inspect(self()),
      alert_id: unique("alert"),
      request_id: unique("req"),
      reasoning_context: %{summary: "metrics check", evidence_link: "runbook://payments"}
    })
  end

  defp topic(%ToolCall{alert_id: alert_id}), do: "alert:#{alert_id}"

  defp unique(prefix), do: "#{prefix}_#{System.unique_integer([:positive])}"

  defp unique_atom(prefix), do: :erlang.binary_to_atom(unique(prefix), :utf8)
end
