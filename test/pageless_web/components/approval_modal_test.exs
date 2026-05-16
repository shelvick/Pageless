defmodule PagelessWeb.Components.ApprovalModalTest do
  @moduledoc """
  Tests pure helpers in the approval modal component. Modal render-path
  acceptance lives in `PagelessWeb.OperatorDashboardLiveTest`; this file
  covers the URI scheme allowlist on evidence links.
  """

  use ExUnit.Case, async: true

  alias PagelessWeb.Components.ApprovalModal

  describe "evidence_link/1 scheme allowlist" do
    test "returns the URL for https links" do
      assert ApprovalModal.evidence_link(%{evidence_link: "https://example.com/evidence/42"}) ==
               "https://example.com/evidence/42"
    end

    test "returns the URL for http links" do
      assert ApprovalModal.evidence_link(%{evidence_link: "http://intranet/evidence/1"}) ==
               "http://intranet/evidence/1"
    end

    test "returns the URL for mailto links" do
      assert ApprovalModal.evidence_link(%{evidence_link: "mailto:oncall@example.com"}) ==
               "mailto:oncall@example.com"
    end

    test "rejects javascript: pseudo-URLs" do
      refute ApprovalModal.evidence_link(%{evidence_link: "javascript:alert(1)"})
    end

    test "rejects data: URLs" do
      refute ApprovalModal.evidence_link(%{
               evidence_link: "data:text/html,<script>alert(1)</script>"
             })
    end

    test "rejects file: URLs" do
      refute ApprovalModal.evidence_link(%{evidence_link: "file:///etc/passwd"})
    end

    test "rejects internal agent_state:findings:N references" do
      refute ApprovalModal.evidence_link(%{evidence_link: "agent_state:findings:3"})
    end

    test "rejects URLs with embedded credentials" do
      refute ApprovalModal.evidence_link(%{evidence_link: "https://user:pass@example.com/x"})
      refute ApprovalModal.evidence_link(%{evidence_link: "https://attacker@example.com/x"})
    end

    test "accepts the same shapes via string-keyed reasoning_context" do
      assert ApprovalModal.evidence_link(%{"evidence_link" => "https://example.com"}) ==
               "https://example.com"

      refute ApprovalModal.evidence_link(%{"evidence_link" => "javascript:alert(1)"})
    end

    test "returns nil when evidence_link key is absent" do
      refute ApprovalModal.evidence_link(%{summary: "no link here"})
      refute ApprovalModal.evidence_link(%{})
    end

    test "returns nil when evidence_link is not a binary" do
      refute ApprovalModal.evidence_link(%{evidence_link: nil})
      refute ApprovalModal.evidence_link(%{evidence_link: 42})
    end
  end
end
