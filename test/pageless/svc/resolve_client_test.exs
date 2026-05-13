defmodule Pageless.Svc.ResolveClientTest.FakeReq do
  @moduledoc "Req-shaped test double that reports outbound calls to the test process."

  @doc "Posts a captured request back to the test process and returns the configured response."
  @spec post(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def post(url, opts) do
    caller = Keyword.fetch!(opts, :caller)
    send(caller, {:req_post, url, opts})
    Keyword.fetch!(opts, :response)
  end
end

defmodule Pageless.Svc.ResolveClientTest.UncalledReq do
  @moduledoc "Req-shaped test double that fails the test if an HTTP request is attempted."

  @doc "Raises because no-op source paths must not attempt HTTP traffic."
  @spec post(String.t(), keyword()) :: no_return()
  def post(_url, _opts), do: raise("ResolveClient attempted HTTP for a no-op source")
end

defmodule Pageless.Svc.ResolveClientTest do
  @moduledoc "Tests the PagerDuty resolve/escalate client contract."

  use ExUnit.Case, async: true

  alias Pageless.AlertEnvelope
  alias Pageless.Svc.ResolveClient
  alias Pageless.Svc.ResolveClient.Behaviour
  alias Pageless.Svc.ResolveClientTest.{FakeReq, UncalledReq}

  describe "behaviour" do
    test "exposes resolve/2 and escalate/3 callbacks" do
      callbacks = Behaviour.behaviour_info(:callbacks)

      assert Enum.sort(callbacks) == [escalate: 3, resolve: 2]
    end
  end

  describe "resolve/2" do
    test "posts a PagerDuty resolve event with source_ref as dedup key" do
      envelope = envelope(source: :pagerduty, source_ref: "pd-dedup-123")

      assert {:ok, %{status: 202, dedup_key: "pd-dedup-123"}} =
               ResolveClient.resolve(envelope,
                 routing_key: "route-key",
                 req_module: FakeReq,
                 caller: self(),
                 response: {:ok, %{status: 202, body: %{"dedup_key" => "pd-dedup-123"}}}
               )

      assert_receive {:req_post, "https://events.pagerduty.com/v2/enqueue", opts}
      body = Keyword.fetch!(opts, :json)
      assert body["routing_key"] == "route-key"
      assert body["event_action"] == "resolve"
      assert body["dedup_key"] == "pd-dedup-123"
      assert Keyword.fetch!(opts, :retry) == false
    end

    test "falls back to alert_id when source_ref is nil" do
      envelope = envelope(source: :pagerduty, source_ref: nil, alert_id: "alert-fallback")

      assert {:ok, %{status: 202, dedup_key: "alert-fallback"}} =
               ResolveClient.resolve(envelope,
                 routing_key: "route-key",
                 req_module: FakeReq,
                 caller: self(),
                 response: {:ok, %{status: 202, body: %{"dedup_key" => "alert-fallback"}}}
               )

      assert_receive {:req_post, _url, opts}
      assert Keyword.fetch!(opts, :json)["dedup_key"] == "alert-fallback"
    end

    test "returns rate_limited without retrying on PagerDuty 429" do
      envelope = envelope(source: :pagerduty)

      assert {:error, :rate_limited} =
               ResolveClient.resolve(envelope,
                 routing_key: "route-key",
                 req_module: FakeReq,
                 caller: self(),
                 response: {:ok, %{status: 429, body: %{"error" => "rate limited"}}}
               )

      assert_receive {:req_post, _url, opts}
      assert Keyword.fetch!(opts, :retry) == false
      refute_receive {:req_post, _url, _opts}, 25
    end

    test "returns bad request details for PagerDuty 400" do
      envelope = envelope(source: :pagerduty)
      body = %{"errors" => ["routing_key is invalid"]}

      assert {:error, {:pd_bad_request, ^body}} =
               ResolveClient.resolve(envelope,
                 routing_key: "route-key",
                 req_module: FakeReq,
                 caller: self(),
                 response: {:ok, %{status: 400, body: body}}
               )
    end

    test "returns network errors without raising" do
      envelope = envelope(source: :pagerduty)

      assert {:error, {:network, :timeout}} =
               ResolveClient.resolve(envelope,
                 routing_key: "route-key",
                 req_module: FakeReq,
                 caller: self(),
                 response: {:error, :timeout}
               )
    end

    test "returns missing_routing_key without attempting HTTP" do
      envelope = envelope(source: :pagerduty)

      assert {:error, :missing_routing_key} =
               ResolveClient.resolve(envelope, req_module: UncalledReq)
    end
  end

  describe "escalate/3" do
    test "posts a PagerDuty trigger event with structured page payload" do
      envelope = envelope(source: :pagerduty, service: "payments-api", alert_class: :latency)

      page = %{
        summary: "Service down",
        severity: :critical,
        dedup_key: "page-dedup",
        runbook_link: "https://runbooks.example/payments",
        extra: %{"pool" => "saturated"}
      }

      assert {:ok, %{status: 202, dedup_key: "page-dedup"}} =
               ResolveClient.escalate(envelope, page,
                 routing_key: "route-key",
                 req_module: FakeReq,
                 caller: self(),
                 response: {:ok, %{status: 202, body: %{"dedup_key" => "page-dedup"}}}
               )

      assert_receive {:req_post, "https://events.pagerduty.com/v2/enqueue", opts}
      body = Keyword.fetch!(opts, :json)
      assert body["event_action"] == "trigger"
      assert body["dedup_key"] == "page-dedup"
      assert body["payload"]["summary"] == "Service down"
      assert body["payload"]["severity"] == "critical"
      assert body["payload"]["source"] == "pageless"
      assert body["payload"]["component"] == "payments-api"
      assert body["payload"]["custom_details"]["alert_id"] == envelope.alert_id
      assert body["payload"]["custom_details"]["alert_class"] == "latency"
      assert body["payload"]["custom_details"]["pool"] == "saturated"

      assert body["links"] == [
               %{"href" => "https://runbooks.example/payments", "text" => "Runbook"}
             ]
    end

    test "falls back to alert_id when page dedup_key is nil" do
      envelope = envelope(source: :pagerduty, alert_id: "alert-escalate-fallback")
      page = %{summary: "Service down", severity: :error, dedup_key: nil}

      assert {:ok, %{status: 202, dedup_key: "alert-escalate-fallback"}} =
               ResolveClient.escalate(envelope, page,
                 routing_key: "route-key",
                 req_module: FakeReq,
                 caller: self(),
                 response:
                   {:ok, %{status: 202, body: %{"dedup_key" => "alert-escalate-fallback"}}}
               )

      assert_receive {:req_post, _url, opts}
      assert Keyword.fetch!(opts, :json)["dedup_key"] == "alert-escalate-fallback"
    end
  end

  describe "no-op sources" do
    test "Alertmanager resolve and escalate short-circuit without HTTP" do
      envelope = envelope(source: :alertmanager)
      page = %{summary: "Page human", severity: :warning}

      assert {:ok, :noop} = ResolveClient.resolve(envelope, req_module: UncalledReq)
      assert {:ok, :noop} = ResolveClient.escalate(envelope, page, req_module: UncalledReq)
    end

    test "demo resolve and escalate short-circuit without HTTP" do
      envelope = envelope(source: :demo)
      page = %{summary: "Synthetic page", severity: :info}

      assert {:ok, :noop} = ResolveClient.resolve(envelope, req_module: UncalledReq)
      assert {:ok, :noop} = ResolveClient.escalate(envelope, page, req_module: UncalledReq)
    end
  end

  describe "telemetry" do
    test "emits one event for each PagerDuty resolve call" do
      handler_id = {:test_resolve_client, System.unique_integer([:positive])}
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:pageless, :resolve_client, :pd, :resolve],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      envelope = envelope(source: :pagerduty, alert_id: "alert-telemetry")

      assert {:ok, %{status: 202}} =
               ResolveClient.resolve(envelope,
                 routing_key: "route-key",
                 req_module: FakeReq,
                 caller: self(),
                 metadata: %{scenario: "unit"},
                 response: {:ok, %{status: 202, body: %{"dedup_key" => "pd-dedup"}}}
               )

      assert_receive {:telemetry_event, [:pageless, :resolve_client, :pd, :resolve], measurements,
                      metadata}

      assert is_integer(measurements.duration_us)
      assert metadata.source == :pagerduty
      assert metadata.alert_id == "alert-telemetry"
      assert metadata.status_or_reason == 202
      assert metadata.metadata == %{scenario: "unit"}
    end
  end

  defp envelope(overrides) do
    defaults = %{
      alert_id: "alert-123",
      source: :pagerduty,
      source_ref: "pd-dedup",
      fingerprint: "fingerprint-123",
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
