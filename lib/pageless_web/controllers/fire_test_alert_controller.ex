defmodule PagelessWeb.FireTestAlertController do
  @moduledoc """
  Demo-only endpoint that proposes a gated deploy of the known-bad payments-api manifest.
  """

  use Phoenix.Controller, formats: [:json]

  alias Pageless.AlertEnvelope
  alias Pageless.Config.Rules
  alias Pageless.Governance.{CapabilityGate, ToolCall}

  @manifest_relative "priv/k8s/11-payments-api-v241.yaml"

  @doc "Stages the payments-api v2.4.1 manifest behind operator approval."
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, _params) do
    deploy_id = deploy_id()
    manifest_path = Application.app_dir(:pageless, @manifest_relative)
    kubectl = Application.get_env(:pageless, :kubectl_impl, Pageless.Tools.Kubectl)
    broker = conn.assigns[:pubsub_broker] || Pageless.PubSub
    rules = conn.assigns[:rules] || lookup_rules!()
    audit_repo = conn.assigns[:audit_repo] || Pageless.AuditTrail

    envelope = alert_envelope(deploy_id, manifest_path)
    :ok = Phoenix.PubSub.broadcast(broker, "alerts", {:alert_received, envelope})

    call = tool_call(manifest_path, deploy_id)

    result =
      CapabilityGate.request(call, rules,
        tool_dispatch: fn call -> kubectl.exec(call) end,
        pubsub: broker,
        repo: audit_repo
      )

    respond(result, conn, deploy_id, call, broker)
  end

  defp tool_call(manifest_path, deploy_id) do
    %ToolCall{
      tool: :kubectl,
      args: ["apply", "-f", manifest_path],
      agent_id: Ecto.UUID.generate(),
      alert_id: deploy_id,
      request_id: deploy_id,
      reasoning_context: %{summary: "Operator-initiated deploy of v2.4.1 via demo button"}
    }
  end

  defp alert_envelope(deploy_id, manifest_path) do
    now = DateTime.utc_now()

    {:ok, envelope} =
      AlertEnvelope.new(%{
        alert_id: deploy_id,
        source: :demo,
        source_ref: deploy_id,
        fingerprint: "demo-fire-test-alert:" <> deploy_id,
        received_at: now,
        started_at: now,
        status: :firing,
        severity: :info,
        alert_class: :operator_demo_trigger,
        title: "Operator-initiated deploy: payments-api v2.4.1",
        service: "payments-api",
        labels: %{"service" => "payments-api", "version" => "v2-4-1", "trigger" => "demo"},
        annotations: %{},
        payload_raw: %{"manifest" => manifest_path, "deploy_id" => deploy_id}
      })

    envelope
  end

  defp respond({:gated, gate_id}, conn, deploy_id, call, broker) do
    :ok =
      Phoenix.PubSub.broadcast(broker, "alerts", {
        :gate_fired,
        gate_id,
        call,
        :write_prod_high,
        "apply",
        call.reasoning_context
      })

    conn
    |> put_status(:accepted)
    |> json(%{deploy_id: deploy_id, gate_id: gate_id, status: "gated"})
  end

  defp respond({:error, :policy_denied}, conn, deploy_id, _call, _broker) do
    conn
    |> put_status(:forbidden)
    |> json(%{error: "policy_denied", deploy_id: deploy_id})
  end

  defp respond({:error, reason}, conn, deploy_id, _call, _broker) do
    conn
    |> put_status(:internal_server_error)
    |> json(%{error: to_string(reason), deploy_id: deploy_id})
  end

  defp respond({:ok, _result}, conn, deploy_id, _call, _broker) do
    conn
    |> put_status(:accepted)
    |> json(%{deploy_id: deploy_id, status: "executed"})
  end

  defp deploy_id do
    suffix =
      6
      |> :crypto.strong_rand_bytes()
      |> Base.url_encode64(padding: false)

    "demo-fire-" <> suffix
  end

  defp lookup_rules! do
    Pageless.Supervisor
    |> Supervisor.which_children()
    |> Enum.find_value(fn
      {Rules.Agent, pid, :worker, [Rules.Agent]} when is_pid(pid) -> Rules.Agent.get(pid)
      _child -> nil
    end) || raise "Pageless rules Agent is not running"
  end
end
