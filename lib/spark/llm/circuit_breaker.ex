defmodule Spark.LLM.CircuitBreaker do
  @moduledoc """
  Circuit breaker for LLM provider protection.

  Tracks failures per provider key (atom, e.g. `:wafer`). After
  3 consecutive failures within a 60-second window, the circuit
  opens for 30 seconds. After the cooldown, one "half-open" probe
  is allowed. If the probe succeeds, the circuit closes; if it
  fails, the circuit re-opens for another 30 seconds.

  State is stored in an ETS table (`:spark_circuit_breakers`) for
  fast concurrent reads. The table is owned by a lightweight GenServer
  started via `start_link/1`.

  Fails open: if the ETS table doesn't exist, all calls are allowed.
  """

  use GenServer

  require Logger

  @table :spark_circuit_breakers
  @failure_threshold 3
  @failure_window_ms 60_000
  @open_duration_ms 30_000

  # Row shape: {provider, state, failure_timestamps, opened_at}
  #   state            :: :closed | :open | :half_open
  #   failure_timestamps :: [monotonic_ms]
  #   opened_at        :: monotonic_ms | nil

  # --- Client API ---

  @doc """
  Starts the circuit breaker GenServer that owns the ETS table.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Records a successful call. Closes the circuit if it was half-open.
  Resets the failure count for a closed circuit.
  """
  @spec success(atom()) :: :ok
  def success(provider) when is_atom(provider) do
    # Self-check guard: Process.whereis(__MODULE__) is correct for named
    # singletons (not session-scoped). (spark-ard.19)
    if not table_exists?() or Process.whereis(__MODULE__) == nil do
      :ok
    else
      GenServer.call(__MODULE__, {:success, provider})
    end
  end

  @doc """
  Records a failure. May open the circuit if the failure threshold
  is reached within the rolling window.
  """
  @spec failure(atom()) :: :ok
  def failure(provider) when is_atom(provider) do
    # Self-check guard: Process.whereis(__MODULE__) is correct for named
    # singletons (not session-scoped). (spark-ard.19)
    if not table_exists?() or Process.whereis(__MODULE__) == nil do
      :ok
    else
      GenServer.call(__MODULE__, {:failure, provider})
    end
  end

  @doc """
  Checks whether a call should proceed.

  Returns `true` if the circuit is closed or a half-open probe is
  allowed. Returns `{:error, :circuit_open, remaining_seconds}` if
  the call should be rejected.
  """
  @spec allow?(atom()) :: true | {:error, :circuit_open, non_neg_integer()}
  def allow?(provider) when is_atom(provider) do
    # Self-check guard: Process.whereis(__MODULE__) is correct for named
    # singletons (not session-scoped). (spark-ard.19)
    if not table_exists?() or Process.whereis(__MODULE__) == nil do
      true
    else
      GenServer.call(__MODULE__, {:allow?, provider})
    end
  end

  # --- GenServer callbacks ---

  @impl true
  def init(_opts) do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [
        :set,
        :public,
        :named_table,
        {:read_concurrency, true}
      ])
    end

    {:ok, %{}}
  end

  @impl true
  def handle_call({:success, provider}, _from, state) do
    if table_exists?() do
      case :ets.lookup(@table, provider) do
        [{^provider, :half_open, _failures, _opened_at}] ->
          :ets.insert(@table, {provider, :closed, [], nil})
          Logger.info("Circuit breaker for #{provider}: CLOSED (probe succeeded)")

        [{^provider, :closed, _failures, _opened_at}] ->
          :ets.insert(@table, {provider, :closed, [], nil})

        [{^provider, :open, _failures, _opened_at}] ->
          :ok

        [] ->
          :ets.insert(@table, {provider, :closed, [], nil})
      end
    end

    {:reply, :ok, state}
  end

  def handle_call({:failure, provider}, _from, state) do
    if table_exists?() do
      now = System.monotonic_time(:millisecond)

      case :ets.lookup(@table, provider) do
        [{^provider, :half_open, _failures, _opened_at}] ->
          :ets.insert(@table, {provider, :open, [now], now})
          Logger.warning("Circuit breaker for #{provider}: RE-OPENED (probe failed)")

        [{^provider, :open, _failures, _opened_at}] ->
          :ets.insert(@table, {provider, :open, [now], now})

        [{^provider, :closed, failures, _opened_at}] ->
          windowed = filter_recent(failures, now)
          new_failures = [now | windowed]

          if length(new_failures) >= @failure_threshold do
            :ets.insert(@table, {provider, :open, new_failures, now})

            Logger.warning(
              "Circuit breaker for #{provider}: OPENED " <>
                "(#{length(new_failures)} failures in window)"
            )
          else
            :ets.insert(@table, {provider, :closed, new_failures, nil})
          end

        [] ->
          :ets.insert(@table, {provider, :closed, [now], nil})
      end
    end

    {:reply, :ok, state}
  end

  def handle_call({:allow?, provider}, _from, state) do
    if not table_exists?() do
      {:reply, true, state}
    else
      now = System.monotonic_time(:millisecond)

      reply =
        case :ets.lookup(@table, provider) do
          [{^provider, :closed, _failures, _opened_at}] ->
            true

          [{^provider, :open, failures, opened_at}] ->
            elapsed = now - opened_at

            if elapsed >= @open_duration_ms do
              :ets.insert(@table, {provider, :half_open, failures, opened_at})
              Logger.info("Circuit breaker for #{provider}: HALF-OPEN (probe allowed)")
              true
            else
              remaining = div(@open_duration_ms - elapsed, 1000) + 1
              {:error, :circuit_open, remaining}
            end

          [{^provider, :half_open, _failures, _opened_at}] ->
            # Only one probe allowed in half-open; block additional calls
            {:error, :circuit_open, 1}

          [] ->
            true
        end

      {:reply, reply, state}
    end
  end

  # --- Private ---

  defp table_exists? do
    :ets.whereis(@table) != :undefined
  end

  defp filter_recent(failures, now) do
    cutoff = now - @failure_window_ms
    Enum.filter(failures, fn ts -> ts > cutoff end)
  end
end
