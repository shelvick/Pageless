defmodule Pageless.Proc.EscalatorTest.SuccessResolveClient do
  @moduledoc "Resolve client test double that reports a sent PagerDuty page."

  @doc "Returns a successful PagerDuty-style escalation result."
  @spec escalate(Pageless.AlertEnvelope.t(), map(), keyword()) ::
          {:ok, %{status: 202, dedup_key: String.t()}}
  def escalate(envelope, _page_payload, _opts),
    do: {:ok, %{status: 202, dedup_key: envelope.alert_id}}
end

defmodule Pageless.Proc.EscalatorTest.NoopResolveClient do
  @moduledoc "Resolve client test double that reports a logical no-op."

  @doc "Returns a successful no-op escalation result."
  @spec escalate(Pageless.AlertEnvelope.t(), map(), keyword()) :: {:ok, :noop}
  def escalate(_envelope, _page_payload, _opts), do: {:ok, :noop}
end

defmodule Pageless.Proc.EscalatorTest.FailureResolveClient do
  @moduledoc "Resolve client test double that reports rate limiting."

  @doc "Returns a deterministic rate-limit error."
  @spec escalate(Pageless.AlertEnvelope.t(), map(), keyword()) :: {:error, :rate_limited}
  def escalate(_envelope, _page_payload, _opts), do: {:error, :rate_limited}
end

defmodule Pageless.Proc.EscalatorTest.ForbiddenResolveClient do
  @moduledoc "Resolve client test double that fails if escalation is attempted."

  @doc "Raises because Gemini failures must stop before calling ResolveClient."
  @spec escalate(Pageless.AlertEnvelope.t(), map(), keyword()) :: no_return()
  def escalate(_envelope, _page_payload, _opts), do: raise("ResolveClient must not be called")
end

defmodule Pageless.Proc.EscalatorTest.AssertingResolveClient do
  @moduledoc "Resolve client test double that validates fallback page payloads."

  @doc "Returns success only when the fallback payload matches the envelope."
  @spec escalate(Pageless.AlertEnvelope.t(), map(), keyword()) ::
          {:ok, %{status: 202, dedup_key: String.t()}}
  def escalate(envelope, page_payload, _opts) do
    true = page_payload.summary == envelope.title
    true = page_payload.severity == envelope.severity
    true = page_payload.dedup_key == envelope.alert_id

    {:ok, %{status: 202, dedup_key: envelope.alert_id}}
  end
end

