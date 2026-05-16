defmodule PagelessWeb.Plugs.PagerDutyHMACVerifyTest do
  @moduledoc "Tests PagerDuty webhook HMAC verification against preserved raw bodies."

  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias PagelessWeb.Plugs.PagerDutyHMACVerify

  @secret "test-pagerduty-secret"
  @body ~s({"event":{"id":"evt-1"}})

  describe "init/1" do
    test "returns configured defaults when no opts passed" do
      opts = PagerDutyHMACVerify.init([])

      assert opts.secret == nil
      assert opts.required == Application.get_env(:pageless, :pagerduty_webhook_required, true)
      assert opts.header_name == "x-pagerduty-signature"
      assert is_function(opts.secret_provider, 0)
    end

    test "honors explicit secret, required, and header_name opts" do
      opts = PagerDutyHMACVerify.init(secret: "abc", required: false, header_name: "x-test-sig")

      assert opts.secret == "abc"
      assert opts.required == false
      assert opts.header_name == "x-test-sig"
    end

    test "accepts explicit required false" do
      assert %{required: false} = PagerDutyHMACVerify.init(required: false)
    end
  end

  describe "call/2" do
    test "passes through when signature matches" do
      conn = signed_conn(@body, @secret)
      opts = PagerDutyHMACVerify.init(secret: @secret, required: true)

      conn = PagerDutyHMACVerify.call(conn, opts)

      refute conn.halted
      assert conn.status == nil
    end

    test "rejects 401 on tampered body" do
      signature = signature_for(~s({"event":{"id":"signed"}}), @secret)

      conn =
        @body
        |> base_conn()
        |> put_req_header("x-pagerduty-signature", "v1=#{signature}")

      assert_hmac_rejection(conn, "signature_mismatch")
    end

    test "rejects 401 when signature header is missing" do
      @body
      |> base_conn()
      |> assert_hmac_rejection("missing_signature_header")
    end

    test "rejects 401 when signature header is empty" do
      @body
      |> base_conn()
      |> put_req_header("x-pagerduty-signature", "")
      |> assert_hmac_rejection("empty_signature_header")
    end

    test "rejects 401 when header has no v1= entries" do
      @body
      |> base_conn()
      |> put_req_header("x-pagerduty-signature", "v2=abc,foo=bar")
      |> assert_hmac_rejection("signature_mismatch")
    end

    test "passes when any v1= entry in multi-entry header matches" do
      good = signature_for(@body, @secret)

      conn =
        @body
        |> base_conn()
        |> put_req_header("x-pagerduty-signature", "v1=badc0ffee,v1=#{good}")
        |> PagerDutyHMACVerify.call(PagerDutyHMACVerify.init(secret: @secret, required: true))

      refute conn.halted
      assert conn.status == nil
    end

    test "tolerates whitespace around v1= entries" do
      good = signature_for(@body, @secret)

      conn =
        @body
        |> base_conn()
        |> put_req_header("x-pagerduty-signature", "  v1=#{good} , v1=badc0ffee ")
        |> PagerDutyHMACVerify.call(PagerDutyHMACVerify.init(secret: @secret, required: true))

      refute conn.halted
      assert conn.status == nil
    end

    test "lowercases v1= entries before comparison" do
      good = @body |> signature_for(@secret) |> String.upcase()

      conn =
        @body
        |> base_conn()
        |> put_req_header("x-pagerduty-signature", "v1=#{good}")
        |> PagerDutyHMACVerify.call(PagerDutyHMACVerify.init(secret: @secret, required: true))

      refute conn.halted
      assert conn.status == nil
    end

    test "rejects 401 when raw_body assign is missing" do
      conn =
        conn(:post, "/webhook/pagerduty-events-v2", @body)
        |> put_req_header("x-pagerduty-signature", "v1=#{signature_for(@body, @secret)}")

      assert_hmac_rejection(conn, "missing_raw_body")
    end

    test "rejects 401 when secret is missing and required" do
      opts = PagerDutyHMACVerify.init(secret_provider: fn -> nil end, required: true)

      conn =
        @body
        |> signed_conn(@secret)
        |> PagerDutyHMACVerify.call(opts)

      assert conn.status == 401
      assert conn.halted
      assert Jason.decode!(conn.resp_body)["reason"] == "missing_secret"
    end

    test "passes through when secret is missing and required is false" do
      opts = PagerDutyHMACVerify.init(secret_provider: fn -> nil end, required: false)

      conn = PagerDutyHMACVerify.call(base_conn(@body), opts)

      refute conn.halted
      assert conn.status == nil
    end

    test "reads secret from provider at request time" do
      opts = PagerDutyHMACVerify.init(secret_provider: fn -> @secret end, required: true)

      conn =
        @body
        |> signed_conn(@secret)
        |> PagerDutyHMACVerify.call(opts)

      refute conn.halted
      assert conn.status == nil
    end
  end

  test "source contains secure_compare and no direct digest equality" do
    path = Path.expand("../../../lib/pageless_web/plugs/pager_duty_hmac_verify.ex", __DIR__)
    source = File.read!(path)

    assert source =~ "Plug.Crypto.secure_compare"
    refute source =~ ~r/computed\s*==/
    refute source =~ ~r/computed\s*===/
  end

  defp assert_hmac_rejection(conn, reason) do
    conn =
      PagerDutyHMACVerify.call(conn, PagerDutyHMACVerify.init(secret: @secret, required: true))

    assert conn.status == 401
    assert conn.halted

    assert Jason.decode!(conn.resp_body) == %{
             "error" => "hmac_verification_failed",
             "reason" => reason
           }
  end

  defp signed_conn(body, secret) do
    body
    |> base_conn()
    |> put_req_header("x-pagerduty-signature", "v1=#{signature_for(body, secret)}")
  end

  defp base_conn(body) do
    :post
    |> conn("/webhook/pagerduty-events-v2", body)
    |> assign(:raw_body, body)
  end

  defp signature_for(body, secret) do
    :hmac
    |> :crypto.mac(:sha256, secret, body)
    |> Base.encode16(case: :lower)
  end
end
