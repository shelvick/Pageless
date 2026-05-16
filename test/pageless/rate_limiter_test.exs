defmodule Pageless.RateLimiterTest do
  @moduledoc "Tests per-route token bucket behavior for webhook rate limiting."

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  @routes %{
    "default" => %{"burst" => 3, "refill_per_sec" => 1},
    "webhook_alertmanager" => %{"burst" => 5, "refill_per_sec" => 5},
    :webhook_pagerduty => %{burst: 2, refill_per_sec: 2}
  }

  defp start_limiter(opts \\ []) do
    start_supervised!({Pageless.RateLimiter, Keyword.put_new(opts, :routes, @routes)})
  end

  defp table_for(pid), do: pid |> :sys.get_state() |> Map.fetch!(:table)

  defp bucket(pid, route_id, ip) do
    assert [{{^route_id, ^ip}, tokens_remaining, last_refill_us}] =
             :ets.lookup(table_for(pid), {route_id, ip})

    {tokens_remaining, last_refill_us}
  end

  describe "token bucket checks" do
    test "first call seeds an empty bucket and consumes one burst token" do
      limiter = start_limiter()

      assert :ok =
               Pageless.RateLimiter.check(limiter, "webhook_alertmanager", "10.0.0.1", now_us: 0)

      assert {4.0, 0} = bucket(limiter, "webhook_alertmanager", "10.0.0.1")
    end

    test "burst plus one immediate calls exhaust the bucket" do
      limiter =
        start_limiter(routes: %{"webhook_alertmanager" => %{"burst" => 3, "refill_per_sec" => 5}})

      results =
        for _ <- 1..4 do
          Pageless.RateLimiter.check(limiter, "webhook_alertmanager", "10.0.0.2", now_us: 0)
        end

      assert [:ok, :ok, :ok, {:error, :rate_limited, retry_after_ms}] = results
      assert retry_after_ms > 0
    end

    test "lazy refill adds tokens from elapsed monotonic time on demand" do
      limiter =
        start_limiter(routes: %{"webhook_alertmanager" => %{"burst" => 5, "refill_per_sec" => 5}})

      for _ <- 1..5 do
        assert :ok =
                 Pageless.RateLimiter.check(limiter, "webhook_alertmanager", "10.0.0.3",
                   now_us: 0
                 )
      end

      assert {:error, :rate_limited, _retry_after_ms} =
               Pageless.RateLimiter.check(limiter, "webhook_alertmanager", "10.0.0.3", now_us: 0)

      assert :ok =
               Pageless.RateLimiter.check(limiter, "webhook_alertmanager", "10.0.0.3",
                 now_us: 1_000_000
               )

      assert {4.0, 1_000_000} = bucket(limiter, "webhook_alertmanager", "10.0.0.3")
    end

    test "partial refill is captured after a rate-limited call without double counting" do
      limiter =
        start_limiter(routes: %{"webhook_alertmanager" => %{"burst" => 2, "refill_per_sec" => 5}})

      for _ <- 1..2 do
        assert :ok =
                 Pageless.RateLimiter.check(limiter, "webhook_alertmanager", "10.0.0.4",
                   now_us: 0
                 )
      end

      assert {:error, :rate_limited, _retry_after_ms} =
               Pageless.RateLimiter.check(limiter, "webhook_alertmanager", "10.0.0.4",
                 now_us: 100_000
               )

      assert {0.5, 100_000} = bucket(limiter, "webhook_alertmanager", "10.0.0.4")

      assert :ok =
               Pageless.RateLimiter.check(limiter, "webhook_alertmanager", "10.0.0.4",
                 now_us: 200_000
               )

      assert {tokens_remaining, 200_000} = bucket(limiter, "webhook_alertmanager", "10.0.0.4")
      assert tokens_remaining == 0.0
    end

    test "exhausting one route and IP does not affect other route/IP buckets" do
      limiter =
        start_limiter(
          routes: %{
            "route_alpha" => %{"burst" => 1, "refill_per_sec" => 1},
            "route_beta" => %{"burst" => 1, "refill_per_sec" => 1}
          }
        )

      assert :ok = Pageless.RateLimiter.check(limiter, "route_alpha", "10.0.0.5", now_us: 0)

      assert {:error, :rate_limited, _retry_after_ms} =
               Pageless.RateLimiter.check(limiter, "route_alpha", "10.0.0.5", now_us: 0)

      assert :ok = Pageless.RateLimiter.check(limiter, "route_alpha", "10.0.0.6", now_us: 0)
      assert :ok = Pageless.RateLimiter.check(limiter, "route_beta", "10.0.0.5", now_us: 0)
    end

    test "unknown route uses configured default and logs only once per route" do
      limiter = start_limiter(routes: %{"default" => %{"burst" => 1, "refill_per_sec" => 1}})

      log =
        capture_log(fn ->
          assert :ok = Pageless.RateLimiter.check(limiter, "unknown_route", "10.0.0.7", now_us: 0)

          assert {:error, :rate_limited, _retry_after_ms} =
                   Pageless.RateLimiter.check(limiter, "unknown_route", "10.0.0.7", now_us: 0)
        end)

      assert log =~ "unknown_route"
      assert length(Regex.scan(~r/unknown_route/, log)) == 1
    end

    test "unknown route without configured default uses hardcoded fallback" do
      limiter = start_limiter(routes: %{})

      log =
        capture_log(fn ->
          results =
            for _ <- 1..11 do
              Pageless.RateLimiter.check(limiter, "unconfigured", "10.0.0.8", now_us: 0)
            end

          assert Enum.count(results, &(&1 == :ok)) == 10
          assert [{:error, :rate_limited, retry_after_ms}] = Enum.reject(results, &(&1 == :ok))
          assert retry_after_ms > 0
        end)

      assert log =~ "unconfigured"
    end
  end

  test "concurrent callers serialize through the GenServer without over-allowing" do
    limiter =
      start_limiter(routes: %{"webhook_alertmanager" => %{"burst" => 17, "refill_per_sec" => 1}})

    results =
      1..100
      |> Enum.map(fn _ ->
        Task.async(fn ->
          Pageless.RateLimiter.check(limiter, "webhook_alertmanager", "10.0.0.9", now_us: 0)
        end)
      end)
      |> Task.await_many(5_000)

    assert Enum.count(results, &(&1 == :ok)) == 17

    assert Enum.count(
             results,
             &match?({:error, :rate_limited, retry_after_ms} when retry_after_ms > 0, &1)
           ) == 83
  end

  test "clock option supplies default time and now_us overrides only one call" do
    clock = fn -> 10_000 end

    limiter =
      start_limiter(
        routes: %{"webhook_alertmanager" => %{"burst" => 2, "refill_per_sec" => 1}},
        clock: clock
      )

    assert :ok = Pageless.RateLimiter.check(limiter, "webhook_alertmanager", "10.0.0.10")
    assert {_tokens, 10_000} = bucket(limiter, "webhook_alertmanager", "10.0.0.10")

    assert :ok =
             Pageless.RateLimiter.check(limiter, "webhook_alertmanager", "10.0.0.10",
               now_us: 20_000
             )

    assert {_tokens, 20_000} = bucket(limiter, "webhook_alertmanager", "10.0.0.10")
  end

  test "test instances start without a registered process name" do
    limiter = start_limiter()

    assert Process.info(limiter, :registered_name) == {:registered_name, []}
  end

  test "zero burst route returns deterministic ceiling retry" do
    limiter =
      start_limiter(routes: %{"webhook_alertmanager" => %{"burst" => 0, "refill_per_sec" => 1}})

    assert {:error, :rate_limited, 2_147_483_648} =
             Pageless.RateLimiter.check(limiter, "webhook_alertmanager", "10.0.0.11", now_us: 0)
  end

  test "zero refill route returns deterministic ceiling retry" do
    limiter =
      start_limiter(routes: %{"webhook_alertmanager" => %{"burst" => 1, "refill_per_sec" => 0}})

    assert :ok =
             Pageless.RateLimiter.check(limiter, "webhook_alertmanager", "10.0.0.12", now_us: 0)

    assert {:error, :rate_limited, 2_147_483_648} =
             Pageless.RateLimiter.check(limiter, "webhook_alertmanager", "10.0.0.12", now_us: 0)
  end
end
