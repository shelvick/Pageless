defmodule PagelessWeb.FireTestAlertController do
  @moduledoc """
  Demo-only endpoint that deploys the known-bad payments-api manifest.
  """

  use Phoenix.Controller, formats: [:json]

  alias Pageless.Governance.ToolCall

  @manifest_relative "priv/k8s/11-payments-api-v241.yaml"
  @output_excerpt_bytes 400

  @doc "Applies the payments-api v2.4.1 manifest to trigger the demo alert path."
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, _params) do
    deploy_id = deploy_id()
    manifest_path = Application.app_dir(:pageless, @manifest_relative)
    kubectl = Application.get_env(:pageless, :kubectl_impl, Pageless.Tools.Kubectl)

    manifest_path
    |> tool_call(deploy_id)
    |> kubectl.exec()
    |> respond(conn, deploy_id)
  end

  defp tool_call(manifest_path, deploy_id) do
    %ToolCall{
      tool: :kubectl,
      args: ["apply", "-f", manifest_path],
      agent_id: "demo-fire-test-alert",
      alert_id: deploy_id,
      request_id: deploy_id
    }
  end

  defp respond({:ok, %{exit_status: 0, output: output}}, conn, deploy_id) do
    conn
    |> put_status(:accepted)
    |> json(%{
      deploy_id: deploy_id,
      kubectl_exit_status: 0,
      output_excerpt: truncate_output(output)
    })
  end

  defp respond({:error, %{reason: :kubectl_not_found}}, conn, deploy_id) do
    conn
    |> put_status(:service_unavailable)
    |> json(%{error: "kubectl_not_found", deploy_id: deploy_id})
  end

  defp respond(
         {:error, %{reason: reason, output: output, exit_status: exit_status}},
         conn,
         deploy_id
       ) do
    conn
    |> put_status(:internal_server_error)
    |> json(%{
      error: to_string(reason),
      deploy_id: deploy_id,
      kubectl_exit_status: exit_status,
      output_excerpt: truncate_output(output || "")
    })
  end

  defp deploy_id do
    suffix =
      6
      |> :crypto.strong_rand_bytes()
      |> Base.url_encode64(padding: false)

    "demo-fire-" <> suffix
  end

  defp truncate_output(output) when byte_size(output) > @output_excerpt_bytes do
    binary_part(output, 0, @output_excerpt_bytes) <> "…"
  end

  defp truncate_output(output), do: output
end
