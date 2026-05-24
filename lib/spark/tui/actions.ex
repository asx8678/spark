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

    # Grab recent LLM/tool lifecycle events for visibility
    recent_events = load_logs(10)

    llm_events =
      Enum.filter(recent_events, fn e ->
        e.type in [
          :worker_llm_started,
          :worker_llm_completed,
          :worker_llm_failed,
          :worker_llm_timeout,
          :tool_started,
          :tool_completed,
          :tool_failed,
          :task_started,
          :task_completed,
          :task_failed,
          :worker_started,
          :agent_reasoning,
          :state_transition,
          :tool_preflight,
          :tool_result_summary,
          :coding_handoff
        ]
      end)

    %{
      orchestrator_phase: if(orchestrator, do: orchestrator.phase, else: nil),
      prompt_version: if(orchestrator, do: orchestrator.prompt_version, else: nil),
      active_plan_id:
        if(orchestrator && orchestrator.active_plan, do: orchestrator.active_plan.id, else: nil),
      active_plan_status:
        if(orchestrator && orchestrator.active_plan,
          do: orchestrator.active_plan.approval_status,
          else: nil
        ),
      queue_length: Map.get(dispatcher, :queue_length, 0),
      active_count: Map.get(dispatcher, :active_count, 0),
      active_worker_tasks: safe(fn -> dispatcher_worker_task_names() end, []),
      max_concurrency: Map.get(dispatcher, :max_concurrency, "—"),
      worker_module: Map.get(dispatcher, :worker_module),
      completed_count: Map.get(dispatcher, :completed_count, 0),
      failed_count: Map.get(dispatcher, :failed_count, 0),
      task_statuses: task_statuses(),
      agents: agents,
      recent_events: llm_events
    }
  end

  def task_statuses do
    safe(fn -> Spark.Dispatcher.task_statuses() end, [])
  end

  def start_plan(goal) do
    Spark.Orchestrator.run(goal)
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, reason -> {:error, {:process_exit, reason}}
  end

  def start_plan_streaming(goal, tui_pid) do
    Spark.Orchestrator.run_streaming(goal, tui_pid)
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
    |> Enum.map(fn info ->
      elapsed =
        if info.started_at,
          do: DateTime.diff(DateTime.utc_now(), info.started_at, :second),
          else: nil

      elapsed_str = if elapsed, do: " (#{elapsed}s)", else: ""
      "#{info.task.title}#{elapsed_str}"
    end)
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  # ── Hot Reload helpers (ported from CLI) ────────────────────────────

  @reload_types [:prompts, :tools, :config, :policy, :guidance]

  @doc "Reloads a single component type via HotReload.Coordinator."
  def reload_component(type) when type in @reload_types do
    Spark.HotReload.Coordinator.reload(type)
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, reason -> {:error, {:process_exit, reason}}
  end

  @doc "Reloads all component types."
  def reload_all do
    results =
      for type <- @reload_types do
        {type, reload_component(type)}
      end

    {:ok, results}
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, reason -> {:error, {:process_exit, reason}}
  end

  @doc "Returns current reload coordinator status."
  def reload_status do
    Spark.HotReload.Coordinator.status()
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  @doc "Returns manifest entries for status display."
  def reload_manifest_entries do
    Spark.HotReload.Manifest.list()
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  @doc "Runs a shell command and captures output."
  def run_shell_command(cmd) do
    System.cmd("sh", ["-c", cmd], stderr_to_stdout: true, timeout: 15_000)
  rescue
    e -> {"Shell error: #{Exception.message(e)}", 1}
  catch
    :exit, _ -> {"Command timed out after 15s", 1}
  end
end
