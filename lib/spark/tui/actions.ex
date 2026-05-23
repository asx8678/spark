defmodule Spark.TUI.Actions do
  @moduledoc "Backend read/write helpers for Spark TUI."

  alias Spark.TUI.EventLog

  def load_agents do
    safe(fn -> Spark.AgentManager.list_agents() end, %{})
  end

  def dashboard_snapshot do
    orchestrator = safe(fn -> Spark.Orchestrator.get_state() end, nil)
    dispatcher = safe(fn -> Spark.Dispatcher.status() end, %{})
    agents = load_agents()

    %{
      orchestrator_phase: if(orchestrator, do: orchestrator.phase, else: nil),
      prompt_version: if(orchestrator, do: orchestrator.prompt_version, else: nil),
      active_plan_id: if(orchestrator && orchestrator.active_plan, do: orchestrator.active_plan.id, else: nil),
      active_plan_status: if(orchestrator && orchestrator.active_plan, do: orchestrator.active_plan.approval_status, else: nil),
      queue_length: Map.get(dispatcher, :queue_length, 0),
      active_count: Map.get(dispatcher, :active_count, 0),
      active_worker_tasks: safe(fn -> dispatcher_worker_task_names() end, []),
      max_concurrency: Map.get(dispatcher, :max_concurrency, "—"),
      completed_count: Map.get(dispatcher, :completed_count, 0),
      failed_count: Map.get(dispatcher, :failed_count, 0),
      agents: agents
    }
  end

  def start_plan(goal) do
    Spark.Orchestrator.run(goal)
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, reason -> {:error, {:process_exit, reason}}
  end

  def approve_plan(plan_id) do
    Spark.Orchestrator.approve_plan(plan_id)
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, reason -> {:error, {:process_exit, reason}}
  end

  def reject_plan(plan_id) do
    Spark.Orchestrator.reject_plan(plan_id)
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, reason -> {:error, {:process_exit, reason}}
  end

  def install_event_log_hook do
    EventLog.install_hook()
  end

  def load_logs(limit \\ 50) do
    EventLog.list(limit)
  end

  def clear_logs do
    EventLog.clear()
  end

  def safe(fun, default \\ nil) do
    fun.()
  rescue
    _ -> default
  catch
    :exit, _ -> default
  end

  defp dispatcher_worker_task_names do
    :sys.get_state(Spark.Dispatcher).active_workers
    |> Map.values()
    |> Enum.map(& &1.task.title)
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end
end
