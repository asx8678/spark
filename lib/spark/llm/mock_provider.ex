defmodule Spark.LLM.MockProvider do
  @moduledoc """
  Deterministic mock LLM provider for testing.

  Each test process gets its own response queue, so concurrent tests
  are isolated. Uses an ETS table keyed by pid.

  ## Usage

      Spark.LLM.MockProvider.set_responses(self(), [
        {:ok, %{id: "test-1", model: "mock", choices: [...], usage: %{...}}},
        {:error, :rate_limited}
      ])

      {:ok, resp} = Spark.LLM.MockProvider.complete(messages, %{})
      # First call returns the first response
      {:error, :rate_limited} = Spark.LLM.MockProvider.complete(messages, %{})
      # Second call returns the second
  """

  @behaviour Spark.LLM.Provider

  @table :spark_mock_provider_responses
  @default_response {:ok,
                     %{
                       id: "chatcmpl-mock",
                       model: "mock-model",
                       choices: [%{message: %{role: "assistant", content: "mock response"}}],
                       usage: %{prompt_tokens: 10, completion_tokens: 5, total_tokens: 15}
                     }}

  @default_stream_chunks [
    {:chunk, %{delta: %{content: "mock "}}},
    {:chunk, %{delta: %{content: "response"}}}
  ]

  # --- Public API ---

  @doc """
  Queues responses for the given process. Each call to `complete/2`
  pops the next response from the queue.
  """
  @spec set_responses(pid(), [{:ok, map()} | {:error, term()}]) :: :ok
  def set_responses(pid, responses) when is_pid(pid) and is_list(responses) do
    ensure_table()
    :ets.insert(@table, {pid, responses})
    :ok
  end

  @doc """
  Queues stream chunks for the given process. Each call to `stream/3`
  uses the queued chunks.
  """
  @spec set_stream_chunks(pid(), [{:chunk, map()} | {:done, map()}]) :: :ok
  def set_stream_chunks(pid, chunks) when is_pid(pid) and is_list(chunks) do
    ensure_table()
    :ets.insert(@table, {{:stream, pid}, chunks})
    :ok
  end

  @doc """
  Clears the queued responses for a process.
  """
  @spec clear(pid()) :: :ok
  def clear(pid) when is_pid(pid) do
    ensure_table()
    :ets.delete(@table, pid)
    :ets.delete(@table, {:stream, pid})
    :ok
  end

  @doc """
  Returns the current queue length for a process.
  """
  @spec queue_length(pid()) :: non_neg_integer()
  def queue_length(pid) when is_pid(pid) do
    ensure_table()

    case :ets.lookup(@table, pid) do
      [{^pid, responses}] -> length(responses)
      [] -> 0
    end
  end

  # --- Provider Behaviour ---

  @impl true
  @spec complete([map()], map()) :: {:ok, map()} | {:error, term()}
  def complete(_messages, opts) do
    caller = Map.get(opts, :mock_caller_pid, self())
    ensure_table()

    case :ets.lookup(@table, caller) do
      [{^caller, [response | rest]}] ->
        :ets.insert(@table, {caller, rest})
        response

      [{^caller, []}] ->
        # Queue exhausted, return default
        @default_response

      [] ->
        # No queue set, return default
        @default_response
    end
  end

  @impl true
  @spec stream([map()], map(), function()) :: {:ok, map()} | {:error, term()}
  def stream(_messages, opts, callback) do
    caller = Map.get(opts, :mock_caller_pid, self())
    ensure_table()

    chunks =
      case :ets.lookup(@table, {:stream, caller}) do
        [{_, chunks}] -> chunks
        [] -> @default_stream_chunks
      end

    # Send each chunk
    for chunk <- chunks do
      callback.(chunk)
    end

    # Final complete response — use the same caller so the orchestrator's
    # queued responses are consumed correctly
    final = complete([], %{mock_caller_pid: caller})
    callback.({:done, final})
    final
  end

  # --- Private ---

  defp ensure_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:set, :named_table, :public])
    end
  end
end
