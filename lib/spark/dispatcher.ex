defmodule Spark.Dispatcher do
  @moduledoc """
  Concurrent task queue dispatcher.

  Manages task scheduling, worker spawning, completion handling, failure
  handling, and retry decisions.
  """

  use GenServer

  require Logger

  alias Spark.Dispatcher.State
  alias Spark.Dispatcher.RetryPolicy
  alias Spark.Types.Task
  alias Spark.EventBus
  alias Spark.AgentProtocol

  @default_worker_module Spark.Worker

  # --- Public API ---

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec enqueue(String.t(), [Spark.Types.Task.t()], keyword()) :: :ok | {:error, term()}
  def enqueue(plan_id, tasks, opts \\ []),
    do: GenServer.call(__MODULE__, {:enqueue, plan_id, tasks, opts})

  @spec pause() :: :ok
  def pause, do: GenServer.call(__MODULE__, :pause)
  @spec resume() :: :ok
  def resume, do: GenServer.call(__MODULE__, :resume)
  @spec status() :: map()
  def status, do: GenServer.call(__MODULE__, :status)

  @spec task_statuses() :: [map()]
  def task_statuses, do: GenServer.call(__MODULE__, :task_statuses)

  @spec handle_worker_complete(String.t(), Spark.Types.WorkerResult.t() | nil) :: :ok
  def handle_worker_complete(task_id, result) do
    GenServer.cast(__MODULE__, {:worker_complete, task_id, result})
  end

  @spec handle_worker_failed(String.t(), term()) :: :ok
  def handle_worker_failed(task_id, reason) do
    GenServer.cast(__MODULE__, {:worker_failed, task_id, reason})
  end

  @spec worker_heartbeat(String.t()) :: :ok
  def worker_heartbeat(task_id) do
    GenServer.cast(__MODULE__, {:worker_heartbeat, task_id})
  end

  @spec reload_config() :: :ok
  def reload_config, do: GenServer.call(__MODULE__, :reload_config)

  @doc """
  Graceful drain — pauses new task spawning, then waits for active
  workers to reach 0, polling every 100ms up to `timeout_ms`.

  Returns `{:ok, 0}` when all workers finished, or
  `{:timeout, remaining_count}` if the deadline expired.
  """
  @spec drain(non_neg_integer()) :: {:ok, 0} | {:timeout, non_neg_integer()}
  def drain(timeout_ms \\ 5000) do
    # Stop spawning new workers
    GenServer.call(__MODULE__, :pause)

    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll_drain(deadline)
  end

  defp poll_drain(deadline) do
    remaining_ms = deadline - System.monotonic_time(:millisecond)

    if remaining_ms <= 0 do
      active = GenServer.call(__MODULE__, :status).active_count
      if active == 0, do: {:ok, 0}, else: {:timeout, active}
    else
      case GenServer.call(__MODULE__, :status).active_count do
        0 ->
          {:ok, 0}

        _ ->
          Process.sleep(100)
          poll_drain(deadline)
      end
    end
  end

  # --- GenServer Callbacks ---

  @heartbeat_check_interval 10_000
  @heartbeat_timeout_seconds 30

  @impl true
  def init(opts) do
    state =
      State.new(
        max_concurrency: Keyword.get(opts, :max_concurrency),
        session_id: Keyword.get(opts, :session_id),
        plan_id: Keyword.get(opts, :plan_id),
        worker_module: Keyword.get(opts, :worker_module)
      )

    Logger.metadata(plan_id: nil, queue_depth: 0, active_count: 0, actor: :dispatcher)

    # Register in SessionRegistry for agent discovery (AgentProtocol)
    # Skip registration when session_id is not yet available
    if state.session_id do
      AgentProtocol.register(:dispatcher, state.session_id)
    end

    schedule_heartbeat_check()
    {:ok, state}
  end

  # Accept both {:enqueue, plan_id, tasks} (legacy) and {:enqueue, plan_id, tasks, opts}
  @impl true
  def handle_call({:enqueue, plan_id, tasks}, from, state) do
    handle_call({:enqueue, plan_id, tasks, []}, from, state)
  end

  def handle_call({:enqueue, plan_id, tasks, opts}, _from, state) do
    # Adopt session_id from the caller (Orchestrator) if we don't have one.
    # This is critical for AgentProtocol discovery — Workers need to find
    # the Dispatcher and Orchestrator, and both must share the same session_id.
    incoming_session_id = Keyword.get(opts, :session_id)

    state =
      if is_nil(state.session_id) and is_binary(incoming_session_id) do
        try do
          AgentProtocol.register(:dispatcher, incoming_session_id)
        rescue
          _ -> :ok
        end

        %{state | session_id: incoming_session_id}
      else
        state
      end

    state = %{state | plan_id: plan_id}

    case State.enqueue(state, tasks) do
      {:ok, new_state} ->
        for task <- tasks, Task.validate(task) == :ok do
          EventBus.publish_task(task.id, :task_queued, %{task_id: task.id, plan_id: plan_id})
        end

        update_disp_metadata(new_state)
        schedule_spawn()
        {:reply, :ok, new_state}

      {:error, _invalid} ->
        update_disp_metadata(state)
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
  def handle_call(:task_statuses, _from, state) do
    {:reply, State.task_statuses(state), state}
  end

  @impl true
  def handle_call(:reload_config, _from, state) do
    new_max = Spark.Config.get([:dispatcher, :max_concurrency], state.max_concurrency)
    # nil default: on reload, missing config key means "keep current value"
    # (vs. State.new/1 where missing means "use Spark.Worker default")
    new_worker_mod = Spark.Config.get([:dispatcher, :worker_module], nil)

    new_state =
      State.update_config(state, %{
        "max_concurrency" => new_max,
        "worker_module" => new_worker_mod
      })

    EventBus.publish_event(
      :dispatcher_config_updated,
      %{
        max_concurrency: new_state.max_concurrency,
        previous_max_concurrency: state.max_concurrency,
        worker_module: new_state.worker_module,
        previous_worker_module: state.worker_module
      }, topic: "spark:events", source: :dispatcher)

    if new_state.max_concurrency > state.max_concurrency, do: schedule_spawn()
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_cast({:worker_complete, task_id, result}, state) do
    worker_info = Map.get(state.active_workers, task_id)
    state = State.remove_active(state, task_id)
    state = State.mark_completed(state, task_id)

    if worker_info, do: Process.demonitor(worker_info.monitor_ref, [:flush])

    EventBus.publish_task(task_id, :task_completed, %{task_id: task_id})
    notify_orchestrator_complete(task_id, result, state.session_id)

    update_disp_metadata(state)
    schedule_spawn()
    {:noreply, state}
  end

  @impl true
  def handle_cast({:worker_failed, task_id, reason}, state) do
    state = process_failure(state, task_id, reason)
    update_disp_metadata(state)
    schedule_spawn()
    {:noreply, state}
  end

  @impl true
  def handle_cast({:worker_heartbeat, task_id}, state) do
    if Map.has_key?(state.active_workers, task_id) do
      {:noreply, State.record_heartbeat(state, task_id)}
    else
      {:noreply, state}
    end
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
              notify_orchestrator_complete(task_id, nil, state.session_id)
              state

            {:shutdown, _} ->
              state = State.mark_completed(state, task_id)
              EventBus.publish_task(task_id, :task_completed, %{task_id: task_id})
              notify_orchestrator_complete(task_id, nil, state.session_id)
              state

            :killed ->
              process_failure_on_state(state, task_id, :worker_killed, :worker_killed, task)

            _ ->
              reason_atom = normalize_reason(reason)
              process_failure_on_state(state, task_id, reason_atom, reason, task)
          end

        schedule_spawn()
        update_disp_metadata(state)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:try_spawn, state) do
    new_state = try_spawn_one(state)
    update_disp_metadata(new_state)
    {:noreply, new_state}
  end

  @impl true
  def handle_info(:check_heartbeats, state) do
    stale_ids = State.stale_heartbeats(state, @heartbeat_timeout_seconds)

    state =
      Enum.reduce(stale_ids, state, fn task_id, acc ->
        case Map.get(acc.active_workers, task_id) do
          nil ->
            acc

          worker_info ->
            Process.demonitor(worker_info.monitor_ref, [:flush])
            Process.exit(worker_info.pid, :kill)
            task = worker_info.task
            acc = State.remove_active(acc, task_id)
            process_failure_on_state(acc, task_id, :heartbeat_timeout, :heartbeat_timeout, task)
        end
      end)

    schedule_heartbeat_check()
    update_disp_metadata(state)
    {:noreply, state}
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
              state = State.record_heartbeat(state, task.id)

              EventBus.publish_task(task.id, :task_started, %{
                task_id: task.id,
                plan_id: state.plan_id
              })

              schedule_spawn()
              state

            {:error, _reason} ->
              state = State.mark_failed(state, task.id, %{reason: :spawn_failed})

              EventBus.publish_task(task.id, :task_failed, %{
                task_id: task.id,
                reason: :spawn_failed
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

  defp schedule_heartbeat_check do
    Process.send_after(self(), :check_heartbeats, @heartbeat_check_interval)
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

    reason_atom =
      case reason do
        %Spark.Types.WorkerResult{errors: [%{reason: r} | _]} ->
          cond do
            is_atom(r) ->
              r

            is_binary(r) ->
              try do
                String.to_existing_atom(r)
              rescue
                ArgumentError -> :worker_failed
              end

            true ->
              :worker_failed
          end

        _ ->
          normalize_reason(reason)
      end

    # Release lock hooks for future LockManager integration
    release_lock_hooks(task)

    process_failure_on_state(state, task_id, reason_atom, reason, task)
  end

  defp process_failure_on_state(state, task_id, reason_atom, reason_or_result, task) do
    if task do
      case RetryPolicy.decide(task, reason_atom) do
        {:retry, updated_task} ->
          {:ok, state} = State.enqueue(state, [updated_task])
          schedule_spawn()

          EventBus.publish_task(task_id, :task_retried, %{
            task_id: task_id,
            retry_count: updated_task.retry_count,
            reason: reason_atom
          })

          state

        {:give_up, _task} ->
          failure_info = %{reason: reason_atom, retries: task.retry_count, final: true}
          state = State.mark_failed(state, task_id, failure_info)

          EventBus.publish_task(task_id, :task_failed, %{
            task_id: task_id,
            reason: reason_atom,
            retries: task.retry_count
          })

          notify_orchestrator_failed(task_id, reason_or_result, state.session_id)
          state
      end
    else
      state = State.mark_failed(state, task_id, %{reason: reason_atom})
      EventBus.publish_task(task_id, :task_failed, %{task_id: task_id, reason: reason_atom})
      notify_orchestrator_failed(task_id, reason_or_result, state.session_id)
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

  defp update_disp_metadata(state) do
    Logger.metadata(
      plan_id: state.plan_id,
      queue_depth: :queue.len(state.queue),
      active_count: map_size(state.active_workers),
      actor: :dispatcher
    )
  end

  defp normalize_reason(:normal), do: :worker_exit
  defp normalize_reason(:killed), do: :worker_killed
  defp normalize_reason({:shutdown, _}), do: :worker_shutdown
  defp normalize_reason(:timeout), do: :llm_timeout
  defp normalize_reason(reason) when is_atom(reason), do: reason
  defp normalize_reason(_), do: :unknown

  defp notify_orchestrator_complete(task_id, result, session_id) do
    # Agent Protocol: Dispatcher→Orchestrator leg of
    # AgentProtocol.report_completion/1 (formal contract in P2.8)
    # Registry-based discovery replaces Process.whereis (spark-ard.19)
    case AgentProtocol.find(:orchestrator, session_id) do
      {:ok, pid} ->
        try do
          orchestrator_result =
            case result do
              %Spark.Types.WorkerResult{} ->
                result

              _ ->
                Spark.Types.WorkerResult.success(%{
                  task_id: task_id,
                  worker_id: "dispatcher",
                  summary: "Task completed",
                  started_at: DateTime.utc_now(),
                  token_usage: %{}
                })
            end

          GenServer.cast(pid, {:task_completed, orchestrator_result})
        catch
          :exit, {:noproc, _} -> :ok
          :exit, {:nodedown, _} -> :ok
        end

      {:error, :not_found} ->
        :ok
    end
  end

  defp notify_orchestrator_failed(task_id, reason, session_id) do
    # Agent Protocol: Dispatcher→Orchestrator failure leg of
    # AgentProtocol.report_completion/1 (formal contract in P2.8)
    # Registry-based discovery replaces Process.whereis (spark-ard.19)
    case AgentProtocol.find(:orchestrator, session_id) do
      {:ok, pid} ->
        try do
          orchestrator_result =
            case reason do
              %Spark.Types.WorkerResult{} ->
                reason

              _ ->
                reason_str = if is_binary(reason), do: reason, else: inspect(reason)

                Spark.Types.WorkerResult.failure(%{
                  task_id: task_id,
                  worker_id: "dispatcher",
                  summary: "Task failed: #{reason_str}",
                  errors: [%{reason: reason_str}],
                  started_at: DateTime.utc_now(),
                  token_usage: %{}
                })
            end

          GenServer.cast(pid, {:task_failed, orchestrator_result})
        catch
          :exit, {:noproc, _} -> :ok
          :exit, {:nodedown, _} -> :ok
        end

      {:error, :not_found} ->
        :ok
    end
  end
end
