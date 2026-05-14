defmodule Pageless.Tools.KubectlTest do
  @moduledoc "Tests the kubectl subprocess wrapper without a live cluster."

  use Pageless.DataCase, async: true

  import Hammox

  alias Pageless.AuditTrail
  alias Pageless.AuditTrail.Decision
  alias Pageless.Config.Rules
  alias Pageless.Governance.CapabilityGate
  alias Pageless.Governance.ToolCall
  alias Pageless.Repo
  alias Pageless.Tools.Kubectl

  setup :verify_on_exit!

  setup do
    pubsub = unique_atom("kubectl_pubsub")
    start_supervised!({Phoenix.PubSub, name: pubsub})

    %{pubsub: pubsub, rules: default_rules(), shim: shim_path()}
  end

  describe "function_call_definition/0" do
    test "exposes a Gemini function-call declaration for profile-scoped catalogs" do
      declaration = Kubectl.function_call_definition()

      assert declaration["name"] == "kubectl"
      assert declaration["parameters"]["type"] == "object"
      assert declaration["parameters"]["required"] == ["args"]
      assert declaration["parameters"]["properties"]["args"]["type"] == "array"
      assert declaration["parameters"]["properties"]["args"]["items"] == %{"type" => "string"}
    end
  end

  describe "exec/2" do
    test "runs read-class kubectl args and captures stdout", %{shim: shim} do
      call = tool_call(["--print-stdout", "NAME READY STATUS\npayments-api-abc 1/1 Running"])

      assert {:ok, result} = Kubectl.exec(call, binary: shim)
      assert result.output == "NAME READY STATUS\npayments-api-abc 1/1 Running\n"
      assert result.exit_status == 0
      assert result.command == call.args
      assert result.duration_ms >= 0
    end

    test "runs rollout undo args and returns the rollback output", %{shim: shim} do
      call =
        tool_call([
          "rollout",
          "undo",
          "deployment/payments-api",
          "-n",
          "prod",
          "--print-stdout",
          "deployment.apps/payments-api rolled back"
        ])

      assert {:ok, result} = Kubectl.exec(call, binary: shim)
      assert result.output == "deployment.apps/payments-api rolled back\n"
      assert result.exit_status == 0
      assert result.command == call.args
      assert result.duration_ms >= 0
    end

    test "merges stderr into output and returns nonzero_exit", %{shim: shim} do
      args = [
        "get",
        "pods",
        "--print-stderr",
        "Error from server: connection refused",
        "--exit-with",
        "1"
      ]

      call = tool_call(args)

      assert {:error, result} = Kubectl.exec(call, binary: shim)
      assert result.reason == :nonzero_exit
      assert result.exit_status == 1
      assert result.output == "Error from server: connection refused\n"
      assert result.command == args
      assert result.duration_ms >= 0
    end

    test "injects KUBECONFIG only when kubeconfig is provided", %{shim: shim} do
      kubeconfig = unique_path("kubeconfig")
      call = tool_call(["--echo-env", "KUBECONFIG"])

      assert {:ok, with_kubeconfig} = Kubectl.exec(call, binary: shim, kubeconfig: kubeconfig)
      assert with_kubeconfig.output == kubeconfig <> "\n"

      assert {:ok, without_kubeconfig} = Kubectl.exec(call, binary: shim)
      assert without_kubeconfig.output == ""
    end

    test "returns kubectl_not_found for missing binary" do
      args = ["get", "pods"]
      call = tool_call(args)

      assert {:error, result} = Kubectl.exec(call, binary: unique_path("missing-kubectl"))
      assert result.reason == :kubectl_not_found
      assert result.output == nil
      assert result.exit_status == nil
      assert result.command == args
      assert result.duration_ms == 0
    end

    test "rejects invalid args without invoking the subprocess", %{shim: shim} do
      for args <- [[], "not a list", [123], ["valid", :not_a_binary]] do
        assert {:error, result} = Kubectl.exec(tool_call(args), binary: shim)
        assert result.reason == :invalid_args
        assert result.output == nil
        assert result.exit_status == nil
        assert result.command == args
        assert result.duration_ms == 0
      end
    end

    test "raises FunctionClauseError for non-kubectl tool calls", %{shim: shim} do
      assert_raise FunctionClauseError, fn ->
        Kubectl.exec(tool_call(:prometheus_query, "up"), binary: shim)
      end
    end
  end

  describe "CapabilityGate integration" do
    @tag :acceptance
    test "read kubectl request executes through the real wrapper and updates audit", %{
      pubsub: pubsub,
      rules: rules,
      shim: shim
    } do
      args = ["get", "pods", "--print-stdout", "NAME READY STATUS\npayments-api-abc 1/1 Running"]
      call = tool_call(args)
      Phoenix.PubSub.subscribe(pubsub, topic(call))

      dispatch = fn dispatched_call -> Kubectl.exec(dispatched_call, binary: shim) end

      assert {:ok, result} = CapabilityGate.request(call, rules, opts(pubsub, dispatch))
      assert result.output == "NAME READY STATUS\npayments-api-abc 1/1 Running\n"
      assert result.exit_status == 0

      assert %Decision{decision: "executed", classification: "read", result_status: "ok"} =
               Repo.get_by(Decision, request_id: call.request_id)

      assert_receive {:gate_decision, :executed, _gate_id, ^call, ^result}
      refute_received {:gate_fired, _, _, _, _, _}
    end

    @tag :acceptance
    test "rollout undo is gated and executes the real wrapper only after approval", %{
      pubsub: pubsub,
      rules: rules,
      shim: shim
    } do
      args = [
        "rollout",
        "undo",
        "deployment/payments-api",
        "--print-stdout",
        "deployment.apps/payments-api rolled back"
      ]

      call = tool_call(args)
      Phoenix.PubSub.subscribe(pubsub, topic(call))
      parent = self()

      dispatch = fn dispatched_call ->
        send(parent, {:dispatch, dispatched_call})
        Kubectl.exec(dispatched_call, binary: shim)
      end

      assert {:gated, gate_id} = CapabilityGate.request(call, rules, opts(pubsub, dispatch))
      assert_receive {:gate_fired, ^gate_id, ^call, :write_prod_high, "rollout undo", _context}
      refute_received {:dispatch, _call}

      assert {:ok, result} =
               CapabilityGate.approve(gate_id, "operator@host", opts(pubsub, dispatch))

      assert result.output == "deployment.apps/payments-api rolled back\n"
      assert result.exit_status == 0

      assert_receive {:dispatch, ^call}

      assert %Decision{decision: "executed", result_status: "ok"} =
               AuditTrail.get_by_gate_id(gate_id)
    end
  end

  describe "Hammox mock" do
    test "mock obeys the kubectl behaviour contract" do
      call = tool_call(["get", "pods"])
      expected = {:ok, %{output: "fake", exit_status: 0, command: [], duration_ms: 0}}

      Pageless.Tools.Kubectl.Mock
      |> expect(:exec, fn ^call -> expected end)

      assert Pageless.Tools.Kubectl.Mock.exec(call) == expected
    end
  end

  defp opts(pubsub, dispatch) do
    [tool_dispatch: dispatch, pubsub: pubsub, repo: AuditTrail]
  end

  defp default_rules do
    Rules.load!(Path.expand("../../fixtures/pageless_rules/default.yaml", __DIR__))
  end

  defp shim_path do
    Path.expand("../../support/bin/fake_kubectl.sh", __DIR__)
  end

  defp tool_call(args), do: tool_call(:kubectl, args)

  defp tool_call(tool, args) do
    struct(ToolCall, %{
      tool: tool,
      args: args,
      agent_id: Ecto.UUID.generate(),
      agent_pid_inspect: inspect(self()),
      alert_id: unique("alert"),
      request_id: unique("req"),
      reasoning_context: %{summary: "kubectl check", evidence_link: "runbook://payments"}
    })
  end

  defp topic(%ToolCall{alert_id: alert_id}), do: "alert:#{alert_id}"

  defp unique(prefix), do: "#{prefix}_#{System.unique_integer([:positive])}"

  defp unique_atom(prefix), do: :erlang.binary_to_atom(unique(prefix), :utf8)

  defp unique_path(prefix) do
    Path.join(System.tmp_dir!(), unique(prefix))
  end
end
