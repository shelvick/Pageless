defmodule PagelessWeb.Components.AlertIntakeCardTest do
  @moduledoc "Tests for the dashboard alert intake card component."

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Pageless.AlertEnvelope
  alias PagelessWeb.Components.AlertIntakeCard

  describe "alert_intake_card/1" do
    test "renders a quiet placeholder when no alert has arrived" do
      html = render_component(&AlertIntakeCard.alert_intake_card/1, envelope: nil)

      assert html =~ "No alert"
      refute html =~ "payments-api health check failing"
      refute html =~ "payments-api-health-check-failing"
    end

    test "renders the B1 alert fields and conductor badge" do
      envelope = demo_envelope()

      html = render_component(&AlertIntakeCard.alert_intake_card/1, envelope: envelope)

      assert html =~ "payments-api health check failing"
      assert html =~ "P1"
      assert html =~ "payments-api-health-check-failing"
      assert html =~ "Service down with recent deploy"
      assert html =~ "demo"
      assert html =~ "03:45:00"
      assert html =~ "[CONDUCTOR]"
      assert Regex.match?(~r/(bg|border)-red-/, html)
    end
  end

  defp demo_envelope do
    assert {:ok, envelope} =
             AlertEnvelope.new(%{
               alert_id: "demo-b1-payments-api",
               source: :demo,
               source_ref: "pageless-demo:b1",
               fingerprint: "payments-api-health-check-failing",
               received_at: ~U[2026-05-13 03:45:00Z],
               started_at: ~U[2026-05-13 03:44:12Z],
               status: :firing,
               severity: :p1,
               alert_class: :service_down_with_recent_deploy,
               title: "payments-api health check failing — 1/8 instances responding",
               service: "payments-api",
               labels: %{"service" => "payments-api", "severity" => "p1"},
               annotations: %{"summary" => "payments-api health check failing"},
               payload_raw: %{"demo_beat" => "B1"}
             })

    envelope
  end
end
