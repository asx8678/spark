defmodule Spark.Dispatcher.State do
  @moduledoc """
  State management for the Dispatcher concurrent task queue.

  Pure data structure with no GenServer dependency.
  """

  alias Spark.Types.Task

  defstruct [
    queue: :queue.new(),
    active_workers: %{},
    completed_tasks: MapSet.new(),
    failed_tasks: %{},
    max_concurrency: 3,
    paused?: false,
    session_id: nil,
    plan_id: nil,
    worker_module: Spark.FakeWorker,
    schema_version: 1
  ]

  @type t :: %__MODULE__{}

  @doc "Creates a new Dispatcher.State, reading config from Spark.Config."
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    max_concurrency =
      Keyword.get(opts, :max_concurrency, nil) ||
        Spark.Config.get([:dispatcher, :max_concurrency], 3)

    %__MODULE__{
      max_concurrency: max_concurrency,
      session_id: Keyword.get(opts, :session_id),
      plan_id: Keyword.get(opts, :plan_id),
      worker_module: Keyword.get(opts, :worker_module, Spark.FakeWorker)
    }
  end

  @doc "Enqueues tasks. Validates each. Returns {:ok, state} or {:error, invalid_tasks}."
  @spec enqueue(t(), [Task.t()]) :: {:ok, t()} | {:error, [Task.t()]}
  def enqueue(state, tasks) when is_list(tasks) do
    {valid, invalid} =
      Enum.split_with(tasks, fn task ->
        case Task.validate(task) do :ok -> true; {:error, _} -> false end
      end)

    new_queue = Enum.reduce(valid, state.queue, &:queue.in(&1, &2))
    new_state = %{state | queue: new_queue}

    if invalid == [], do: {:ok, new_state}, else: {:error, invalid}
  end

  @doc "Dequeues up to n ready tasks (deps met, no write conflicts)."
  @spec dequeue(t(), pos_integer()) :: {[Task.t()], t()}
  def dequeue(state, n) when is_integer(n) and n > 0 do
    dequeue_loop(state, n, [])
  end

  defp dequeue_loop(state, 0, acc), do: {Enum.reverse(acc), state}

  defp dequeue_loop(state, remaining, acc) do
    case next_ready_task(state, acc) do
      nil ->
        {Enum.reverse(acc), state}

      task ->
        new_queue = remove_from_queue(state.queue, task.id)
        new_state = %{state | queue: new_queue}
        dequeue_loop(new_state, remaining - 1, [task | acc])
    end
  end

  defp next_ready_task(state, already_selected) do
    completed_ids = completed_and_selected_ids(state, already_selected)
    active_writes = active_write_paths(state)
    items = :queue.to_list(state.queue)

    Enum.find(items, fn task ->
      Task.ready?(task, completed_ids) and
        not has_write_conflict?(task, active_writes)
    end)
  end

  defp completed_and_selected_ids(state, already_selected) do
    selected = Enum.map(already_selected, & &1.id)
    MapSet.union(state.completed_tasks, MapSet.new(selected)) |> MapSet.to_list()
  end

  defp active_write_paths(state) do
    state.active_workers
    |> Map.values()
    |> Enum.flat_map(fn %{task: task} -> task.write_paths end)
  end

  defp has_write_conflict?(task, active_writes) do
    Enum.any?(task.write_paths, &(&1 in active_writes))
  end

  defp remove_from_queue(queue, task_id) do
    items = :queue.to_list(queue)
    filtered = Enum.reject(items, &(&1.id == task_id))
    :queue.from_list(filtered)
  end

  @doc "Pulls the next task whose deps are all in completed_ids. Returns {task, state} or :empty."
  @spec next_ready(t(), [String.t()]) :: {Task.t(), t()} | :empty
  def next_ready(state, completed_ids) when is_list(completed_ids) do
    case Enum.find(:queue.to_list(state.queue), &Task.ready?(&1, completed_ids)) do
      nil -> :empty
      task -> {task, %{state | queue: remove_from_queue(state.queue, task.id)}}
    end
  end

  @doc "Returns all ready tasks (deps met, no write conflicts)."
  @spec ready_tasks(t()) :: [Task.t()]
  def ready_tasks(state) do
    completed_ids = MapSet.to_list(state.completed_tasks)
    active_writes = active_write_paths(state)

    :queue.to_list(state.queue)
    |> Enum.filter(fn task ->
      Task.ready?(task, completed_ids) and
        not has_write_conflict?(task, active_writes)
    end)
  end

  @doc "Number of currently active workers."
  @spec active_count(t()) :: non_neg_integer()
  def active_count(state), do: map_size(state.active_workers)

  @doc "Adds a worker to the active map. worker_info: %{pid, monitor_ref, worker_id, started_at, task}"
  @spec add_active(t(), String.t(), map()) :: t()
  def add_active(state, task_id, worker_info), do: %{state | active_workers: Map.put(state.active_workers, task_id, worker_info)}

  @doc "Removes a worker from the active map."
  @spec remove_active(t(), String.t()) :: t()
  def remove_active(state, task_id), do: %{state | active_workers: Map.delete(state.active_workers, task_id)}

  @doc "Marks a task as completed."
  @spec mark_completed(t(), String.t()) :: t()
  def mark_completed(state, task_id), do: %{state | completed_tasks: MapSet.put(state.completed_tasks, task_id)}

  @doc "Marks a task as failed with failure info."
  @spec mark_failed(t(), String.t(), map()) :: t()
  def mark_failed(state, task_id, failure_info), do: %{state | failed_tasks: Map.put(state.failed_tasks, task_id, failure_info)}

  @doc "Pauses the dispatcher."
  @spec pause(t()) :: t()
  def pause(state), do: %{state | paused?: true}

  @doc "Resumes the dispatcher."
  @spec resume(t()) :: t()
  def resume(state), do: %{state | paused?: false}

  @doc "True if the dispatcher can spawn more workers."
  @spec can_spawn?(t()) :: boolean()
  def can_spawn?(state), do: not state.paused? and active_count(state) < state.max_concurrency

  @doc "Returns a status map for status queries."
  @spec status_map(t()) :: map()
  def status_map(state) do
    %{
      active_count: active_count(state),
      max_concurrency: state.max_concurrency,
      paused?: state.paused?,
      queue_length: :queue.len(state.queue),
      completed_count: MapSet.size(state.completed_tasks),
      failed_count: map_size(state.failed_tasks),
      can_spawn?: can_spawn?(state),
      session_id: state.session_id,
      plan_id: state.plan_id
    }
  end

  @doc "Updates config. Validates and rejects invalid values."
  @spec update_config(t(), map()) :: t()
  def update_config(state, config) when is_map(config) do
    state
    |> maybe_update_int(:max_concurrency, Map.get(config, "max_concurrency"))
  end

  defp maybe_update_int(state, _key, nil), do: state
  defp maybe_update_int(state, key, n) when is_integer(n) and n > 0, do: Map.put(state, key, n)
  defp maybe_update_int(state, _key, _), do: state
end
