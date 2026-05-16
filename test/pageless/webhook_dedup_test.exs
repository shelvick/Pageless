defmodule Pageless.WebhookDedupTest do
  @moduledoc "Tests envelope fingerprint deduplication for webhook intake."

  use ExUnit.Case, async: true

  alias Pageless.AlertEnvelope

  defp start_clock(initial_us) do
    start_supervised!({Agent, fn -> initial_us end})
  end

  defp clock_fun(clock), do: fn -> Agent.get(clock, & &1) end

  defp set_clock(clock, now_us), do: Agent.update(clock, fn _ -> now_us end)

  defp start_dedup(opts \\ []) do
    start_supervised!(
      {Pageless.WebhookDedup, Keyword.merge([window_ms: 100, prune_interval_ms: 50], opts)}
    )
  end

  defp table_for(pid), do: pid |> :sys.get_state() |> Map.fetch!(:table)

  defp envelope(attrs \\ []) do
    struct!(
      AlertEnvelope,
      Keyword.merge(
        [
          alert_id: "alert-1",
          source: :alertmanager,
          source_ref: "am/ref/1",
          fingerprint: "fingerprint-1",
          received_at: ~U[2026-05-14 00:00:00Z],
          status: :firing,
          severity: :critical,
          alert_class: :service_down_with_recent_deploy,
          title: "Payments API down",
          payload_raw: %{}
        ],
        attrs
      )
    )
  end

  describe "check_or_record/3" do
    test "first sighting records the envelope key and returns ok" do
      clock = start_clock(0)
      dedup = start_dedup(clock: clock_fun(clock))

      assert :ok = Pageless.WebhookDedup.check_or_record(dedup, :alertmanager, envelope())
      assert :ets.info(table_for(dedup), :size) == 1
    end

    test "duplicate within the window returns age without extending last_seen" do
      clock = start_clock(0)
      dedup = start_dedup(clock: clock_fun(clock), window_ms: 100)

      assert :ok = Pageless.WebhookDedup.check_or_record(dedup, :alertmanager, envelope())

      set_clock(clock, 10_000)

      assert {:duplicate, 10} =
               Pageless.WebhookDedup.check_or_record(dedup, :alertmanager, envelope())

      set_clock(clock, 20_000)

      assert {:duplicate, 20} =
               Pageless.WebhookDedup.check_or_record(dedup, :alertmanager, envelope())

      set_clock(clock, 99_000)

      assert {:duplicate, 99} =
               Pageless.WebhookDedup.check_or_record(dedup, :alertmanager, envelope())

      set_clock(clock, 101_000)
      assert :ok = Pageless.WebhookDedup.check_or_record(dedup, :alertmanager, envelope())
    end

    test "stale entry refreshes the stored timestamp" do
      clock = start_clock(0)
      dedup = start_dedup(clock: clock_fun(clock), window_ms: 100)

      assert :ok = Pageless.WebhookDedup.check_or_record(dedup, :alertmanager, envelope())

      set_clock(clock, 101_000)
      assert :ok = Pageless.WebhookDedup.check_or_record(dedup, :alertmanager, envelope())

      key = {:alertmanager, "fingerprint-1", :firing}
      assert [{^key, 101_000}] = :ets.lookup(table_for(dedup), key)
    end

    test "status and source are part of the dedup key" do
      clock = start_clock(0)
      dedup = start_dedup(clock: clock_fun(clock))

      assert :ok =
               Pageless.WebhookDedup.check_or_record(
                 dedup,
                 :alertmanager,
                 envelope(status: :firing)
               )

      assert :ok =
               Pageless.WebhookDedup.check_or_record(
                 dedup,
                 :alertmanager,
                 envelope(status: :resolved)
               )

      assert {:duplicate, 0} =
               Pageless.WebhookDedup.check_or_record(
                 dedup,
                 :alertmanager,
                 envelope(status: :firing)
               )

      assert :ok =
               Pageless.WebhookDedup.check_or_record(dedup, :pagerduty, envelope(status: :firing))

      assert :ets.info(table_for(dedup), :size) == 3
    end

    test "accepts AlertEnvelope structs and maps as the same dedup input" do
      clock = start_clock(0)
      dedup = start_dedup(clock: clock_fun(clock))

      assert :ok = Pageless.WebhookDedup.check_or_record(dedup, :alertmanager, envelope())

      assert {:duplicate, 0} =
               Pageless.WebhookDedup.check_or_record(dedup, :alertmanager, %{
                 fingerprint: "fingerprint-1",
                 status: :firing
               })
    end
  end

  describe "manual prune" do
    test "removes stale rows and keeps fresh rows" do
      clock = start_clock(0)
      dedup = start_dedup(clock: clock_fun(clock), window_ms: 100)

      assert :ok =
               Pageless.WebhookDedup.check_or_record(
                 dedup,
                 :alertmanager,
                 envelope(fingerprint: "stale")
               )

      set_clock(clock, 75_000)

      assert :ok =
               Pageless.WebhookDedup.check_or_record(
                 dedup,
                 :alertmanager,
                 envelope(fingerprint: "fresh")
               )

      set_clock(clock, 150_001)
      send(dedup, :prune)
      table = table_for(dedup)

      assert :ets.lookup(table, {:alertmanager, "stale", :firing}) == []

      assert [{{:alertmanager, "fresh", :firing}, 75_000}] =
               :ets.lookup(table, {:alertmanager, "fresh", :firing})
    end

    test "removes all stale rows" do
      clock = start_clock(0)
      dedup = start_dedup(clock: clock_fun(clock), window_ms: 100)

      for index <- 1..3 do
        assert :ok =
                 Pageless.WebhookDedup.check_or_record(
                   dedup,
                   :alertmanager,
                   envelope(fingerprint: "old-#{index}")
                 )
      end

      set_clock(clock, 200_000)
      send(dedup, :prune)
      table = table_for(dedup)

      assert :ets.info(table, :size) == 0
    end

    test "stores a fresh timer reference after prune re-arms itself" do
      clock = start_clock(0)
      dedup = start_dedup(clock: clock_fun(clock), window_ms: 100, prune_interval_ms: 1_000)

      first_timer_ref = dedup |> :sys.get_state() |> Map.fetch!(:timer_ref)
      assert is_reference(first_timer_ref)

      send(dedup, :prune)

      second_timer_ref = dedup |> :sys.get_state() |> Map.fetch!(:timer_ref)
      assert is_reference(second_timer_ref)
      refute second_timer_ref == first_timer_ref
      assert is_integer(:erlang.read_timer(second_timer_ref))
    end
  end

  test "concurrent callers record exactly one first sighting" do
    clock = start_clock(0)
    dedup = start_dedup(clock: clock_fun(clock))

    results =
      1..100
      |> Enum.map(fn _ ->
        Task.async(fn ->
          Pageless.WebhookDedup.check_or_record(dedup, :alertmanager, envelope())
        end)
      end)
      |> Task.await_many(5_000)

    assert Enum.count(results, &(&1 == :ok)) == 1
    assert Enum.count(results, &match?({:duplicate, age_ms} when age_ms >= 0, &1)) == 99
  end

  test "test instances start without a registered process name" do
    dedup = start_dedup()

    assert Process.info(dedup, :registered_name) == {:registered_name, []}
  end
end
