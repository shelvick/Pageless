defmodule PagelessWeb.Plugs.InjectPubSub do
  @moduledoc """
  Assigns the PubSub broker used by webhook controllers.
  """

  @behaviour Plug

  @impl true
  @spec init(keyword()) :: atom()
  def init(opts), do: Keyword.get(opts, :broker, Pageless.PubSub)

  @impl true
  @spec call(Plug.Conn.t(), atom()) :: Plug.Conn.t()
  def call(conn, broker), do: Plug.Conn.assign(conn, :pubsub_broker, broker)
end
