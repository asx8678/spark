defmodule Spark.Streaming.Pipeline do
  @moduledoc """
  Ephemeral pipeline that wires an SSEProducer to a ChunkConsumer via GenStage.

  Started per streaming request, stopped when the stream completes,
  errors, or times out. The pipeline is the entry point for the
  demand-driven streaming path — it starts both GenStage stages,
  subscribes the consumer to the producer, and manages lifecycle.

  ## Usage

      {:ok, pipeline} = Spark.Streaming.Pipeline.start_link(
        request: {url, body, headers, req_opts},
        consumer: {worker_pid, callback},
        caller: caller_pid,
        model: "deepseek-chat",
        api_key: "sk-..."
      )

      # Pipeline sends {:pipeline_done, result} to caller_pid when complete
      # ...

      Spark.Streaming.Pipeline.stop(pipeline)

  ## Architecture

      SSEProducer ──[GenStage demand]──▶ ChunkConsumer
           │                                      │
           │  (HTTP request in separate process)   │  (sends to worker_pid)
           ▼                                      ▼
      SSE chunks flow on demand            {:sse_chunk, data}
                                           {:sse_done, response}
                                           {:sse_error, reason}
  """

  use GenServer

  require Logger

  # --- Public API ---

  @doc """
  Starts the pipeline, wiring the SSEProducer and ChunkConsumer together.

  Options:
    - `:request` — `{url, body, headers, req_opts}` for the HTTP request
    - `:consumer` — `{worker_pid, callback}` for event relay
    - `:caller` — pid to notify with `{:pipeline_done, result}` on completion
    - `:model` — model name (for response metadata)
    - `:api_key` — API key (for error masking)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Gracefully stops the pipeline, cleaning up producer and consumer.
  """
  @spec stop(pid()) :: :ok
  def stop(pid) do
    GenServer.stop(pid, :normal)
  catch
    :exit, {:noproc, _} -> :ok
    :exit, {:shutdown, _} -> :ok
  end

  # --- GenServer callbacks ---

  @impl true
  def init(opts) do
    {url, body, headers, req_opts} = Keyword.fetch!(opts, :request)
    {worker_pid, callback} = Keyword.fetch!(opts, :consumer)
    caller_pid = Keyword.get(opts, :caller)
    model = Keyword.get(opts, :model, "unknown")
    api_key = Keyword.get(opts, :api_key, "")

    # Start the producer first — it won't begin the HTTP request
    # until demand arrives from the consumer.
    {:ok, producer} =
      Spark.Streaming.SSEProducer.start_link(
        {{url, body, headers, req_opts}, caller_pid: caller_pid, model: model, api_key: api_key}
      )

    # Start the consumer, subscribing to the producer.
    # sync_subscribe ensures the consumer is ready before the producer
    # dispatches any events.
    {:ok, consumer} =
      Spark.Streaming.ChunkConsumer.start_link({worker_pid, callback, producer})

    GenStage.sync_subscribe(consumer, to: producer, min_demand: 0, max_demand: 10)

    state = %{
      producer: producer,
      consumer: consumer
    }

    {:ok, state}
  end

  @impl true
  def terminate(_reason, state) do
    # Stop consumer first — it stops demanding, which pauses the producer.
    # Then stop the producer, which kills the HTTP process.
    safe_stop(state.consumer, "consumer")
    safe_stop(state.producer, "producer")
    :ok
  end

  # --- Private ---

  defp safe_stop(pid, label) do
    if is_pid(pid) and Process.alive?(pid) do
      try do
        GenStage.stop(pid)
      catch
        :exit, reason ->
          Logger.debug("Pipeline: #{label} stop exited: #{inspect(reason)}")
      end
    end
  end
end
