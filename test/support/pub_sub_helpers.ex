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

  @doc "Returns true when the given PID is subscribed to the topic on the test broker."
  @spec subscribed?(atom(), String.t(), pid()) :: boolean()
  def subscribed?(broker, topic, pid) when is_atom(broker) and is_binary(topic) and is_pid(pid) do
    broker
    |> Registry.lookup(topic)
    |> Enum.any?(fn {subscribed_pid, _metadata} -> subscribed_pid == pid end)
  end

  @doc "Counts the registry entries for a PID under a broker topic."
  @spec subscription_count(atom(), String.t(), pid()) :: non_neg_integer()
  def subscription_count(broker, topic, pid)
      when is_atom(broker) and is_binary(topic) and is_pid(pid) do
    broker
    |> Registry.lookup(topic)
    |> Enum.count(fn {subscribed_pid, _metadata} -> subscribed_pid == pid end)
  end
end
