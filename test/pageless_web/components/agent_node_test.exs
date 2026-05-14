defmodule PagelessWeb.Components.AgentNodeTest do
  @moduledoc "Tests for the per-agent visual node component."

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias PagelessWeb.Components.AgentNode

  describe "render_component/2" do
    test "renders a compact idle triager without reasoning or tool-call chrome" do
      html = render_node(role: :triager, id: "triager-1", data: node_data(status: :idle))

      assert html =~ "Triager"
      assert html =~ "triager-1"
      refute html =~ "Reasoning"
      refute html =~ "kubectl"
    end

    test "renders active thinking state with stable cyan or pulse cue" do
      html = render_node(role: :triager, id: "triager-1", data: node_data(status: :thinking))

      assert html =~ "Triager"
      assert Regex.match?(~r/(border-cyan-|animate-pulse)/, html)
    end

    test "renders streamed reasoning lines" do
      html =
        render_node(
          role: :investigator,
          id: "investigator-logs-1",
          data: node_data(status: :thinking, reasoning: ["line one", "line two", "line three"])
        )

      assert html =~ "line one"
      assert html =~ "line two"
      assert html =~ "line three"
    end

    test "renders literal tool call with classification chip" do
      html =
        render_node(
          role: :remediator,
          id: "remediator-1",
          data:
            node_data(
              status: :tool_active,
              tool_call: %{
                command: "kubectl rollout undo deployment/payments-api -n prod",
                classification: :write_prod_high,
                result: nil
              }
            )
        )

      assert html =~ "kubectl rollout undo deployment/payments-api -n prod"
      assert Regex.match?(~r/(WRITE_PROD_HIGH|border-red-)/, html)
    end

    test "renders each cap-class banner with distinct visible text" do
      assert render_node(data: node_data(status: :gated, banner: :gated)) =~ "GATED"
      assert render_node(data: node_data(status: :escalated, banner: :escalated)) =~ "ESCALATED"

      assert render_node(data: node_data(status: :auto_fired, banner: :auto_fired)) =~
               "AUTONOMOUS"
    end

    test "renders done nodes without thinking pulse cue" do
      html = render_node(role: :triager, id: "triager-1", data: node_data(status: :done))

      assert html =~ "Triager"
      refute html =~ "animate-pulse"
    end

    test "renders investigator profile payload" do
      html =
        render_node(
          role: :investigator,
          id: "investigator-logs-1",
          data: node_data(status: :thinking, payload: %{profile: :logs})
        )

      assert Regex.match?(~r/(Logs|logs)/, html)
    end

    test "renders conductor badge when beat is conductor-owned" do
      html =
        render_node(
          role: :triager,
          id: "triager-1",
          beat: :b1,
          data: node_data(status: :thinking)
        )

      assert html =~ "[CONDUCTOR]"
    end

    test "unknown status renders without crashing with default styling" do
      html =
        render_node(role: :triager, id: "triager-1", data: node_data(status: :something_weird))

      assert html =~ "Triager"
      assert html =~ "triager-1"
    end
  end

  defp render_node(opts) do
    assigns =
      Keyword.merge(
        [
          role: :triager,
          id: "agent-1",
          beat: nil,
          data: node_data()
        ],
        opts
      )

    render_component(AgentNode, assigns)
  end

  defp node_data(overrides \\ []) do
    Map.merge(
      %{
        status: :idle,
        reasoning: [],
        tool_call: nil,
        elapsed_ms: nil,
        banner: nil,
        gate_id: nil,
        payload: %{}
      },
      Map.new(overrides)
    )
  end
end
