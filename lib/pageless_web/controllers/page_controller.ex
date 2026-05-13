defmodule PagelessWeb.PageController do
  @moduledoc """
  Day 1 scaffold controller. Serves a 200 OK plaintext smoke-test response
  at `/`. Replaced by the operator dashboard LiveView in a later Change Set.
  """
  use Phoenix.Controller, formats: [:html]

  @doc "Scaffold smoke-test response at `/`. 200 OK plaintext."
  @spec home(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def home(conn, _params) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, "Pageless — scaffold OK")
  end
end
