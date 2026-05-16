defmodule PagelessWeb.Plugs.WebhookRateLimitTest.LimiterStub do
  @moduledoc "Per-test GenServer that speaks the Pageless.RateLimiter.check/4 call protocol."

  use GenServer

  @type response :: :ok | {:error, :rate_limited, non_neg_integer()}
  @type opts :: [owner: pid(), responses: [response()]]

  @doc false
  @spec child_spec(opts()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: {__MODULE__, System.unique_integer([:positive])},
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  @doc false
  @spec start_link(opts()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    {:ok, %{owner: Keyword.fetch!(opts, :owner), responses: Keyword.fetch!(opts, :responses)}}
  end

  @impl true
  def handle_call({:check, route_id, ip, _opts}, _from, %{responses: [response | rest]} = state) do
    send(state.owner, {:limiter_checked, self(), route_id, ip})
    {:reply, response, %{state | responses: rest}}
  end
end

defmodule PagelessWeb.Plugs.WebhookRateLimitTest do
  @moduledoc "Tests the webhook rate-limit plug adapter around Pageless.RateLimiter."

  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias PagelessWeb.Plugs.WebhookRateLimit
  alias PagelessWeb.Plugs.WebhookRateLimitTest.LimiterStub

  describe "init/1" do
    test "returns compiled opts with default server" do
      assert WebhookRateLimit.init(route_id: :webhook_alertmanager) == %{
               route_id: :webhook_alertmanager,
               default_server: Pageless.RateLimiter
             }
    end

    test "stores explicit :server opt as default_server" do
      server = self()

      assert WebhookRateLimit.init(route_id: :webhook_alertmanager, server: server) == %{
               route_id: :webhook_alertmanager,
               default_server: server
             }
    end

    test "raises when :route_id is missing" do
      assert_raise ArgumentError, ~r/:route_id/, fn ->
        WebhookRateLimit.init([])
      end
    end

    test "raises when :route_id is not an atom" do
      assert_raise ArgumentError, ~r/:route_id/, fn ->
        WebhookRateLimit.init(route_id: "webhook_alertmanager")
      end
    end
  end

  describe "call/2" do
    test "passes conn through unchanged when limiter returns :ok" do
      limiter = start_supervised!({LimiterStub, owner: self(), responses: [:ok]})
      conn = call_conn(:webhook_alertmanager, limiter)

      refute conn.halted
      assert conn.status == nil
      assert get_resp_header(conn, "retry-after") == []
      assert_receive {:limiter_checked, ^limiter, :webhook_alertmanager, {127, 0, 0, 1}}
    end

    test "halts with 429 and retry-after header on rate-limited" do
      limiter =
        start_supervised!({LimiterStub, owner: self(), responses: [{:error, :rate_limited, 750}]})

      conn = call_conn(:webhook_alertmanager, limiter)

      assert conn.halted
      assert conn.status == 429
      assert get_resp_header(conn, "retry-after") == ["1"]

      assert Jason.decode!(conn.resp_body) == %{
               "error" => "rate_limited",
               "route_id" => "webhook_alertmanager",
               "retry_after_ms" => 750
             }
    end

    test "rounds retry_after_ms up to the next second" do
      limiter =
        start_supervised!(
          {LimiterStub, owner: self(), responses: [{:error, :rate_limited, 1500}]}
        )

      conn = call_conn(:webhook_alertmanager, limiter)

      assert get_resp_header(conn, "retry-after") == ["2"]
    end

    test "floors retry-after at 1 second when retry_after_ms is 0" do
      limiter =
        start_supervised!({LimiterStub, owner: self(), responses: [{:error, :rate_limited, 0}]})

      conn = call_conn(:webhook_alertmanager, limiter)

      assert get_resp_header(conn, "retry-after") == ["1"]
    end

    test "uses conn.assigns[:rate_limiter] when present" do
      default = start_supervised!({LimiterStub, owner: self(), responses: [:ok]})

      injected =
        start_supervised!(
          {LimiterStub, owner: self(), responses: [{:error, :rate_limited, 1000}]}
        )

      opts = WebhookRateLimit.init(route_id: :webhook_alertmanager, server: default)

      conn =
        :post
        |> conn("/webhook/alertmanager", "{}")
        |> assign(:rate_limiter, injected)
        |> WebhookRateLimit.call(opts)

      assert conn.status == 429
      assert_receive {:limiter_checked, ^injected, :webhook_alertmanager, {127, 0, 0, 1}}
    end

    test "forwards route_id atom verbatim to the limiter" do
      limiter = start_supervised!({LimiterStub, owner: self(), responses: [:ok]})
      _conn = call_conn(:webhook_pagerduty, limiter)

      assert_receive {:limiter_checked, ^limiter, :webhook_pagerduty, {127, 0, 0, 1}}
    end

    test "forwards conn.remote_ip verbatim to the limiter" do
      limiter = start_supervised!({LimiterStub, owner: self(), responses: [:ok]})
      conn = %{conn(:post, "/webhook/alertmanager", "{}") | remote_ip: {192, 168, 1, 5}}
      opts = WebhookRateLimit.init(route_id: :webhook_alertmanager, server: limiter)

      _conn = WebhookRateLimit.call(conn, opts)

      assert_receive {:limiter_checked, ^limiter, :webhook_alertmanager, {192, 168, 1, 5}}
    end
  end

  defp call_conn(route_id, server) do
    opts = WebhookRateLimit.init(route_id: route_id, server: server)
    WebhookRateLimit.call(conn(:post, "/webhook/alertmanager", "{}"), opts)
  end
end
