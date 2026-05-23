defmodule Spark.Worker do
  @moduledoc """
  LLM-powered task execution worker.

  Each Worker receives one validated Task, runs an LLM-driven execution
  loop (max 10 iterations), executes tools via ToolRunner, and reports
  results back to the Dispatcher.

  Workers capture prompt and tool versions at startup and are immune to
  hot reload events mid-task — they log/receive the event but never
  change behavior while running.
  """

  use GenServer

  alias Spark.Types.{Event, Task, WorkerResult}
  alias Spark.EventBus
  alias Spark.Guidance

  @max_iterations 10

  # spark-04w.3: Worker isolation — cannot spawn sub-workers
  @blocked_modules [Spark.Worker, Spark.WorkerSupervisor, Spark.Orchestrator]

  @doc """
  Checks if a module call would violate Worker isolation.
  Workers must not: spawn sub-workers, call Orchestrator state mutators.
  """
  def isolation_violation?(module, function) do
    cond do
      module in @blocked_modules and function in [:start_link, :child_spec, :run, :approve_plan, :reject_plan, :modify_plan] ->
        true
      module == Spark.Orchestrator and function in [:get_state] ->
        false  # reads are fine
      module == Spark.Orchestrator ->
        true  # any other Orchestrator call = mutation attempt
      true ->
        false
    end
  end

  # --- Public API ---

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  # --- Init (spark-pvp.1) ---

  @impl true
  def init(opts) do
    task = Keyword.fetch!(opts, :task)
    session_id = Keyword.get(opts, :session_id)
    plan_id = Keyword.get(opts, :plan_id)

    case Task.validate(task) do
      :ok ->
        worker_id = generate_worker_id()
        prompt_version = capture_prompt_version()
        tool_versions = capture_tool_versions()

        state = %{
          worker_id: worker_id,
          session_id: session_id,
          plan_id: plan_id,
          task: task,
          prompt_version: prompt_version,
          tool_versions: tool_versions,
          history: [],
          guidance_messages: [],
          started_at: DateTime.utc_now(),
          status: :running,
          llm_call_fn: Keyword.get(opts, :llm_call_fn, &Spark.LLM.Client.complete/3),
          reload_notifier: Keyword.get(opts, :reload_notifier)
        }

        # Subscribe to hot reload events (won't change behavior mid-task)
        try do
          EventBus.subscribe("spark:hot_reload")
        rescue
          _ -> :ok
        end

        EventBus.publish_task(task.id, :task_started, %{
          task_id: task.id,
          worker_id: worker_id,
          plan_id: plan_id,
          prompt_version: prompt_version,
          tool_versions: tool_versions
        })

        # Kick off execution loop via self-message (allows interleaving of
        # hot-reload events and :sys.get_state between iterations)
        send(self(), {:execute_step, 0})
        {:ok, state}

      {:error, errors} ->
        {:stop, {:invalid_task, errors}}
    end
  end

  # --- Execution Loop (spark-pvp.2) ---

  @impl true
  def handle_info({:execute_step, iteration}, state) when iteration >= @max_iterations do
    do_complete_failure(state, :max_iterations_exceeded)
  end

  def handle_info({:execute_step, iteration}, state) do
    try do
      messages = build_messages(state)
      opts = %{session_id: state.session_id, plan_id: state.plan_id, task_id: state.task.id}

      case state.llm_call_fn.(:worker, messages, opts) do
        {:ok, response} ->
          handle_llm_response(response, iteration, state)

        {:error, reason} ->
          do_complete_failure(state, reason)
      end
    rescue
      e ->
        do_complete_failure(state, Exception.message(e))
    end
  end

  # Hot reload events — survive them, optionally notify (spark-pvp.4)
  # spark-04w.5: Policy reload — revalidate active task
  @impl true
  def handle_info(%Event{type: type} = event, state)
      when type in [:prompt_reloaded, :tool_reloaded, :config_reloaded] do
    if state.reload_notifier, do: state.reload_notifier.(event)
    # spark-31u.2: Reload guidance on relevant hot reload events
    try do
      Guidance.reload()
    rescue
      _ -> :ok
    end
    {:noreply, state}
  end

  def handle_info(%Event{type: :guidance_reloaded}, state) do
    # spark-31u.2: Guidance hot reload — refresh guidance rules
    try do
      Guidance.reload()
    rescue
      _ -> :ok
    end
    {:noreply, state}
  end

  def handle_info(%Event{type: :policy_reloaded}, state) do
    # Revalidate current task against new policy — if denied, fail gracefully
    case Spark.Policy.validate_task(state.task) do
      :ok ->
        {:noreply, state}
      {:error, _reason} ->
        do_complete_failure(state, :policy_denied_after_reload)
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Private: LLM Response Handling ---

  defp handle_llm_response(response, iteration, state) do
    choice = get_in(response, [:choices, Access.at(0), :message]) || %{}
    content = Map.get(choice, :content)
    tool_calls = Map.get(choice, :tool_calls)

    cond do
      is_binary(content) and content != "" ->
        do_complete_success(state, content, get_usage(response))

      is_list(tool_calls) and tool_calls != [] ->
        results = execute_tool_calls(tool_calls, state)
        # spark-31u.2: Run guidance selection on tool results
        guidance_msgs = collect_guidance_messages(results)
        new_history = state.history ++ [{:assistant, response}, {:tool, results}]
        new_guidance = state.guidance_messages ++ guidance_msgs
        send(self(), {:execute_step, iteration + 1})
        {:noreply, %{state | history: new_history, guidance_messages: new_guidance}}

      true ->
        # No content and no tool calls — retry
        send(self(), {:execute_step, iteration + 1})
        {:noreply, state}
    end
  end

  # --- Private: Tool Execution ---

  # spark-04w.3: Workers cannot bypass ToolRunner — all tool calls route here.
  # spark-04w.2: Policy gate enforced before every tool call.
  defp execute_tool_calls(tool_calls, state) do
    context = %{
      session_id: state.session_id,
      plan_id: state.plan_id,
      task_id: state.task.id,
      worker_id: state.worker_id
    }

    Enum.map(tool_calls, fn tc ->
      name = get_in(tc, [:function, :name]) || Map.get(tc, :name, "unknown")
      args = get_in(tc, [:function, :arguments]) || Map.get(tc, :arguments, %{})

      # spark-04w.2: Policy gate — validate before execution
      worker_state = %{task_id: state.task.id, task: state.task, worker_id: state.worker_id}

      result =
        case Spark.Policy.validate_tool_call(name, args, worker_state) do
          :ok ->
            Spark.ToolRunner.run(name, args, context)
          {:error, reason} ->
            {:error, {:policy_denied, reason}}
        end

      {name, result}
    end)
  end

  # --- Private: Completion / Failure (spark-pvp.3) ---

  defp do_complete_success(state, summary, usage) do
    result =
      WorkerResult.success(%{
        task_id: state.task.id,
        worker_id: state.worker_id,
        summary: summary,
        started_at: state.started_at,
        token_usage: usage || %{}
      })

    EventBus.publish_task(state.task.id, :task_completed, %{
      task_id: state.task.id,
      worker_id: state.worker_id,
      prompt_version: state.prompt_version,
      tool_versions: state.tool_versions,
      result: result
    })

    notify_dispatcher(:complete, state.task.id, result)

    {:stop, :normal, %{state | status: :completed}}
  end

  defp do_complete_failure(state, reason) do
    reason_str = stringify_reason(reason)

    result =
      WorkerResult.failure(%{
        task_id: state.task.id,
        worker_id: state.worker_id,
        summary: "Task failed: #{reason_str}",
        errors: [%{reason: reason_str}],
        started_at: state.started_at,
        token_usage: %{}
      })

    EventBus.publish_task(state.task.id, :task_failed, %{
      task_id: state.task.id,
      worker_id: state.worker_id,
      reason: reason,
      prompt_version: state.prompt_version,
      result: result
    })

    notify_dispatcher(:failed, state.task.id, result)

    {:stop, :normal, %{state | status: :failed}}
  end

  # --- Private: Helpers ---

  defp build_messages(state) do
    task = state.task

    system_msg = %{
      role: "system",
      content: "You are a Spark worker executing task: #{task.title}."
    }

    user_msg = %{
      role: "user",
      content: "Execute task: #{task.title}\n\nDescription: #{task.description}"
    }

    # spark-31u.2: Inject guidance messages as hidden system messages
    # before the next LLM call
    guidance_msgs =
      Enum.map(state.guidance_messages, fn msg ->
        %{role: "system", content: "[guidance] #{msg}"}
      end)

    history_msgs =
      Enum.flat_map(state.history, fn
        {:assistant, resp} ->
          choice = get_in(resp, [:choices, Access.at(0), :message]) || %{}
          [%{role: "assistant", content: Map.get(choice, :content, "")}]

        {:tool, results} ->
          Enum.map(results, fn {name, result} ->
            %{role: "tool", content: "#{name}: #{inspect(result)}"}
          end)
      end)

    [system_msg, user_msg | guidance_msgs ++ history_msgs]
  end

  # spark-31u.2: Collect guidance injection messages from tool results
  defp collect_guidance_messages(results) do
    Enum.flat_map(results, fn {_name, result} ->
      context = infer_guidance_context(result)

      try do
        case Guidance.select(result, context) do
          nil -> []
          msg -> [msg]
        end
      rescue
        _ -> []
      catch
        :exit, _ -> []
      end
    end)
  end

  defp infer_guidance_context({:error, _}), do: %{error: true}
  defp infer_guidance_context({:ok, %{status: :timeout}}), do: %{error: true}
  defp infer_guidance_context({:ok, %{tool: tool}}), do: %{tool: tool}
  defp infer_guidance_context(_), do: %{}

  defp capture_prompt_version do
    case Code.ensure_loaded(Spark.Prompt.Store) do
      {:module, mod} ->
        try do
          apply(mod, :current_version, [])
        rescue
          _ -> "unknown"
        catch
          _, _ -> "unknown"
        end

      {:error, _} ->
        "unknown"
    end
  end

  defp capture_tool_versions do
    try do
      Registry.select(Spark.ToolRegistry, [{{:"$1", :_, :_}, [], [:"$1"]}])
      |> Map.new(fn name -> {name, :unknown} end)
    rescue
      _ -> %{}
    end
  end

  defp generate_worker_id do
    "worker_#{:erlang.unique_integer([:positive])}"
  end

  defp get_usage(response), do: Map.get(response, :usage, %{})

  defp stringify_reason(reason) when is_binary(reason), do: reason
  defp stringify_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp stringify_reason(reason), do: inspect(reason)

  defp notify_dispatcher(:complete, task_id, result) do
    safe_dispatcher_call(:handle_worker_complete, [task_id, result])
  end

  defp notify_dispatcher(:failed, task_id, result) do
    safe_dispatcher_call(:handle_worker_failed, [task_id, result])
  end

  defp safe_dispatcher_call(fun, args) do
    try do
      if Process.whereis(Spark.Dispatcher) do
        apply(Spark.Dispatcher, fun, args)
      end
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end
  end
end
