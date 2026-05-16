defmodule PagelessWeb.EndpointTest do
  @moduledoc """
  Smoke tests for `PagelessWeb.Endpoint` session-options runtime resolution.

  Asserts the function-form `session_options/0` returns the configured
  keyword list and that the request pipeline still produces a session
  cookie under the new `:session_plug` wrapper. Prod-safety enforcement
  (raise on missing env) lives in `config/runtime.exs`; that path runs
  only in prod releases and is not exercised by the test suite.
  """

  use PagelessWeb.ConnCase, async: true

  alias PagelessWeb.Endpoint

  describe "session_options/0" do
    test "returns a keyword list with the configured shape" do
      opts = Endpoint.session_options()

      assert Keyword.fetch!(opts, :store) == :cookie
      assert Keyword.fetch!(opts, :key) == "_pageless_key"
      assert Keyword.fetch!(opts, :same_site) == "Lax"
      assert is_binary(Keyword.fetch!(opts, :signing_salt))
    end

    test "signing_salt reflects the current app env value" do
      env_salt = Application.fetch_env!(:pageless, :session_signing_salt)
      assert Keyword.fetch!(Endpoint.session_options(), :signing_salt) == env_salt
    end
  end

  describe "request pipeline" do
    test "GET / passes through :session_plug and sets the session cookie", %{conn: conn} do
      conn = get(conn, "/")
      assert conn.status == 200
      assert Map.has_key?(conn.resp_cookies, "_pageless_key")
    end

    test "JSON requests expose raw_body assign alongside parsed params" do
      body = ~s({ "alerts": [], "status": "firing" })

      limiter =
        start_supervised!(
          {Pageless.RateLimiter, routes: %{webhook_alertmanager: %{burst: 10, refill_per_sec: 5}}}
        )

      conn =
        :post
        |> Phoenix.ConnTest.build_conn("/webhook/alertmanager", body)
        |> Plug.Conn.assign(:rate_limiter, limiter)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Endpoint.call([])

      assert conn.assigns.raw_body == body
      assert conn.body_params == %{"alerts" => [], "status" => "firing"}
    end

    test "trusts X-Forwarded-For when explicitly enabled for the endpoint call" do
      conn =
        :get
        |> Phoenix.ConnTest.build_conn("/")
        |> Map.put(:remote_ip, {127, 0, 0, 1})
        |> Plug.Conn.put_req_header("x-forwarded-for", "203.0.113.7")
        |> Endpoint.call(trust_x_forwarded_for: true)

      assert conn.remote_ip == {203, 0, 113, 7}
    end

    test ":keep_rightmost_x_forwarded_for is a no-op when trust is disabled" do
      x_forwarded_for = "1.2.3.4, 9.9.9.9"

      conn =
        :get
        |> Phoenix.ConnTest.build_conn("/")
        |> Map.put(:remote_ip, {127, 0, 0, 1})
        |> Plug.Conn.put_req_header("x-forwarded-for", x_forwarded_for)
        |> Endpoint.call(trust_x_forwarded_for: false)

      assert Plug.Conn.get_req_header(conn, "x-forwarded-for") == [x_forwarded_for]
      assert conn.remote_ip == {127, 0, 0, 1}
    end

    test ":keep_rightmost_x_forwarded_for is a no-op when XFF header is absent" do
      conn =
        :get
        |> Phoenix.ConnTest.build_conn("/")
        |> Map.put(:remote_ip, {127, 0, 0, 1})
        |> Endpoint.call(trust_x_forwarded_for: true)

      assert Plug.Conn.get_req_header(conn, "x-forwarded-for") == []
      assert conn.remote_ip == {127, 0, 0, 1}
    end

    test ":keep_rightmost_x_forwarded_for preserves a single-entry header" do
      conn =
        :get
        |> Phoenix.ConnTest.build_conn("/")
        |> Map.put(:remote_ip, {127, 0, 0, 1})
        |> Plug.Conn.put_req_header("x-forwarded-for", "9.9.9.9")
        |> Endpoint.call(trust_x_forwarded_for: true)

      assert Plug.Conn.get_req_header(conn, "x-forwarded-for") == ["9.9.9.9"]
      assert conn.remote_ip == {9, 9, 9, 9}
    end

    test ":keep_rightmost_x_forwarded_for rewrites two-entry header to rightmost" do
      conn =
        :get
        |> Phoenix.ConnTest.build_conn("/")
        |> Map.put(:remote_ip, {127, 0, 0, 1})
        |> Plug.Conn.put_req_header("x-forwarded-for", "1.2.3.4, 9.9.9.9")
        |> Endpoint.call(trust_x_forwarded_for: true)

      assert Plug.Conn.get_req_header(conn, "x-forwarded-for") == ["9.9.9.9"]
      assert conn.remote_ip == {9, 9, 9, 9}
    end

    test ":keep_rightmost_x_forwarded_for joins multi-value headers, takes rightmost" do
      conn =
        :get
        |> Phoenix.ConnTest.build_conn("/")
        |> Map.put(:remote_ip, {127, 0, 0, 1})
        |> Map.update!(
          :req_headers,
          &[
            {"x-forwarded-for", "1.2.3.4, 5.5.5.5"},
            {"x-forwarded-for", "9.9.9.9"}
            | &1
          ]
        )
        |> Endpoint.call(trust_x_forwarded_for: true)

      assert Plug.Conn.get_req_header(conn, "x-forwarded-for") == ["9.9.9.9"]
      assert conn.remote_ip == {9, 9, 9, 9}
    end

    test ":keep_rightmost_x_forwarded_for trims whitespace around the rightmost entry" do
      conn =
        :get
        |> Phoenix.ConnTest.build_conn("/")
        |> Map.put(:remote_ip, {127, 0, 0, 1})
        |> Plug.Conn.put_req_header("x-forwarded-for", "1.2.3.4 ,  9.9.9.9")
        |> Endpoint.call(trust_x_forwarded_for: true)

      assert Plug.Conn.get_req_header(conn, "x-forwarded-for") == ["9.9.9.9"]
      assert conn.remote_ip == {9, 9, 9, 9}
    end

    test ":keep_rightmost_x_forwarded_for drops empties, takes last non-empty" do
      conn =
        :get
        |> Phoenix.ConnTest.build_conn("/")
        |> Map.put(:remote_ip, {127, 0, 0, 1})
        |> Plug.Conn.put_req_header("x-forwarded-for", "1.2.3.4, , ")
        |> Endpoint.call(trust_x_forwarded_for: true)

      assert Plug.Conn.get_req_header(conn, "x-forwarded-for") == ["1.2.3.4"]
      assert conn.remote_ip == {1, 2, 3, 4}
    end

    test ":keep_rightmost_x_forwarded_for is a no-op when all entries empty" do
      conn =
        :get
        |> Phoenix.ConnTest.build_conn("/")
        |> Map.put(:remote_ip, {127, 0, 0, 1})
        |> Plug.Conn.put_req_header("x-forwarded-for", ", , ")
        |> Endpoint.call(trust_x_forwarded_for: true)

      assert Plug.Conn.get_req_header(conn, "x-forwarded-for") == [", , "]
      assert conn.remote_ip == {127, 0, 0, 1}
    end

    test "Endpoint sets conn.remote_ip to rightmost XFF entry when trust enabled" do
      conn =
        :get
        |> Phoenix.ConnTest.build_conn("/")
        |> Map.put(:remote_ip, {127, 0, 0, 1})
        |> Plug.Conn.put_req_header("x-forwarded-for", "1.2.3.4, 9.9.9.9")
        |> Endpoint.call(trust_x_forwarded_for: true)

      assert conn.remote_ip == {9, 9, 9, 9}
      refute conn.remote_ip == {1, 2, 3, 4}
    end

    test "ignores X-Forwarded-For when trust is disabled" do
      conn =
        :get
        |> Phoenix.ConnTest.build_conn("/")
        |> Map.put(:remote_ip, {127, 0, 0, 1})
        |> Plug.Conn.put_req_header("x-forwarded-for", "203.0.113.7")
        |> Endpoint.call(trust_x_forwarded_for: false)

      assert conn.remote_ip == {127, 0, 0, 1}
    end

    test "endpoint rejects POST bodies larger than 256 KB with 413" do
      body = Jason.encode!(%{"alerts" => [], "padding" => String.duplicate("x", 262_145)})

      conn =
        :post
        |> Phoenix.ConnTest.build_conn("/webhook/alertmanager", body)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Endpoint.call([])

      assert conn.status == 413
      refute Map.has_key?(conn.assigns, :raw_body)
    end

    test "Caddyfile overwrites XFF inside both reverse_proxy blocks" do
      caddyfile = File.read!(Path.expand("../../deploy/Caddyfile", __DIR__))

      reverse_proxy_blocks =
        ~r/reverse_proxy\s+127\.0\.0\.1:4040\s*\{\s*header_up\s+X-Forwarded-For\s+\{remote_host\}\s*\}/
        |> Regex.scan(caddyfile)

      assert length(reverse_proxy_blocks) == 2
    end
  end
end
