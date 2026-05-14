defmodule PagelessWeb.FireTestAlertControllerTest do
  @moduledoc "Controller tests for the demo fire-test-alert endpoint."

  use PagelessWeb.ConnCase, async: true

  import Hammox

  alias Pageless.Governance.ToolCall

  setup :verify_on_exit!

  @tag :acceptance
  test "POST /demo/fire-test-alert applies the known-bad manifest", %{conn: conn} do
    expect_kubectl(fn %ToolCall{tool: :kubectl, args: ["apply", "-f", manifest_path]} ->
      assert String.ends_with?(manifest_path, "priv/k8s/11-payments-api-v241.yaml")

      {:ok,
       %{
         output: "deployment.apps/payments-api-v2-4-1 configured",
         exit_status: 0,
         command: ["apply", "-f", manifest_path],
         duration_ms: 12
       }}
    end)

    conn = post_json(conn, "/demo/fire-test-alert", %{})

    assert conn.status == 202

    body = Jason.decode!(conn.resp_body)
    assert %{"deploy_id" => deploy_id, "kubectl_exit_status" => 0} = body
    assert is_binary(deploy_id) and deploy_id != ""
    assert body["output_excerpt"] =~ "configured"
    refute Map.has_key?(body, "error")
  end

  test "POST /demo/fire-test-alert ignores unrelated request params", %{conn: conn} do
    expect_kubectl(fn %ToolCall{args: ["apply", "-f", manifest_path]} ->
      {:ok,
       %{
         output: "deployment.apps/payments-api-v2-4-1 unchanged",
         exit_status: 0,
         command: ["apply", "-f", manifest_path],
         duration_ms: 4
       }}
    end)

    conn = post_json(conn, "/demo/fire-test-alert", %{unexpected: "ignored"})

    assert conn.status == 202
    body = Jason.decode!(conn.resp_body)
    assert is_binary(body["deploy_id"])
    assert body["kubectl_exit_status"] == 0
    assert body["output_excerpt"] =~ "unchanged"
  end

  test "POST /demo/fire-test-alert reports missing kubectl as service unavailable", %{conn: conn} do
    expect_kubectl(fn %ToolCall{args: ["apply", "-f", manifest_path]} ->
      {:error,
       %{
         reason: :kubectl_not_found,
         output: nil,
         exit_status: nil,
         command: ["apply", "-f", manifest_path],
         duration_ms: 0
       }}
    end)

    conn = post_json(conn, "/demo/fire-test-alert", %{})

    assert conn.status == 503
    body = Jason.decode!(conn.resp_body)
    assert body["error"] == "kubectl_not_found"
    assert is_binary(body["deploy_id"]) and body["deploy_id"] != ""
    refute Map.has_key?(body, "kubectl_exit_status")
  end

  test "POST /demo/fire-test-alert reports nonzero kubectl exits", %{conn: conn} do
    output = "the Deployment \"payments-api-v2-4-1\" is invalid: forbidden"

    expect_kubectl(fn %ToolCall{args: ["apply", "-f", manifest_path]} ->
      {:error,
       %{
         reason: :nonzero_exit,
         output: output,
         exit_status: 1,
         command: ["apply", "-f", manifest_path],
         duration_ms: 7
       }}
    end)

    conn = post_json(conn, "/demo/fire-test-alert", %{})

    assert conn.status == 500
    body = Jason.decode!(conn.resp_body)
    assert body["error"] == "nonzero_exit"
    assert body["kubectl_exit_status"] == 1
    assert body["output_excerpt"] == output
    assert is_binary(body["deploy_id"])
  end

  test "POST /demo/fire-test-alert truncates long kubectl output to 400 bytes", %{conn: conn} do
    long_output = String.duplicate("x", 450)

    expect_kubectl(fn %ToolCall{args: ["apply", "-f", manifest_path]} ->
      {:error,
       %{
         reason: :nonzero_exit,
         output: long_output,
         exit_status: 1,
         command: ["apply", "-f", manifest_path],
         duration_ms: 7
       }}
    end)

    conn = post_json(conn, "/demo/fire-test-alert", %{})

    assert conn.status == 500
    body = Jason.decode!(conn.resp_body)
    assert body["output_excerpt"] == String.duplicate("x", 400) <> "…"
  end

  defp expect_kubectl(fun) do
    Pageless.Tools.Kubectl.Mock
    |> expect(:exec, fn call -> fun.(call) end)
  end

  defp post_json(conn, path, params) do
    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json")
    |> post(path, Jason.encode!(params))
  end
end
