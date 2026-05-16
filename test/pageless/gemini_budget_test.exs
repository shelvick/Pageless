defmodule Pageless.GeminiBudgetTest do
  @moduledoc "Tests daily Gemini call budget behavior."

  use ExUnit.Case, async: true

  alias Pageless.GeminiBudget

  test "increments until cap and then refuses without growing the counter" do
    budget = start_supervised!({GeminiBudget, cap: 2, clock: fixed_clock(~D[2026-05-15])})

    assert GeminiBudget.current(budget) == 0
    assert GeminiBudget.cap(budget) == 2
    assert GeminiBudget.increment(budget) == :ok
    assert GeminiBudget.increment(budget) == :ok
    assert GeminiBudget.current(budget) == 2

    assert GeminiBudget.increment(budget) == {:error, :budget_exhausted}
    assert GeminiBudget.increment(budget) == {:error, :budget_exhausted}
    assert GeminiBudget.current(budget) == 2
  end

  test "rolls over lazily when the injected UTC date changes" do
    {:ok, agent} = Agent.start_link(fn -> ~D[2026-05-15] end)

    on_exit(fn ->
      if Process.alive?(agent), do: Agent.stop(agent, :normal, :infinity)
    end)

    budget = start_supervised!({GeminiBudget, cap: 1, clock: fn -> Agent.get(agent, & &1) end})

    assert GeminiBudget.increment(budget) == :ok
    assert GeminiBudget.increment(budget) == {:error, :budget_exhausted}

    Agent.update(agent, fn _date -> ~D[2026-05-16] end)

    assert GeminiBudget.current(budget) == 0
    assert GeminiBudget.increment(budget) == :ok
    assert GeminiBudget.current(budget) == 1
  end

  test "serializes concurrent increments at the configured cap" do
    budget = start_supervised!({GeminiBudget, cap: 50, clock: fixed_clock(~D[2026-05-15])})
    supervisor = start_supervised!(Task.Supervisor)

    results =
      supervisor
      |> Task.Supervisor.async_stream_nolink(
        1..100,
        fn _index -> GeminiBudget.increment(budget) end,
        max_concurrency: 100,
        timeout: 1_000,
        ordered: false
      )
      |> Enum.map(fn {:ok, result} -> result end)
      |> Enum.frequencies()

    assert results[:ok] == 50
    assert results[{:error, :budget_exhausted}] == 50
    assert GeminiBudget.current(budget) == 50
  end

  defp fixed_clock(date), do: fn -> date end
end
