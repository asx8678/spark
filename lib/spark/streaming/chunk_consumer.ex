defmodule Spark.Streaming.ChunkConsumer do
  @moduledoc """
  GenStage consumer that relays SSE events from the producer to a Worker process.

  For each event received from the SSEProducer, this consumer:
    1. Calls the original callback (backward compatibility)
    2. Sends a message to the `worker_pid` for GenStage-native handling

  The consumer only receives events when it has demand capacity, providing
  natural backpressure between the SSE stream and the Worker.

  ## Worker messages

    - `{:sse_chunk, %{delta: %{content: content}}}` — content delta
    - `{:sse_done, response}` — stream completed with final response
    - `{:sse_error, reason}` — an error occurred

  ## Callback format

  The callback is invoked with the same events as the original
  `WaferProvider.stream/3` callback:
    - `{:chunk, %{delta: %{content: content}}}`
    - `{:done, {:ok, response}}`
  """

  use GenStage

  require Logger

  # --- Public API ---

  @doc """
  Starts the chunk consumer linked to the calling process.

  Expects `{worker_pid, callback, producer}` where:
    - `worker_pid` — the Worker process to relay events to
    - `callback` — the original streaming callback (1-arity function)
    - `producer` — the GenStage producer pid or name to subscribe to
  """
  @spec start_link({pid(), function(), GenStage.stage()}) :: GenServer.on_start()
  def start_link({worker_pid, callback, producer}) do
    GenStage.start_link(__MODULE__, {worker_pid, callback, producer})
  end

  # --- GenStage callbacks ---

  @impl true
  def init({worker_pid, callback, producer}) do
    state = %{
      worker_pid: worker_pid,
      callback: callback
    }

    # Subscribe to the producer with demand settings that provide
    # reasonable batching without overwhelming the Worker mailbox.
    {:consumer, state, subscribe_to: [{producer, min_demand: 0, max_demand: 10}]}
  end

  @impl true
  def handle_events(events, _from, state) do
    for event <- events do
      relay_event(event, state)
    end

    {:noreply, [], state}
  end

  # --- Private ---

  defp relay_event({:chunk, data} = event, state) do
    # Backward compat: call the original callback
    safe_callback(state.callback, event)
    # GenStage-native: send to Worker
    send(state.worker_pid, {:sse_chunk, data})
  end

  defp relay_event({:done, {:ok, response}} = event, state) do
    safe_callback(state.callback, event)
    send(state.worker_pid, {:sse_done, response})
  end

  defp relay_event({:error, reason}, state) do
    # Error events don't have a standard callback format,
    # but we still notify the Worker
    send(state.worker_pid, {:sse_error, reason})
  end

  defp relay_event(event, state) do
    # Unknown event type — best-effort callback, log a warning
    Logger.warning("ChunkConsumer received unknown event: #{inspect(event)}")
    safe_callback(state.callback, event)
  end

  defp safe_callback(callback, event) do
    try do
      callback.(event)
    rescue
      e ->
        Logger.warning("ChunkConsumer callback error: #{Exception.message(e)}")
    end
  end
end
