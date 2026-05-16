defmodule Pageless.WebhookDedup do
  @moduledoc """
  Envelope-fingerprint deduplication cache backed by a process-owned ETS table.

  A first sighting of `{source, fingerprint, status}` returns `:ok`. Repeated
  sightings within the configured window return `{:duplicate, age_ms}` without
  extending the stored timestamp.
  """

  use GenServer

  @type source :: atom()
  @type dedup_input ::
          Pageless.AlertEnvelope.t()
          | %{required(:fingerprint) => String.t(), required(:status) => atom()}
  @type opts :: [
          window_ms: pos_integer(),
          prune_interval_ms: pos_integer(),
          name: GenServer.name(),
          clock: (-> integer())
        ]

  @doc "Starts a deduplication cache process."
  @spec start_link(opts()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {genserver_opts, init_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, init_opts, genserver_opts)
  end

  @doc "Checks whether an envelope has already been seen within the dedup window."
  @spec check_or_record(pid() | GenServer.name(), source(), dedup_input()) ::
          :ok | {:duplicate, non_neg_integer()}
  def check_or_record(server, source, envelope) do
    GenServer.call(server, {:check_or_record, source, envelope})
  end

  @impl true
  def init(opts) do
    window_ms =
      Keyword.get_lazy(opts, :window_ms, fn ->
        Application.get_env(:pageless, :webhook_dedup_window_ms, 60_000)
      end)

    state = %{
      table: :ets.new(:pageless_webhook_dedup, [:set, :public, {:read_concurrency, true}]),
      window_us: window_ms * 1_000,
      prune_interval_ms: Keyword.get(opts, :prune_interval_ms, 30_000),
      clock: Keyword.get(opts, :clock, fn -> System.monotonic_time(:microsecond) end),
      timer_ref: nil
    }

    {:ok, state, {:continue, :setup}}
  end

  @impl true
  def handle_continue(:setup, state) do
    {:noreply, arm_prune(state)}
  end

  @impl true
  def handle_call({:check_or_record, source, envelope}, _from, state) do
    now_us = state.clock.()
    key = {source, Map.fetch!(envelope, :fingerprint), Map.fetch!(envelope, :status)}
    result = check_key(state.table, key, now_us, state.window_us)

    {:reply, result, state}
  end

  @impl true
  def handle_info(:prune, state) do
    cutoff_us = state.clock.() - state.window_us
    :ets.select_delete(state.table, [{{:_, :"$1"}, [{:<, :"$1", cutoff_us}], [true]}])

    {:noreply, arm_prune(state)}
  end

  defp check_key(table, key, now_us, window_us) do
    case :ets.lookup(table, key) do
      [] ->
        record(table, key, now_us)

      [{^key, last_seen_us}] ->
        age_us = max(0, now_us - last_seen_us)

        if age_us > window_us do
          record(table, key, now_us)
        else
          {:duplicate, div(age_us, 1_000)}
        end
    end
  end

  defp record(table, key, now_us) do
    :ets.insert(table, {key, now_us})
    :ok
  end

  defp arm_prune(state) do
    %{state | timer_ref: Process.send_after(self(), :prune, state.prune_interval_ms)}
  end
end
