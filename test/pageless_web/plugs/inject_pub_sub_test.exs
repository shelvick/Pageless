defmodule PagelessWeb.Plugs.InjectPubSubTest do
  @moduledoc "Tests for injecting PubSub broker names into webhook conns."

  use ExUnit.Case, async: true

  alias PagelessWeb.Plugs.InjectPubSub

  test "default plug opts assign the production broker name" do
    conn = Plug.Test.conn(:post, "/webhook/alertmanager", %{})
    broker = InjectPubSub.init([])

    conn = InjectPubSub.call(conn, broker)

    assert conn.assigns.pubsub_broker == Pageless.PubSub
  end

  test "broker option overrides the default broker name" do
    test_broker = :"test_pubsub_#{System.unique_integer([:positive])}"
    conn = Plug.Test.conn(:post, "/webhook/alertmanager", %{})
    broker = InjectPubSub.init(broker: test_broker)

    conn = InjectPubSub.call(conn, broker)

    assert conn.assigns.pubsub_broker == test_broker
  end
end
