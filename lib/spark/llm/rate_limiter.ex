defmodule Spark.LLM.RateLimiter do
  @moduledoc """
  Token-bucket rate limiter for LLM provider protection.

  50 tokens burst capacity with 10 tokens/second refill rate,
  keyed per provider. ETS-backed for fast concurrent access.

  The table is owned by a lightweight GenServer started via
  `start_link/1`.

  Fails open: if the ETS table doesn't exist, all calls are allowed.
  """

  use GenServer

  @table :spark_rate_limiters
  @burst_capacity 50
  @refill_rate_per_sec 10

  # Row shape: {provider, tokens, last_refill_ms}
  #   tokens        :: non_neg_integer()
  #   last_refill_ms :: monotonic_milliseconds

  # --- Client API ---

  @doc """
  Starts the rate limiter GenServer that owns the ETS table.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Attempts to acquire one token for the given provider.

  Returns `:ok` if a token was available, or
  `{:error, :rate_limited, retry_after_ms}` if the bucket is empty.
  """
  @spec acquire(atom()) :: :ok | {:error, :rate_limited, non_neg_integer()}
  def acquire(provider) when is_atom(provider) do
    # Self-check guard: Process.whereis(__MODULE__) is correct for named
    # singletons (not session-scoped). (spark-ard.19)
    if not table_exists?() or Process.whereis(__MODULE__) == nil do
      :ok
    else
      GenServer.call(__MODULE__, {:acquire, provider})
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
  def handle_call({:acquire, provider}, _from, state) do
    if not table_exists?() do
      {:reply, :ok, state}
    else
      now = System.monotonic_time(:millisecond)

      reply =
        case :ets.lookup(@table, provider) do
          [{^provider, tokens, last_refill}] ->
            elapsed_ms = now - last_refill
            refill = div(elapsed_ms * @refill_rate_per_sec, 1000)
            new_tokens = min(tokens + refill, @burst_capacity)
            new_last_refill = if refill > 0, do: now, else: last_refill

            if new_tokens >= 1 do
              :ets.insert(@table, {provider, new_tokens - 1, new_last_refill})
              :ok
            else
              # Time until 1 token refills
              retry_after_ms = div(1000, @refill_rate_per_sec)
              {:error, :rate_limited, retry_after_ms}
            end

          [] ->
            # First call — start with a full bucket minus one
            :ets.insert(@table, {provider, @burst_capacity - 1, now})
            :ok
        end

      {:reply, reply, state}
    end
  end

  # --- Private ---

  defp table_exists? do
    :ets.whereis(@table) != :undefined
  end
end
