defmodule PagelessWeb.Endpoint do
  @moduledoc """
  Phoenix endpoint for the operator dashboard + alert webhooks.

  Serves the operator dashboard, webhook routes, and LiveView socket.

  ## Session options

  `session_options/0` reads the cookie signing salt from
  `Application.fetch_env!(:pageless, :session_signing_salt)` at request time.
  In `:prod`, `config/runtime.exs` raises if `SESSION_SIGNING_SALT` is unset;
  in dev/test, a non-secret default is supplied so the local server boots.
  The function form is required because:

    * `Plug.Session` is wrapped by the `:session_plug` function plug below so
      `Plug.Session.init/1` runs per request and picks up the runtime app env.
    * `connect_info: [session: {__MODULE__, :session_options, []}]` is the
      Phoenix-supported MFA form (Phoenix.Endpoint docs ~L970) that lets the
      socket pull options at handshake time rather than module-compile time.
  """
  use Phoenix.Endpoint, otp_app: :pageless

  @doc false
  @impl true
  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, opts) do
    conn
    |> put_trust_x_forwarded_for_override(opts)
    |> super(opts)
  rescue
    error in Plug.Parsers.RequestTooLargeError ->
      Plug.Conn.send_resp(conn, 413, Exception.message(error))
  end

  socket("/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: {__MODULE__, :session_options, []}]],
    longpoll: [connect_info: [session: {__MODULE__, :session_options, []}]]
  )

  plug(Plug.Static,
    at: "/",
    from: :pageless,
    gzip: false,
    only: PagelessWeb.static_paths()
  )

  if code_reloading? do
    plug(Phoenix.LiveReloader)
    plug(Phoenix.CodeReloader)
    plug(Phoenix.Ecto.CheckRepoStatus, otp_app: :pageless)
  end

  plug(Phoenix.LiveDashboard.RequestLogger,
    param_key: "request_logger",
    cookie_key: "request_logger"
  )

  plug(:keep_rightmost_x_forwarded_for)
  plug(:rewrite_x_forwarded_for)
  plug(Plug.RequestId)
  plug(Plug.Telemetry, event_prefix: [:phoenix, :endpoint])

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library(),
    body_reader: {PagelessWeb.Plugs.RawBodyReader, :read_body, []},
    length: 262_144
  )

  plug(Plug.MethodOverride)
  plug(Plug.Head)
  plug(:session_plug)
  plug(PagelessWeb.Router)

  @doc """
  Returns session options for `Plug.Session` and the LiveView socket.

  Reads the signing salt from app env at call time; raises if absent
  (enforced for `:prod` by `config/runtime.exs`).
  """
  @spec session_options() :: keyword()
  def session_options do
    [
      store: :cookie,
      key: "_pageless_key",
      signing_salt: Application.fetch_env!(:pageless, :session_signing_salt),
      same_site: "Lax"
    ]
  end

  @spec session_plug(Plug.Conn.t(), term()) :: Plug.Conn.t()
  defp session_plug(conn, _opts) do
    Plug.Session.call(conn, Plug.Session.init(session_options()))
  end

  @spec rewrite_x_forwarded_for(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  defp rewrite_x_forwarded_for(conn, opts) do
    if trust_x_forwarded_for?(conn, opts) do
      Plug.RewriteOn.call(conn, [:x_forwarded_for])
    else
      conn
    end
  end

  @spec keep_rightmost_x_forwarded_for(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  defp keep_rightmost_x_forwarded_for(conn, opts) do
    if trust_x_forwarded_for?(conn, opts) do
      conn
      |> Plug.Conn.get_req_header("x-forwarded-for")
      |> Enum.join(",")
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> List.last()
      |> put_rightmost_x_forwarded_for(conn)
    else
      conn
    end
  end

  defp put_rightmost_x_forwarded_for(nil, conn), do: conn

  defp put_rightmost_x_forwarded_for(value, conn) do
    conn
    |> Plug.Conn.delete_req_header("x-forwarded-for")
    |> Plug.Conn.put_req_header("x-forwarded-for", value)
  end

  defp put_trust_x_forwarded_for_override(conn, opts) do
    Plug.Conn.put_private(
      conn,
      :pageless_trust_x_forwarded_for,
      Keyword.get(opts, :trust_x_forwarded_for)
    )
  end

  defp trust_x_forwarded_for?(conn, _opts) do
    case conn.private[:pageless_trust_x_forwarded_for] do
      nil -> Application.get_env(:pageless, :trust_x_forwarded_for, false)
      value -> value
    end
  end
end
