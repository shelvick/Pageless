defmodule Pageless.PubSubHelpersTest do
  @moduledoc "Tests for per-test isolated PubSub helper behavior."

  use ExUnit.Case, async: true

  alias Pageless.PubSubHelpers

  test "starts a uniquely named supervised PubSub broker" do
    broker = PubSubHelpers.start_isolated_pubsub()

    assert is_atom(broker)
    assert broker |> Atom.to_string() |> String.starts_with?("test_pubsub_")
    assert :ok = Phoenix.PubSub.subscribe(broker, "alerts")
    assert :ok = Phoenix.PubSub.broadcast(broker, "alerts", {:helper_probe, self()})
    assert_receive {:helper_probe, _pid}
  end

  test "isolated brokers do not leak broadcasts across topics" do
    first_broker = PubSubHelpers.start_isolated_pubsub()
    second_broker = PubSubHelpers.start_isolated_pubsub()

    assert first_broker != second_broker
    assert :ok = PubSubHelpers.subscribe(first_broker, "alerts")
    assert :ok = Phoenix.PubSub.broadcast(second_broker, "alerts", {:alert_received, :other})

    refute_receive {:alert_received, :other}, 25
  end
end
