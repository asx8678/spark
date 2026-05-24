defmodule Spark.Workspace.LockManager do
  @moduledoc """
  GenServer managing exclusive path locks for tasks.

  Prevents concurrent tasks from writing to overlapping paths. Locks are
  acquired per-task, released on task completion/failure, and support
  overlap detection via prefix matching.

  State is a map of `path => task_id`. A task can hold locks on multiple
  paths. Any path that is a prefix of (or equal to) another locked path
  is considered a conflict.
  """

  use GenServer

  @type lock_state :: %{String.t() => String.t()}

  # --- Public API ---

  @doc """
  Starts the LockManager GenServer.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Acquires locks on `paths` for the given `task_id`.

  Returns `:ok` if all paths are available and locked.
  Returns `{:error, :conflict, [conflicting_task_ids]}` if any path is
  already locked by a different task. No partial locks are granted on
  conflict — it's all or nothing.
  """
  @spec acquire(String.t(), [String.t()]) :: :ok | {:error, :conflict, [String.t()]}
  def acquire(task_id, paths) when is_binary(task_id) and is_list(paths) do
    GenServer.call(__MODULE__, {:acquire, task_id, paths})
  end

  @doc """
  Releases all locks held by `task_id`.
  """
  @spec release(String.t()) :: :ok
  def release(task_id) when is_binary(task_id) do
    GenServer.call(__MODULE__, {:release, task_id})
  end

  @doc """
  Checks if any path in `paths` is currently locked.

  Returns `{true, [conflicting_task_ids]}` or `false`.
  """
  @spec conflicts?([String.t()]) :: {true, [String.t()]} | false
  def conflicts?(paths) when is_list(paths) do
    GenServer.call(__MODULE__, {:conflicts?, paths})
  end

  @doc """
  Returns the current lock state as a map of `path => task_id`.
  """
  @spec status() :: lock_state()
  def status do
    GenServer.call(__MODULE__, :status)
  end

  # --- GenServer callbacks ---

  @impl true
  def init(_opts) do
    {:ok, %{locks: %{}}}
  end

  @impl true
  def handle_call({:acquire, task_id, paths}, _from, state) do
    # Normalize paths for consistent matching
    normalized = Enum.map(paths, &normalize_path/1)

    # Find conflicts: any path that overlaps with existing locks
    conflict_tasks =
      normalized
      |> Enum.flat_map(fn path ->
        find_conflicting_tasks(path, state.locks, task_id)
      end)
      |> Enum.uniq()

    if conflict_tasks == [] do
      new_locks =
        Enum.reduce(normalized, state.locks, fn path, locks ->
          Map.put(locks, path, task_id)
        end)

      {:reply, :ok, %{state | locks: new_locks}}
    else
      {:reply, {:error, :conflict, conflict_tasks}, state}
    end
  end

  @impl true
  def handle_call({:release, task_id}, _from, state) do
    new_locks =
      state.locks
      |> Enum.reject(fn {_path, tid} -> tid == task_id end)
      |> Map.new()

    {:reply, :ok, %{state | locks: new_locks}}
  end

  @impl true
  def handle_call({:conflicts?, paths}, _from, state) do
    normalized = Enum.map(paths, &normalize_path/1)

    conflict_tasks =
      normalized
      |> Enum.flat_map(fn path ->
        find_all_conflicting_tasks(path, state.locks)
      end)
      |> Enum.uniq()

    if conflict_tasks == [] do
      {:reply, false, state}
    else
      {:reply, {true, conflict_tasks}, state}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, state.locks, state}
  end

  # --- Private helpers ---

  # Find tasks that conflict with `path` for a specific requesting task.
  # A conflict exists when a path overlaps (prefix match) with a lock
  # held by a *different* task.
  defp find_conflicting_tasks(path, locks, requesting_task_id) do
    locks
    |> Enum.filter(fn {locked_path, tid} ->
      tid != requesting_task_id and paths_overlap?(path, locked_path)
    end)
    |> Enum.map(fn {_path, tid} -> tid end)
  end

  # Find all tasks holding locks that overlap with `path` (regardless of task).
  defp find_all_conflicting_tasks(path, locks) do
    locks
    |> Enum.filter(fn {locked_path, _tid} ->
      paths_overlap?(path, locked_path)
    end)
    |> Enum.map(fn {_path, tid} -> tid end)
  end

  # Two paths overlap if either is a prefix of the other.
  # This catches: same path, parent/child, sibling ambiguity.
  defp paths_overlap?(path_a, path_b) do
    # Exact match
    # path_a is a parent of path_b
    # path_b is a parent of path_a
    path_a == path_b or
      String.starts_with?(path_b, path_a <> "/") or
      String.starts_with?(path_a, path_b <> "/")
  end

  defp normalize_path(path) do
    path
    |> Path.expand()
    |> String.trim_trailing("/")
  end
end
