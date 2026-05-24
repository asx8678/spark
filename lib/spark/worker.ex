defmodule Spark.Worker do
  @moduledoc """
  LLM-powered task execution worker.

  Each Worker receives one validated Task, runs an LLM-driven execution
  loop (max 10 iterations), executes tools via ToolRunner, and reports
  results back to the Dispatcher.

  Workers capture prompt and tool versions at startup and are immune to
  hot reload events mid-task — they log/receive the event but never
  change behavior while running.

  The LLM call runs asynchronously in a supervised Task to keep the
  GenServer responsive to heartbeats, hot reloads, and timeout checks
  while waiting for the LLM provider.
  """

  use GenServer

  require Logger

  alias Spark.Types.{Event, Task, WorkerResult}
  alias Spark.EventBus
  alias Spark.Guidance

  @max_iterations 10
  @max_history 50
  @max_guidance 50
  @heartbeat_interval 15_000

  # spark-04w.3: Worker isolation — cannot spawn sub-workers
  @blocked_modules [Spark.Worker, Spark.WorkerSupervisor, Spark.Orchestrator]

  @doc """
  Checks if a module call would violate Worker isolation.
  Workers must not: spawn sub-workers, call Orchestrator state mutators.
  """
  @spec isolation_violation?(module(), atom()) :: boolean()
  def isolation_violation?(module, function) do
    cond do
      module in @blocked_modules and
          function in [:start_link, :child_spec, :run, :approve_plan, :reject_plan, :modify_plan] ->
        true

      module == Spark.Orchestrator and function in [:get_state] ->
        # reads are fine
        false

      module == Spark.Orchestrator ->
        # any other Orchestrator call = mutation attempt
        true

      true ->
        false
    end
  end

  # --- Public API ---

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @spec child_spec(keyword()) :: map()
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
          reload_notifier: Keyword.get(opts, :reload_notifier),
          streaming_content: "",
          current_iteration: 0,
          # Async LLM call tracking
          pending_llm_ref: nil,
          pending_llm_task: nil,
          llm_started_at: nil,
          current_operation: nil
        }

        Logger.metadata(
          worker_id: worker_id,
          task_id: task.id,
          plan_id: plan_id,
          iteration: 0,
          actor: :worker
        )

        # Subscribe to hot reload events (won't change behavior mid-task)
        try do
          EventBus.subscribe("spark:hot_reload")
        rescue
          _ -> :ok
        end

        EventBus.publish_task(task.id, :worker_started, %{
          task_id: task.id,
          worker_id: worker_id,
          plan_id: plan_id,
          prompt_version: prompt_version,
          tool_versions: tool_versions
        }, source: :worker)

        # Kick off execution loop via self-message (allows interleaving of
        # hot-reload events and :sys.get_state between iterations)
        send(self(), {:execute_step, 0})

        # Start periodic heartbeat to Dispatcher
        schedule_heartbeat()
        {:ok, state}

      {:error, errors} ->
        {:stop, {:invalid_task, errors}}
    end
  end

  # --- Execution Loop (spark-pvp.2) ---

  # Max iterations guard — fire immediately
  @impl true
  def handle_info({:execute_step, iteration}, state) when iteration >= @max_iterations do
    do_complete_failure(state, :max_iterations_exceeded)
  end

  # Start an async LLM call — keeps GenServer responsive
  def handle_info({:execute_step, iteration}, state) do
    Logger.metadata(iteration: iteration)
    state = %{state | current_iteration: iteration, current_operation: :llm_call}

    EventBus.publish_worker(state.worker_id, :worker_iteration_started, %{
      task_id: state.task.id,
      worker_id: state.worker_id,
      iteration: iteration
    })

    messages = build_messages(state)
    opts = build_llm_opts(state)

    # Start the LLM call in a separate supervised Task
    llm_fn = state.llm_call_fn

    async_task =
      Elixir.Task.Supervisor.async_nolink(Spark.ToolSupervisor, fn ->
        llm_fn.(:worker, messages, opts)
      end)

    # The Task ref is what we'll match on for the result message
    ref = async_task.ref

    # Schedule a timeout for the LLM call based on task timeout
    task_timeout = state.task.timeout_ms
    timer_ref = Process.send_after(self(), {:llm_timeout, ref}, task_timeout)

    state = %{state |
      pending_llm_ref: ref,
      pending_llm_task: %{task: async_task, timer_ref: timer_ref},
      llm_started_at: System.monotonic_time(:millisecond)
    }

    EventBus.publish_worker(state.worker_id, :worker_llm_started, %{
      task_id: state.task.id,
      worker_id: state.worker_id,
      iteration: iteration,
      timeout_ms: task_timeout
    })

    {:noreply, state}
  end

  # LLM result from the async Task
  @impl true
  def handle_info({ref, result}, %{pending_llm_ref: ref} = state) do
    # Cancel the timeout timer
    state = cancel_llm_timeout(state)

    elapsed =
      if state.llm_started_at,
        do: System.monotonic_time(:millisecond) - state.llm_started_at,
        else: nil

    state = clear_pending_llm(state)

    case result do
      {:ok, response} ->
        EventBus.publish_worker(state.worker_id, :worker_llm_completed, %{
          task_id: state.task.id,
          worker_id: state.worker_id,
          iteration: state.current_iteration,
          elapsed_ms: elapsed
        })

        handle_llm_response(response, state.current_iteration, state)

      {:error, reason} ->
        EventBus.publish_worker(state.worker_id, :worker_llm_failed, %{
          task_id: state.task.id,
          worker_id: state.worker_id,
          iteration: state.current_iteration,
          reason: safe_reason_string(reason),
          elapsed_ms: elapsed
        })

        do_complete_failure(state, reason)
    end
  end

  # Async Task crashed (DOWN message from Task.Supervisor.async_nolink)
  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{pending_llm_ref: ref} = state) do
    state = cancel_llm_timeout(state)
    state = clear_pending_llm(state)

    EventBus.publish_worker(state.worker_id, :worker_llm_failed, %{
      task_id: state.task.id,
      worker_id: state.worker_id,
      iteration: state.current_iteration,
      reason: safe_reason_string(reason)
    })

    do_complete_failure(state, reason)
  end

  # LLM timeout — kill the pending task
  @impl true
  def handle_info({:llm_timeout, ref}, %{pending_llm_ref: ref} = state) do
    # Kill the async task
    if state.pending_llm_task do
      Elixir.Task.shutdown(state.pending_llm_task.task, 5000)
    end

    state = clear_pending_llm(state)

    EventBus.publish_worker(state.worker_id, :worker_llm_timeout, %{
      task_id: state.task.id,
      worker_id: state.worker_id,
      iteration: state.current_iteration,
      timeout_ms: state.task.timeout_ms
    })

    do_complete_failure(state, :llm_timeout)
  end

  # Ignore stale LLM refs
  def handle_info({_ref, _result}, state) do
    {:noreply, state}
  end

  # Ignore stale DOWN messages from completed async tasks
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    {:noreply, state}
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

  # Heartbeat: periodically notify Dispatcher that this Worker is alive
  @impl true
  def handle_info(:send_heartbeat, state) do
    # Registry-based discovery replaces named GenServer call (spark-ard.19)
    registry_cast(:dispatcher, state.session_id, {:worker_heartbeat, state.task.id})
    schedule_heartbeat()
    {:noreply, state}
  end

  # --- GenStage SSE streaming handlers ---

  # GenStage streaming path: accumulate content deltas from the
  # ChunkConsumer. The Worker's mailbox stays clean because GenStage
  # only delivers events on demand.
  @impl true
  def handle_info({:sse_chunk, %{delta: %{content: content}}}, state) do
    new_streaming = state.streaming_content <> content
    {:noreply, %{state | streaming_content: new_streaming}}
  end

  # GenStage streaming path: stream completed — process the final
  # response the same way as a synchronous LLM completion.
  @impl true
  def handle_info({:sse_done, response}, state) do
    # Clean up streaming state and process the response
    iteration = state.current_iteration
    state = %{state | streaming_content: ""}
    handle_llm_response(response, iteration, state)
  end

  # GenStage streaming path: error from the pipeline
  @impl true
  def handle_info({:sse_error, reason}, state) do
    Logger.warning("Worker received SSE error: #{inspect(reason)}")
    state = %{state | streaming_content: ""}
    do_complete_failure(state, reason)
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Private: LLM Response Handling ---

  defp handle_llm_response(response, iteration, state) do
    choice = get_in(response, [:choices, Access.at(0), :message]) || %{}
    content = Map.get(choice, :content)
    tool_calls = Map.get(choice, :tool_calls)

    cond do
      # Tool calls take priority over content — OpenAI-compatible responses
      # may include both explanatory content and tool_calls; we execute tools.
      is_list(tool_calls) and tool_calls != [] ->
        # Normalize once per response and reuse for both execution and history,
        # preventing divergence between the two normalization passes.
        norm_tool_calls =
          tool_calls
          |> Enum.with_index()
          |> Enum.map(fn {tc, idx} -> normalize_tool_call(tc, idx) end)

        results = execute_tool_calls(norm_tool_calls, state)
        # spark-31u.2: Run guidance selection on tool results
        guidance_msgs = collect_guidance_messages(results)

        new_history =
          ring_push(state.history, [{:assistant, choice, norm_tool_calls}, {:tool, results}], @max_history)

        new_guidance = ring_push(state.guidance_messages, guidance_msgs, @max_guidance)
        state = %{state | current_operation: nil}
        send(self(), {:execute_step, iteration + 1})
        {:noreply, %{state | history: new_history, guidance_messages: new_guidance}}

      is_binary(content) and content != "" ->
        do_complete_success(state, content, get_usage(response))

      true ->
        # No content and no tool calls — retry
        state = %{state | current_operation: nil}
        send(self(), {:execute_step, iteration + 1})
        {:noreply, state}
    end
  end

  # --- Private: Tool Execution ---

  # spark-04w.3: Workers cannot bypass ToolRunner — all tool calls route here.
  # spark-04w.2: Policy gate enforced before every tool call.
  # Receives pre-normalized tool calls — no secondary normalization.
  defp execute_tool_calls(norm_tool_calls, state) do
    context = %{
      session_id: state.session_id,
      plan_id: state.plan_id,
      task_id: state.task.id,
      worker_id: state.worker_id
    }

    Enum.map(norm_tool_calls, fn tc ->
      name = tc.name
      args = tc.arguments
      tool_call_id = tc.id

      # spark-04w.2: Policy gate — validate before execution
      worker_state = %{task_id: state.task.id, task: state.task, worker_id: state.worker_id}

      result =
        case Spark.Policy.validate_tool_call(name, args, worker_state) do
          :ok ->
            Spark.ToolRunner.run(name, args, context)

          {:error, reason} ->
            {:error, {:policy_denied, reason}}
        end

      %{tool_call_id: tool_call_id, name: name, result: result}
    end)
  end

  # Normalizes a tool_call map to support both atom-key and string-key formats
  # from OpenAI/Wafer responses. Generates stable fallback IDs for malformed
  # tool calls that lack an `id` field. Supports:
  #   - OpenAI format: %{id: ..., function: %{name: ..., arguments: ...}}
  #   - Top-level format: %{name: ..., arguments: ...} (no nested function key)
  @spec normalize_tool_call(map(), non_neg_integer()) :: %{id: String.t(), name: String.t(), arguments: term()}
  defp normalize_tool_call(tc, idx) when is_map(tc) and is_integer(idx) do
    id = tc[:id] || tc["id"] || "call_#{idx}"
    func = tc[:function] || tc["function"]

    # Prefer nested `function` key; fall back to top-level name/arguments
    {name, args} =
      if is_map(func) and map_size(func) > 0 do
        {func[:name] || func["name"] || "unknown", func[:arguments] || func["arguments"] || %{}}
      else
        {tc[:name] || tc["name"] || "unknown", tc[:arguments] || tc["arguments"] || %{}}
      end

    %{id: id, name: name, arguments: args}
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
    }, source: :worker)

    notify_dispatcher(:complete, state.task.id, result, state.session_id)

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
    }, source: :worker)

    notify_dispatcher(:failed, state.task.id, result, state.session_id)

    {:stop, :normal, %{state | status: :failed}}
  end

  # --- Private: Helpers ---

  defp build_llm_opts(state) do
    base = %{
      session_id: state.session_id,
      plan_id: state.plan_id,
      task_id: state.task.id,
      timeout_ms: state.task.timeout_ms
    }

    # Include tool schemas and tool_choice when tools are registered
    case safe_openai_schemas() do
      [] -> base
      schemas -> Map.merge(base, %{tools: schemas, tool_choice: "auto"})
    end
  end

  defp safe_openai_schemas do
    Spark.ToolRegistry.openai_schemas()
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  defp build_messages(state) do
    task = state.task

    worker_prompt =
      try do
        Spark.Prompt.Store.get(:worker)
      rescue
        _ -> "You are a Spark worker."
      catch
        _, _ -> "You are a Spark worker."
      end

    system_msg = %{
      role: "system",
      content: "#{worker_prompt}\n\nCurrently executing task: #{task.title}."
    }

    user_msg = %{
      role: "user",
      content: "Execute task: #{task.title}\n\nDescription: #{task.description}"
    }

    # spark-31u.2: Inject guidance messages as hidden system messages
    # before the next LLM call
    # Guidance & history stored newest-first; reverse for chronological order
    guidance_msgs =
      Enum.reverse(state.guidance_messages)
      |> Enum.map(fn msg ->
        %{role: "system", content: "[guidance] #{msg}"}
      end)

    history_msgs =
      Enum.reverse(state.history)
      |> Enum.flat_map(fn
        # New format: assistant with normalized tool_calls (3-tuple)
        {:assistant, choice_msg, norm_tool_calls} when is_list(norm_tool_calls) ->
          content = choice_content(choice_msg)
          base = %{role: "assistant", content: content}

          if norm_tool_calls != [] do
            openai_tcs =
              Enum.map(norm_tool_calls, fn tc ->
                args_str = tool_call_arguments_to_string(tc.arguments)

                %{
                  id: tc.id,
                  type: "function",
                  function: %{name: tc.name, arguments: args_str}
                }
              end)

            [Map.put(base, :tool_calls, openai_tcs)]
          else
            [base]
          end

        # Legacy format: assistant without tool_calls (2-tuple)
        {:assistant, resp} ->
          choice = get_in(resp, [:choices, Access.at(0), :message]) || %{}
          [%{role: "assistant", content: choice_content(choice)}]

        # New format: tool results with tool_call_id
        {:tool, results} ->
          Enum.map(results, fn
            %{tool_call_id: tc_id, result: result} ->
              content = format_tool_result(result)
              base = %{role: "tool", content: content}
              if tc_id, do: Map.put(base, :tool_call_id, tc_id), else: base

            {name, result} ->
              # Legacy 2-tuple format
              %{role: "tool", content: "#{name}: #{format_tool_result(result)}"}
          end)
      end)

    [system_msg, user_msg | guidance_msgs ++ history_msgs]
  end

  # spark-31u.2: Collect guidance injection messages from tool results
  defp collect_guidance_messages(results) do
    Enum.flat_map(results, fn
      %{result: result} ->
        collect_single_guidance(result)

      {_name, result} ->
        collect_single_guidance(result)
    end)
  end

  defp collect_single_guidance(result) do
    context = infer_guidance_context(result)

    try do
      case Guidance.select(result, context) do
        nil -> []
        msg -> [msg]
      end
    rescue
      FunctionClauseError -> []
    catch
      :exit, _ -> []
    end
  end

  defp infer_guidance_context({:error, _}), do: %{error: true}
  defp infer_guidance_context({:ok, %{status: :timeout}}), do: %{error: true}
  defp infer_guidance_context({:ok, %{tool: tool}}), do: %{tool: tool}
  defp infer_guidance_context(_), do: %{}

  defp capture_prompt_version do
    case Code.ensure_loaded(Spark.Prompt.Store) do
      {:module, mod} ->
        try do
          apply(mod, :version, [:worker])
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
      Spark.ToolRegistry.list()
      |> Map.new(fn {name, entry} -> {name, Map.get(entry, :version, :unknown)} end)
    rescue
      _ -> %{}
    catch
      _, _ -> %{}
    end
  end

  defp generate_worker_id do
    "worker_#{:erlang.unique_integer([:positive])}"
  end

  defp get_usage(response), do: Map.get(response, :usage, %{})

  # Extracts content from a choice message, returning nil for empty strings
  # (OpenAI convention: content is null/nil when tool_calls are present)
  defp choice_content(choice) when is_map(choice) do
    c = Map.get(choice, :content) || Map.get(choice, "content")
    if c == "", do: nil, else: c
  end

  defp choice_content(_), do: nil

  # Formats a tool result for inclusion in conversation history.
  # Bounded to avoid unbounded token growth.
  @max_tool_result_bytes 2_000
  defp format_tool_result(result, max_bytes \\ @max_tool_result_bytes) do
    text = inspect(result)

    if byte_size(text) > max_bytes do
      binary_part(text, 0, max_bytes) <> "...[truncated]"
    else
      text
    end
  end

  # Converts tool_call arguments to a JSON string for OpenAI-compatible history.
  # OpenAI requires arguments as a JSON string, not an object.
  defp tool_call_arguments_to_string(args) when is_binary(args), do: args

  defp tool_call_arguments_to_string(args) when is_map(args) do
    try do
      Jason.encode!(args)
    rescue
      _ -> "{}"
    end
  end

  defp tool_call_arguments_to_string(_), do: "{}"

  defp stringify_reason(reason) when is_binary(reason), do: reason
  defp stringify_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp stringify_reason(reason), do: inspect(reason)

  defp safe_reason_string(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp safe_reason_string(reason) when is_binary(reason), do: reason
  defp safe_reason_string(reason), do: inspect(reason)

  # --- Private: Async LLM helpers ---

  defp cancel_llm_timeout(%{pending_llm_task: %{timer_ref: timer_ref}} = state)
       when not is_nil(timer_ref) do
    Process.cancel_timer(timer_ref)
    %{state | pending_llm_task: %{state.pending_llm_task | timer_ref: nil}}
  end

  defp cancel_llm_timeout(state), do: state

  defp clear_pending_llm(state) do
    %{
      state
      | pending_llm_ref: nil,
        pending_llm_task: nil,
        llm_started_at: nil,
        current_operation: nil
    }
  end

  # --- Private: Ring buffer helpers ---

  defp ring_push(list, entries, max) do
    # Prepend entries newest-first, maintaining relative order
    list
    |> then(fn acc -> Enum.reduce(Enum.reverse(entries), acc, fn e, a -> [e | a] end) end)
    |> trim_list(max)
  end

  defp trim_list(list, max) when length(list) > max do
    Enum.take(list, max)
  end

  defp trim_list(list, _max), do: list

  defp notify_dispatcher(:complete, task_id, result, session_id) do
    # Agent Protocol: Worker→Dispatcher completion leg of
    # AgentProtocol.report_completion/1 (formal contract in P2.8)
    # Registry-based discovery replaces Process.whereis (spark-ard.19)
    registry_cast(:dispatcher, session_id, {:worker_complete, task_id, result})
  end

  defp notify_dispatcher(:failed, task_id, result, session_id) do
    # Agent Protocol: Worker→Dispatcher failure leg of
    # AgentProtocol.report_completion/1 (formal contract in P2.8)
    # Registry-based discovery replaces Process.whereis (spark-ard.19)
    registry_cast(:dispatcher, session_id, {:worker_failed, task_id, result})
  end

  defp schedule_heartbeat do
    Process.send_after(self(), :send_heartbeat, @heartbeat_interval)
  end

  # Registry-based agent discovery — looks up the target PID via
  # Spark.SessionRegistry and casts a message directly.
  # Falls back silently if the agent is not found (not yet started
  # or already terminated), matching the old Process.whereis guard.
  defp registry_cast(role, session_id, message) do
    case Spark.AgentProtocol.find(role, session_id) do
      {:ok, pid} ->
        try do
          GenServer.cast(pid, message)
        catch
          :exit, {:noproc, _} -> :ok
          :exit, {:nodedown, _} -> :ok
        end

      {:error, :not_found} ->
        :ok
    end
  end
end
