defmodule Pageless.RateLimiter do
  @moduledoc """
  Per-route token-bucket limiter backed by a process-owned ETS table.

  Callers pass the server PID/name, route id, and client IP. Bucket mutations are
  serialized through the GenServer; ETS is public only so tests and diagnostics can
  inspect current bucket state without introducing a named table.
  """

  use GenServer

  require Logger

  @fallback_bucket %{burst: 10, refill_per_sec: 5}
  @max_retry_after_ms 2_147_483_648

  @type ip :: :inet.ip_address() | binary()
  @type route_id :: atom() | binary()
  @type bucket_config :: %{burst: non_neg_integer(), refill_per_sec: number()}
  @type opts :: [routes: map(), name: GenServer.name(), clock: (-> integer())]
  @type check_opts :: [now_us: integer()]

  @doc "Starts a rate limiter process with process-local bucket state."
  @spec start_link(opts()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {genserver_opts, init_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, init_opts, genserver_opts)
  end

  @doc "Checks whether a route/IP tuple may consume one token."
  @spec check(pid() | GenServer.name(), route_id(), ip(), check_opts()) ::
          :ok | {:error, :rate_limited, non_neg_integer()}
  def check(server, route_id, ip, opts \\ []) do
    GenServer.call(server, {:check, route_id, ip, opts})
  end

  @impl true
  def init(opts) do
    table = :ets.new(:pageless_rate_limiter, [:set, :public, {:read_concurrency, true}])

    state = %{
      table: table,
      routes: normalize_routes(Keyword.get(opts, :routes, %{})),
      clock: Keyword.get(opts, :clock, fn -> System.monotonic_time(:microsecond) end),
      logged_unknown_routes: MapSet.new()
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:check, route_id, ip, opts}, _from, state) do
    now_us = Keyword.get_lazy(opts, :now_us, state.clock)
    {bucket, state} = bucket_for_route(route_id, state)
    key = {route_id, ip}
    result = check_bucket(state.table, key, bucket, now_us)

    {:reply, result, state}
  end

  defp check_bucket(table, key, bucket, now_us) do
    case :ets.lookup(table, key) do
      [] ->
        consume(table, key, bucket.burst * 1.0, now_us, bucket)

      [{^key, tokens_remaining, last_refill_us}] ->
        elapsed_us = max(0, now_us - last_refill_us)

        refilled =
          min(
            bucket.burst * 1.0,
            tokens_remaining + elapsed_us * bucket.refill_per_sec / 1_000_000
          )

        consume(table, key, refilled, now_us, bucket)
    end
  end

  defp consume(table, key, tokens, now_us, %{burst: burst}) when burst <= 0 do
    :ets.insert(table, {key, tokens, now_us})
    {:error, :rate_limited, @max_retry_after_ms}
  end

  defp consume(table, key, tokens, now_us, _bucket) when tokens >= 1.0 do
    :ets.insert(table, {key, tokens - 1.0, now_us})
    :ok
  end

  defp consume(table, key, tokens, now_us, bucket) do
    :ets.insert(table, {key, tokens, now_us})
    {:error, :rate_limited, retry_after_ms(tokens, bucket.refill_per_sec)}
  end

  defp retry_after_ms(_tokens, refill_per_sec) when refill_per_sec <= 0, do: @max_retry_after_ms

  defp retry_after_ms(tokens, refill_per_sec) do
    tokens
    |> then(&((1.0 - &1) / refill_per_sec * 1_000))
    |> ceil()
    |> max(0)
  end

  defp bucket_for_route(route_id, %{routes: routes} = state) do
    case fetch_route(routes, route_id) || fetch_route(routes, "default") ||
           fetch_route(routes, :default) do
      nil ->
        maybe_log_unknown_route(route_id, state, @fallback_bucket)

      bucket ->
        if Map.has_key?(routes, route_id) do
          {bucket, state}
        else
          maybe_log_unknown_route(route_id, state, bucket)
        end
    end
  end

  defp maybe_log_unknown_route(route_id, state, bucket) do
    if MapSet.member?(state.logged_unknown_routes, route_id) do
      {bucket, state}
    else
      Logger.warning("Using default rate limit bucket for unknown route #{inspect(route_id)}")

      {bucket,
       %{state | logged_unknown_routes: MapSet.put(state.logged_unknown_routes, route_id)}}
    end
  end

  defp fetch_route(routes, route_id) do
    direct_route(routes, route_id) || alternate_route(routes, route_id)
  end

  defp direct_route(routes, route_id), do: Map.get(routes, route_id)

  defp alternate_route(routes, route_id) when is_atom(route_id) do
    Map.get(routes, Atom.to_string(route_id))
  end

  defp alternate_route(routes, route_id) when is_binary(route_id) and route_id != "" do
    route_atom = String.to_existing_atom(route_id)
    Map.get(routes, route_atom)
  rescue
    ArgumentError -> nil
  end

  defp alternate_route(_routes, _route_id), do: nil

  defp normalize_routes(routes) when is_map(routes) do
    Map.new(routes, fn {route_id, config} -> {route_id, normalize_bucket!(config)} end)
  end

  defp normalize_bucket!(config) when is_map(config) do
    %{
      burst: fetch_bucket_value!(config, :burst),
      refill_per_sec: fetch_bucket_value!(config, :refill_per_sec)
    }
  end

  defp normalize_bucket!(_config),
    do: raise(ArgumentError, "rate limiter route config must be a map")

  defp fetch_bucket_value!(config, key) do
    string_key = Atom.to_string(key)

    case Map.fetch(config, key) do
      {:ok, value} -> value
      :error -> Map.fetch!(config, string_key)
    end
  end
end
