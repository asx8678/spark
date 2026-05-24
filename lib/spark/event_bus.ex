defmodule Spark.EventBus do
  @moduledoc """
  Central event system for Spark runtime.

  Wraps Phoenix.PubSub behind a stable, typed API. All runtime events
  flow through here — Orchestrator, Dispatcher, Workers, CLI, Memory,
  ToolRunner, and HotReload.

  ## Topics

    - `spark:events` — global firehose
    - `spark:session:{session_id}` — session-scoped
    - `spark:plan:{plan_id}` — plan-scoped
    - `spark:task:{task_id}` — task-scoped
    - `spark:worker:{worker_id}` — worker-scoped
    - `spark:hot_reload` — hot reload events

  ## Rules

    - `publish/2` validates the event is a `%Spark.Types.Event{}`
    - Raw tuples are never part of the public API
    - Invalid events are rejected before hooks or subscribers fire
  """

  alias Spark.Types.Event

  @pubsub Spark.PubSub

  # --- Core API ---

  @doc """
  Subscribes the current process to a topic.
  """
  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(topic) when is_binary(topic) do
    Phoenix.PubSub.subscribe(@pubsub, topic)
  end

  @doc """
  Unsubscribes the current process from a topic.
  """
  @spec unsubscribe(String.t()) :: :ok | {:error, term()}
  def unsubscribe(topic) when is_binary(topic) do
    Phoenix.PubSub.unsubscribe(@pubsub, topic)
  end

  @doc """
  Publishes a validated `Spark.Types.Event` to a topic.

  Returns `:ok` on success, `{:error, reason}` if the event is invalid.
  Hooks and subscribers only receive events that pass validation.
  """
  @spec publish(String.t(), Event.t()) :: :ok | {:error, term()}
  def publish(topic, %Event{} = event) when is_binary(topic) do
    case Event.validate(event) do
      :ok ->
        run_hooks(event)
        Phoenix.PubSub.broadcast(@pubsub, topic, event)
        :ok

      {:error, reason} ->
        {:error, {:invalid_event, reason}}
    end
  end

  @spec publish(String.t(), term()) :: {:error, :not_an_event}
  def publish(_topic, _not_event) do
    {:error, :not_an_event}
  end

  @doc """
  Builds an event via `Spark.Types.Event.new/3` and publishes it.

  Returns `:ok` on success, `{:error, reason}` on failure.
  """
  @spec publish_event(atom(), map(), keyword()) :: :ok | {:error, term()}
  def publish_event(type, payload, opts \\ []) when is_atom(type) and is_map(payload) do
    event = Event.new(type, payload, opts)
    topic = event.topic
    publish(topic, event)
  end

  # --- Convenience Wrappers ---

  @doc """
  Publishes a session-scoped event.
  """
  @spec publish_session(String.t(), atom(), map(), keyword()) :: :ok | {:error, term()}
  def publish_session(session_id, type, payload, opts \\ []) do
    opts =
      Keyword.merge(opts,
        topic: "spark:session:#{session_id}",
        session_id: session_id,
        source: Keyword.get(opts, :source, :session)
      )

    publish_event(type, payload, opts)
  end

  @doc """
  Publishes a plan-scoped event.
  """
  @spec publish_plan(String.t(), atom(), map(), keyword()) :: :ok | {:error, term()}
  def publish_plan(plan_id, type, payload, opts \\ []) do
    opts =
      Keyword.merge(opts,
        topic: "spark:plan:#{plan_id}",
        plan_id: plan_id,
        source: Keyword.get(opts, :source, :orchestrator)
      )

    publish_event(type, payload, opts)
  end

  @doc """
  Publishes a task-scoped event.
  """
  @spec publish_task(String.t(), atom(), map(), keyword()) :: :ok | {:error, term()}
  def publish_task(task_id, type, payload, opts \\ []) do
    opts =
      Keyword.merge(opts,
        topic: "spark:task:#{task_id}",
        task_id: task_id,
        source: Keyword.get(opts, :source, :dispatcher)
      )

    publish_event(type, payload, opts)
  end

  @doc """
  Publishes a worker-scoped event.
  """
  @spec publish_worker(String.t(), atom(), map(), keyword()) :: :ok | {:error, term()}
  def publish_worker(worker_id, type, payload, opts \\ []) do
    opts =
      Keyword.merge(opts,
        topic: "spark:worker:#{worker_id}",
        source: Keyword.get(opts, :source, :worker)
      )

    publish_event(type, payload, opts)
  end

  @doc """
  Publishes a hot reload event.
  """
  @spec publish_hot_reload(atom(), map(), keyword()) :: :ok | {:error, term()}
  def publish_hot_reload(type, payload, opts \\ []) do
    opts =
      Keyword.merge(opts,
        topic: "spark:hot_reload",
        source: Keyword.get(opts, :source, :hot_reload)
      )

    publish_event(type, payload, opts)
  end

  # --- Hook System (spark-bny.3) ---

  @doc """
  Adds a named hook function that receives every published event.
  Hooks run synchronously in the publishing process — keep them fast.
  """
  @spec add_hook(atom(), (Event.t() -> any())) :: :ok
  def add_hook(hook_name, function) when is_atom(hook_name) and is_function(function, 1) do
    hooks = get_hooks()

    if Map.has_key?(hooks, hook_name) do
      :ok
    else
      put_hooks(Map.put(hooks, hook_name, function))
    end

    :ok
  end

  @doc """
  Removes a named hook.
  """
  @spec remove_hook(atom()) :: :ok
  def remove_hook(hook_name) when is_atom(hook_name) do
    hooks = get_hooks()
    put_hooks(Map.delete(hooks, hook_name))
    :ok
  end

  @doc """
  Lists all registered hook names.
  """
  @spec hooks() :: [atom()]
  def hooks do
    get_hooks() |> Map.keys()
  end

  @doc """
  Clears all hooks. Useful for test cleanup.
  """
  @spec clear_hooks() :: :ok
  def clear_hooks do
    put_hooks(%{})
    :ok
  end

  # --- Normalization (spark-bny.2) ---

  @doc """
  Normalizes a raw map or tuple into a `Spark.Types.Event`.

  Accepts:
    - `%Spark.Types.Event{}` — returned as-is
    - `%{type: atom, payload: map, ...}` — converted via `Event.new/3`
    - `{type, payload}` — converted with defaults
    - `{type, payload, opts}` — converted with opts

  Returns `{:ok, event}` or `{:error, reason}`.
  """
  @spec normalize(Event.t() | map() | tuple()) :: {:ok, Event.t()} | {:error, term()}
  def normalize(%Event{} = event), do: {:ok, event}

  def normalize(%{type: type, payload: payload} = map) when is_atom(type) and is_map(payload) do
    opts =
      [:topic, :source, :session_id, :plan_id, :task_id, :source_id]
      |> Enum.flat_map(fn key ->
        case Map.get(map, key) do
          nil -> []
          val -> [{key, val}]
        end
      end)

    {:ok, Event.new(type, payload, opts)}
  end

  def normalize({type, payload}) when is_atom(type) and is_map(payload) do
    {:ok, Event.new(type, payload)}
  end

  def normalize({type, payload, opts}) when is_atom(type) and is_map(payload) and is_list(opts) do
    {:ok, Event.new(type, payload, opts)}
  end

  @spec normalize(term()) :: {:error, :cannot_normalize}
  def normalize(_), do: {:error, :cannot_normalize}

  @doc """
  Broadcasts a normalized event. Alias for `publish/2` that normalizes first.
  Validates the resulting struct before publishing.
  """
  @spec broadcast(String.t(), Event.t() | map() | tuple()) :: :ok | {:error, term()}
  def broadcast(topic, raw_event) when is_binary(topic) do
    case normalize(raw_event) do
      {:ok, event} -> publish(topic, event)
      {:error, reason} -> {:error, {:normalization_failed, reason}}
    end
  end

  # --- Private helpers ---

  defp get_hooks do
    case :ets.whereis(:spark_event_bus_hooks) do
      :undefined ->
        %{}

      tid ->
        try do
          case :ets.lookup(tid, :hooks) do
            [{:hooks, hooks}] -> hooks
            [] -> %{}
          end
        rescue
          _ -> %{}
        end
    end
  end

  defp put_hooks(hooks) do
    tid = ensure_hooks_table()
    :ets.insert(tid, {:hooks, hooks})
  end

  defp ensure_hooks_table do
    case :ets.whereis(:spark_event_bus_hooks) do
      :undefined ->
        :ets.new(:spark_event_bus_hooks, [:set, :named_table, :public])

      tid ->
        tid
    end
  end

  defp run_hooks(event) do
    hooks = get_hooks()

    Enum.each(hooks, fn {_name, fun} ->
      try do
        fun.(event)
      rescue
        e ->
          require Logger
          Logger.warning("EventBus hook error: #{inspect(e)}")
      end
    end)
  end
end
