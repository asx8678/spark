defmodule Spark.Dispatcher do
  @moduledoc """
  Concurrent task queue dispatcher.

  Manages task scheduling, worker spawning, completion handling, failure
  handling, and retry decisions.
  """

  use GenServer

  alias Spark.Dispatcher.State
  alias Spark.Dispatcher.RetryPolicy
  alias Spark.Types.Task
  alias Spark.EventBus

  @default_worker_module Spark.FakeWorker

  # --- Public API ---

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def enqueue(plan_id, tasks), do: GenServer.call(__MODULE__, {:enqueue, plan_id, tasks})
  def pause, do: GenServer.call(__MODULE__, :pause)
  def resume, do: GenServer.call(__MODULE__, :resume)
  def status, do: GenServer.call(__MODULE__, :status)

  def handle_worker_complete(task_id, result) do
    GenServer.call(__MODULE__, {:worker_complete, task_id, result})
  end

  def handle_worker_failed(task_id, reason) do
    GenServer.call(__MODULE__, {:worker_failed, task_id, reason})
  end

  def reload_config, do: GenServer.call(__MODULE__, :reload_config)

  # --- GenServer Callbacks ---

  @impl true
  def init(opts) do
    state = State.new(
      max_concurrency: Keyword.get(opts, :max_concurrency),
      session_id: Keyword.get(opts, :session_id),
      plan_id: Keyword.get(opts, :plan_id),
      worker_module: Keyword.get(opts, :worker_module, @default_worker_module)
    )
    {:ok, state}
  end

  @impl true
  def handle_call({:enqueue, plan_id, tasks}, _from, state) do
    state = %{state | plan_id: plan_id}

    case State.enqueue(state, tasks) do
      {:ok, new_state} ->
        for task <- tasks, Task.validate(task) == :ok do
          EventBus.publish_task(task.id, :task_queued, %{task_id: task.id, plan_id: plan_id})
        end
        schedule_spawn()
        {:reply, :ok, new_state}

      {:error, _invalid} ->
        schedule_spawn()
        {:reply, {:error, :some_invalid}, state}
    end
  end

  @impl true
  def handle_call(:pause, _from, state) do
    {:reply, :ok, State.pause(state)}
  end

  @impl true
  def handle_call(:resume, _from, state) do
    schedule_spawn()
    {:reply, :ok, State.resume(state)}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, State.status_map(state), state}
  end

  @impl true
  def handle_call(:reload_config, _from, state) do
    new_max = Spark.Config.get([:dispatcher, :max_concurrency], state.max_concurrency)
    new_state = State.update_config(state, %{"max_concurrency" => new_max})

    EventBus.publish_event(:dispatcher_config_updated, %{
      max_concurrency: new_state.max_concurrency,
      previous: state.max_concurrency
    }, topic: "spark:events", source: :dispatcher)

    if new_state.max_concurrency > state.max_concurrency, do: schedule_spawn()
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:worker_complete, task_id, _result}, _from, state) do
    worker_info = Map.get(state.active_workers, task_id)
    state = State.remove_active(state, task_id)
    state = State.mark_completed(state, task_id)

    if worker_info, do: Process.demonitor(worker_info.monitor_ref, [:flush])

    EventBus.publish_task(task_id, :task_completed, %{task_id: task_id})
    notify_orchestrator_complete(task_id, nil)

    schedule_spawn()
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:worker_failed, task_id, reason}, _from, state) do
    state = process_failure(state, task_id, reason)
    notify_orchestrator_failed(task_id, reason)
    schedule_spawn()
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    case find_task_by_pid(state, pid) do
      nil ->
        {:noreply, state}

      {task_id, worker_info} ->
        state = State.remove_active(state, task_id)
        task = worker_info.task

        # Release lock hooks for future LockManager integration
        release_lock_hooks(task)

        state =
          case reason do
            :normal ->
              state = State.mark_completed(state, task_id)
              EventBus.publish_task(task_id, :task_completed, %{task_id: task_id})
              notify_orchestrator_complete(task_id, nil)
              state

            :killed ->
              process_failure_on_state(state, task_id, :worker_killed, task)

            {:shutdown, _} ->
              state = State.mark_completed(state, task_id)
              EventBus.publish_task(task_id, :task_completed, %{task_id: task_id})
              notify_orchestrator_complete(task_id, nil)
              state

            _ ->
              reason_atom = normalize_reason(reason)
              state = process_failure_on_state(state, task_id, reason_atom, task)
              notify_orchestrator_failed(task_id, reason_atom)
              state
          end

        schedule_spawn()
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:try_spawn, state) do
    {:noreply, try_spawn_one(state)}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # --- Private ---

  defp try_spawn_one(state) do
    if State.can_spawn?(state) do
      {ready, state} = State.dequeue(state, 1)

      case ready do
        [task] ->
          case spawn_worker(task, state) do
            {:ok, pid, ref} ->
              worker_info = %{
                pid: pid,
                monitor_ref: ref,
                worker_id: "worker_#{:erlang.unique_integer([:positive])}",
                started_at: DateTime.utc_now(),
                task: task
              }

              state = State.add_active(state, task.id, worker_info)

              EventBus.publish_task(task.id, :task_started, %{
                task_id: task.id, plan_id: state.plan_id
              })

              schedule_spawn()
              state

            {:error, _reason} ->
              state = State.mark_failed(state, task.id, %{reason: :spawn_failed})
              EventBus.publish_task(task.id, :task_failed, %{
                task_id: task.id, reason: :spawn_failed
              })
              schedule_spawn()
              state
          end

        [] ->
          state
      end
    else
      state
    end
  end

  defp schedule_spawn do
    Process.send_after(self(), :try_spawn, 5)
  end

  defp spawn_worker(task, state) do
    worker_mod = state.worker_module || @default_worker_module
    child_spec = {worker_mod, task: task, session_id: state.session_id, plan_id: state.plan_id}

    case DynamicSupervisor.start_child(Spark.WorkerSupervisor, child_spec) do
      {:ok, pid} ->
        ref = Process.monitor(pid)
        {:ok, pid, ref}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp process_failure(state, task_id, reason) do
    worker_info = Map.get(state.active_workers, task_id)
    state = State.remove_active(state, task_id)
    if worker_info, do: Process.demonitor(worker_info.monitor_ref, [:flush])
    task = if worker_info, do: worker_info.task, else: nil
    reason_atom = normalize_reason(reason)

    # Release lock hooks for future LockManager integration
    release_lock_hooks(task)

    process_failure_on_state(state, task_id, reason_atom, task)
  end

  defp process_failure_on_state(state, task_id, reason_atom, task) do
    if task do
      case RetryPolicy.decide(task, reason_atom) do
        {:retry, updated_task} ->
          {:ok, state} = State.enqueue(state, [updated_task])
          schedule_spawn()
          EventBus.publish_task(task_id, :task_retried, %{
            task_id: task_id, retry_count: updated_task.retry_count, reason: reason_atom
          })
          state

        {:give_up, _task} ->
          failure_info = %{reason: reason_atom, retries: task.retry_count, final: true}
          state = State.mark_failed(state, task_id, failure_info)
          EventBus.publish_task(task_id, :task_failed, %{
            task_id: task_id, reason: reason_atom, retries: task.retry_count
          })
          notify_orchestrator_failed(task_id, reason_atom)
          state
      end
    else
      state = State.mark_failed(state, task_id, %{reason: reason_atom})
      EventBus.publish_task(task_id, :task_failed, %{task_id: task_id, reason: reason_atom})
      state
    end
  end

  defp find_task_by_pid(state, pid) do
    Enum.find(state.active_workers, fn {_task_id, info} ->
      info.pid == pid
    end)
  end

  # Placeholder for future LockManager — will release write_path locks
  # when a worker dies or a task fails.
  defp release_lock_hooks(nil), do: :ok
  defp release_lock_hooks(_task), do: :ok

  defp normalize_reason(:normal), do: :worker_exit
  defp normalize_reason(:killed), do: :worker_killed
  defp normalize_reason({:shutdown, _}), do: :worker_shutdown
  defp normalize_reason(:timeout), do: :llm_timeout
  defp normalize_reason(reason) when is_atom(reason), do: reason
  defp normalize_reason(_), do: :unknown

  defp notify_orchestrator_complete(task_id, _result) do
    try do
      if Process.whereis(Spark.Orchestrator) do
        result = Spark.Types.WorkerResult.success(%{
          task_id: task_id,
          worker_id: "dispatcher",
          summary: "Task completed",
          started_at: DateTime.utc_now(),
          token_usage: %{}
        })
        Spark.Orchestrator.task_completed(result)
      end
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end
  end

  defp notify_orchestrator_failed(task_id, reason) do
    try do
      if Process.whereis(Spark.Orchestrator) do
        reason_str = if is_binary(reason), do: reason, else: inspect(reason)
        result = Spark.Types.WorkerResult.failure(%{
          task_id: task_id,
          worker_id: "dispatcher",
          summary: "Task failed: #{reason_str}",
          errors: [%{reason: reason_str}],
          started_at: DateTime.utc_now(),
          token_usage: %{}
        })
        Spark.Orchestrator.task_failed(result)
      end
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end
  end
end