defmodule Pageless.Proc.EscalatorTest do
  @moduledoc "Tests the Escalator agent lifecycle and side effects."

  use Pageless.DataCase, async: true

  import Hammox

  alias Pageless.AlertEnvelope
  alias Pageless.Data.AgentState
  alias Pageless.Proc.Escalator
  alias Pageless.PubSubHelpers
  alias Pageless.Sup.Alert
  alias Pageless.SupHelpers
  alias Pageless.Svc.GeminiClient.FunctionCall
  alias Pageless.Svc.GeminiClient.Response

  setup :verify_on_exit!

  setup do
    broker = PubSubHelpers.start_isolated_pubsub()
    :ok = PubSubHelpers.subscribe(broker, "alert:alert-escalator")
    %{pubsub: broker}
  end

  describe "setup" do
    test "spawns with a state handshake, audit row, and PubSub event", %{
      pubsub: broker,
      sandbox_owner: sandbox_owner
    } do
      %{pid: pid, agent_id: agent_id} = start_escalator(broker, sandbox_owner)

      assert Process.alive?(pid)
      assert agent_id =~ ~r/^escalator-\d+$/
      assert_receive {:escalator_spawned, ^agent_id, "alert-escalator"}

      [spawned] = AgentState.history(Pageless.Repo, agent_id, event_type: :spawned)
      assert spawned.agent_type == :escalator
      assert spawned.payload["envelope_summary"]["alert_id"] == "alert-escalator"
      assert spawned.payload["envelope_summary"]["source"] == "pagerduty"
    end
  end

  describe "successful page out" do
    test "calls Gemini, escalates through ResolveClient, persists state, broadcasts, and exits",
         %{
           pubsub: broker,
           sandbox_owner: sandbox_owner
         } do
      expect(Pageless.Svc.GeminiClient.Mock, :generate, fn opts ->
        assert Keyword.fetch!(opts, :model) == :flash
        assert Keyword.fetch!(opts, :temperature) == 0.0
        assert Keyword.fetch!(opts, :tool_choice) == {:specific, "page_out"}

        {:ok,
         struct(Response,
           text: "Paging on-call",
           function_calls: [
             struct(FunctionCall,
               name: "page_out",
               args: %{"summary" => "Service down", "severity" => "critical"}
             )
           ]
         )}
      end)

      %{pid: pid, agent_id: agent_id} =
        start_escalator(
          broker,
          sandbox_owner,
          envelope(),
          resolve_client: Pageless.Proc.EscalatorTest.SuccessResolveClient
        )

      :ok = Escalator.kick_off(pid)
      monitor_ref = Process.monitor(pid)

      assert_receive {:escalator_reasoning, ^agent_id, "alert-escalator", "Paging on-call"}
      assert_receive {:page_out_sent, ^agent_id, "alert-escalator", page_payload}
      assert page_payload.summary == "Service down"
      assert_receive {:escalator_complete, "alert-escalator", ^agent_id, %{outcome: :sent}}
      assert_receive {:DOWN, ^monitor_ref, :process, ^pid, reason}
      assert clean_exit?(reason)

      rows = AgentState.history(Pageless.Repo, agent_id)

      assert Enum.map(rows, & &1.event_type) == [
               :spawned,
               :reasoning_line,
               :tool_call,
               :final_state
             ]

      assert Enum.at(rows, 2).payload["result"]["status"] == 202
      assert List.last(rows).payload["outcome"] == "sent"
    end
  end

  describe "no-op and failure paths" do
    test "treats ResolveClient noop as a successful page-out", %{
      pubsub: broker,
      sandbox_owner: sandbox_owner
    } do
      expect_page_out_from_gemini(%{"summary" => "Alertmanager page", "severity" => "warning"})

      %{pid: pid, agent_id: agent_id} =
        start_escalator(broker, sandbox_owner, envelope(source: :alertmanager),
          resolve_client: Pageless.Proc.EscalatorTest.NoopResolveClient
        )

      :ok = Escalator.kick_off(pid)
      monitor_ref = Process.monitor(pid)

      assert_receive {:page_out_sent, ^agent_id, "alert-escalator", _page_payload}, 1_000
      assert_receive {:escalator_complete, "alert-escalator", ^agent_id, %{outcome: :noop}}, 1_000
      assert_receive {:DOWN, ^monitor_ref, :process, ^pid, reason}, 1_000
      assert clean_exit?(reason)

      rows = AgentState.history(Pageless.Repo, agent_id)
      assert Enum.find(rows, &(&1.event_type == :tool_call)).payload["result"] == "noop"
      assert List.last(rows).payload["outcome"] == "noop"
    end

    test "records page-out failures and exits normally", %{
      pubsub: broker,
      sandbox_owner: sandbox_owner
    } do
      expect_page_out_from_gemini(%{"summary" => "Rate limited page", "severity" => "critical"})

      %{pid: pid, agent_id: agent_id} =
        start_escalator(
          broker,
          sandbox_owner,
          envelope(),
          resolve_client: Pageless.Proc.EscalatorTest.FailureResolveClient
        )

      :ok = Escalator.kick_off(pid)
      monitor_ref = Process.monitor(pid)

      assert_receive {:page_out_failed, ^agent_id, "alert-escalator", :rate_limited}

      assert_receive {:escalator_complete, "alert-escalator", ^agent_id,
                      %{outcome: :failed, reason: :rate_limited}}

      assert_receive {:DOWN, ^monitor_ref, :process, ^pid, reason}
      assert clean_exit?(reason)

      rows = AgentState.history(Pageless.Repo, agent_id)
      assert Enum.find(rows, &(&1.event_type == :tool_error)).payload["reason"] == "rate_limited"
      assert List.last(rows).payload["outcome"] == "failed"
      assert List.last(rows).payload["reason"] == "rate_limited"
    end

    test "does not call ResolveClient when Gemini fails", %{
      pubsub: broker,
      sandbox_owner: sandbox_owner
    } do
      expect(Pageless.Svc.GeminiClient.Mock, :generate, fn _opts -> {:error, :gemini_timeout} end)

      %{pid: pid, agent_id: agent_id} =
        start_escalator(
          broker,
          sandbox_owner,
          envelope(),
          resolve_client: Pageless.Proc.EscalatorTest.ForbiddenResolveClient
        )

      :ok = Escalator.kick_off(pid)
      monitor_ref = Process.monitor(pid)

      assert_receive {:page_out_failed, ^agent_id, "alert-escalator", :gemini_timeout}
      assert_receive {:DOWN, ^monitor_ref, :process, ^pid, reason}
      assert clean_exit?(reason)

      rows = AgentState.history(Pageless.Repo, agent_id)
      assert Enum.find(rows, &(&1.event_type == :tool_error)).payload["tool"] == "gemini.generate"
      assert List.last(rows).payload["outcome"] == "failed"
    end

    test "synthesizes a page payload when Gemini emits no function call", %{
      pubsub: broker,
      sandbox_owner: sandbox_owner
    } do
      expect(Pageless.Svc.GeminiClient.Mock, :generate, fn _opts ->
        {:ok, struct(Response, text: "Hmm, I don't know", function_calls: [])}
      end)

      %{pid: pid, agent_id: agent_id} =
        start_escalator(
          broker,
          sandbox_owner,
          envelope(),
          resolve_client: Pageless.Proc.EscalatorTest.AssertingResolveClient
        )

      :ok = Escalator.kick_off(pid)
      monitor_ref = Process.monitor(pid)
      assert_receive {:DOWN, ^monitor_ref, :process, ^pid, reason}
      assert clean_exit?(reason)

      rows = AgentState.history(Pageless.Repo, agent_id)
      reasoning = Enum.find(rows, &(&1.event_type == :reasoning_line))
      assert reasoning.payload["text"] =~ "fallback"
    end
  end

  defp expect_page_out_from_gemini(args) do
    expect(Pageless.Svc.GeminiClient.Mock, :generate, fn _opts ->
      {:ok,
       struct(Response,
         text: "Paging on-call",
         function_calls: [struct(FunctionCall, name: "page_out", args: args)]
       )}
    end)
  end

  defp start_escalator(broker, sandbox_owner, env \\ envelope(), opts \\ []) do
    %{alert: alert} =
      SupHelpers.start_isolated_alert(
        envelope: env,
        pubsub: broker,
        sandbox_owner: sandbox_owner,
        audit_repo: Pageless.Repo,
        gemini_client: Pageless.Svc.GeminiClient.Mock,
        parent: self()
      )

    resolve_client =
      Keyword.get(opts, :resolve_client, Pageless.Proc.EscalatorTest.SuccessResolveClient)

    assert {:ok, pid} =
             Alert.start_agent(alert, Escalator,
               resolve_client: resolve_client,
               routing_key: "route-key"
             )

    assert {:ok, state} = GenServer.call(pid, :get_state)
    %{pid: pid, agent_id: state.agent_id}
  end

  defp clean_exit?(reason) when reason in [:normal, :noproc, :shutdown], do: true
  defp clean_exit?({:shutdown, _details}), do: true
  defp clean_exit?(_reason), do: false

  defp envelope(overrides \\ []) do
    defaults = %{
      alert_id: "alert-escalator",
      source: :pagerduty,
      source_ref: "pd-dedup",
      fingerprint: "fingerprint-escalator",
      received_at: DateTime.utc_now(),
      started_at: DateTime.utc_now(),
      status: :firing,
      severity: :critical,
      alert_class: :latency,
      title: "payments-api p95 latency above SLO",
      service: "payments-api",
      labels: %{"service" => "payments-api"},
      annotations: %{},
      payload_raw: %{"fixture" => true}
    }

    struct!(AlertEnvelope, Map.merge(defaults, Map.new(overrides)))
  end
end
