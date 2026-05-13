defmodule Pageless.PubSubHelpers do
  @moduledoc "Test helpers for per-test isolated Phoenix.PubSub brokers."

  @doc "Starts a uniquely named PubSub broker under the current test supervisor."
  @spec start_isolated_pubsub() :: atom()
  def start_isolated_pubsub do
    name = :"test_pubsub_#{System.unique_integer([:positive])}"
    ExUnit.Callbacks.start_supervised!({Phoenix.PubSub, name: name}, id: name)
    name
  end

  @doc "Subscribes the current process to a topic on the provided test broker."
  @spec subscribe(atom(), String.t()) :: :ok | {:error, term()}
  def subscribe(broker, topic), do: Phoenix.PubSub.subscribe(broker, topic)
end
