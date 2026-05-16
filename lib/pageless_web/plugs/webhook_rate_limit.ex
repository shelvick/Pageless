defmodule PagelessWeb.Plugs.WebhookRateLimit do
  @moduledoc """
  Enforces per-route webhook rate limits through `Pageless.RateLimiter`.
  """

  import Plug.Conn

  @behaviour Plug

  @type init_opts :: [route_id: atom(), server: GenServer.server()]
  @type compiled_opts :: %{route_id: atom(), default_server: GenServer.server()}

  @doc "Compiles rate-limit plug options."
  @impl true
  @spec init(init_opts()) :: compiled_opts()
  def init(opts) do
    route_id = Keyword.get(opts, :route_id)

    unless is_atom(route_id) and not is_nil(route_id) do
      raise ArgumentError, ":route_id must be an atom"
    end

    %{route_id: route_id, default_server: Keyword.get(opts, :server, Pageless.RateLimiter)}
  end

  @doc "Checks the request against the configured limiter and halts on 429."
  @impl true
  @spec call(Plug.Conn.t(), compiled_opts()) :: Plug.Conn.t()
  def call(conn, %{route_id: route_id, default_server: default_server}) do
    server = conn.assigns[:rate_limiter] || default_server

    check_rate_limit(conn, server, route_id)
  end

  defp check_rate_limit(conn, server, route_id) do
    case Pageless.RateLimiter.check(server, route_id, conn.remote_ip) do
      :ok ->
        conn

      {:error, :rate_limited, retry_after_ms} ->
        retry_after_s = retry_after_ms |> retry_after_seconds() |> max(1)

        conn
        |> put_resp_header("retry-after", Integer.to_string(retry_after_s))
        |> put_resp_content_type("application/json")
        |> send_resp(
          429,
          Jason.encode!(%{
            error: "rate_limited",
            route_id: route_id,
            retry_after_ms: retry_after_ms
          })
        )
        |> halt()
    end
  end

  if Code.ensure_loaded?(Integer) and function_exported?(Integer, :ceil_div, 2) do
    @compile {:no_warn_undefined, {Integer, :ceil_div, 2}}
    defp retry_after_seconds(retry_after_ms), do: Integer.ceil_div(retry_after_ms, 1_000)
  else
    defp retry_after_seconds(retry_after_ms), do: div(retry_after_ms + 999, 1_000)
  end
end
