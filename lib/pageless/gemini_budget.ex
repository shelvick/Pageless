defmodule Pageless.GeminiBudget do
  @moduledoc """
  Per-UTC-day Gemini call budget backed by a process-owned ETS table.

  Mutations are serialized through the GenServer so concurrent alert paths cannot
  overshoot the configured daily cap.
  """

  use GenServer

  @type opts :: [cap: non_neg_integer(), name: GenServer.name(), clock: (-> Date.t())]

  @doc "Starts a daily Gemini budget process."
  @spec start_link(opts()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {genserver_opts, init_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, init_opts, genserver_opts)
  end

  @doc "Claims one Gemini call from today's budget."
  @spec increment(pid() | GenServer.name()) :: :ok | {:error, :budget_exhausted}
  def increment(server), do: GenServer.call(server, :increment)

  @doc "Returns today's current Gemini call count."
  @spec current(pid() | GenServer.name()) :: non_neg_integer()
  def current(server), do: GenServer.call(server, :current)

  @doc "Returns the configured daily Gemini call cap."
  @spec cap(pid() | GenServer.name()) :: non_neg_integer()
  def cap(server), do: GenServer.call(server, :cap)

  @impl true
  def init(opts) do
    state = %{
      table: :ets.new(:pageless_gemini_budget, [:set, :public, {:read_concurrency, true}]),
      cap:
        Keyword.get_lazy(opts, :cap, fn ->
          Application.get_env(:pageless, :gemini_daily_call_cap, 5_000)
        end),
      clock: Keyword.get(opts, :clock, fn -> Date.utc_today() end)
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:increment, _from, state) do
    today = state.clock.()
    {row_date, counter} = current_row(state.table, today)

    cond do
      today != row_date ->
        :ets.insert(state.table, {:today, {today, 1}})
        {:reply, :ok, state}

      counter >= state.cap ->
        {:reply, {:error, :budget_exhausted}, state}

      true ->
        :ets.insert(state.table, {:today, {today, counter + 1}})
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call(:current, _from, state) do
    today = state.clock.()
    {row_date, counter} = current_row(state.table, today)
    reply = if today == row_date, do: counter, else: 0

    {:reply, reply, state}
  end

  @impl true
  def handle_call(:cap, _from, state), do: {:reply, state.cap, state}

  defp current_row(table, default_date) do
    case :ets.lookup(table, :today) do
      [{:today, {date, counter}}] -> {date, counter}
      [] -> {default_date, 0}
    end
  end
end
