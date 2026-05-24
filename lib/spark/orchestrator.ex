defmodule Spark.Orchestrator do
  @moduledoc """
  Central orchestrator GenServer for the Spark planning-execution loop.

  Phases: :awaiting_input → :planning → :awaiting_approval → :executing → :reviewing → :completed

  - spark-anh.2: Planning flow — run/1 builds plan via LLM
  - spark-anh.3: Approval gate — approve/reject/modify plan
  - spark-anh.4: Result reconciliation — collect task results
  - spark-anh.5: Final review — LLM reviews all results
  - spark-anh.6: Hot reload — reacts to prompt/policy/config reloads
  """

  use GenServer

  require Logger

  alias Spark.State
  alias Spark.Types.{Plan, Task, TaskRequest, WorkerResult}
  alias Spark.LLM.{Cache, Client}
  alias Spark.EventBus
  alias Spark.Orchestrator.Checkpoint
  alias Spark.AgentProtocol
  alias Spark.CodePuppyCompat

  @llm_call_timeout_ms 300_000
  @quick_call_timeout_ms 30_000

  # Fallback prompt delegates to CodePuppyCompat for DRY consistency.
  # build_cached_prefix/1 calls Prompt.Store.get(:orchestrator) first,
  # falling back to this only if the Store is unavailable.
  @orchestrator_prompt Spark.CodePuppyCompat.orchestrator_prompt()

  # --- Public API ---

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Submit user input, triggers planning."
  @spec run(String.t()) :: {:ok, Spark.Types.Plan.t()} | {:error, term()}
  def run(user_input),
    do: GenServer.call(__MODULE__, {:run, user_input}, @llm_call_timeout_ms)

  @doc "Submit user input with streaming output forwarded to tui_pid."
  @spec run_streaming(String.t(), pid()) :: {:ok, Spark.Types.Plan.t()} | {:error, term()}
  def run_streaming(user_input, tui_pid),
    do: GenServer.call(__MODULE__, {:run_streaming, user_input, tui_pid}, @llm_call_timeout_ms)

  @doc "Approve the active plan by plan_id."
  @spec approve_plan(String.t()) :: {:ok, Spark.Types.Plan.t()} | {:error, term()}
  def approve_plan(plan_id),
    do: GenServer.call(__MODULE__, {:approve_plan, plan_id}, @quick_call_timeout_ms)

  @doc "Reject the active plan by plan_id."
  @spec reject_plan(String.t(), String.t()) :: {:ok, Spark.Types.Plan.t()} | {:error, term()}
  def reject_plan(plan_id, reason \\ "user rejected"),
    do: GenServer.call(__MODULE__, {:reject_plan, plan_id, reason}, @quick_call_timeout_ms)

  @doc "Modify the active plan with a new instruction, triggers re-plan."
  @spec modify_plan(String.t(), String.t()) :: {:ok, Spark.Types.Plan.t()} | {:error, term()}
  def modify_plan(plan_id, instruction),
    do: GenServer.call(__MODULE__, {:modify_plan, plan_id, instruction}, @llm_call_timeout_ms)

  @doc "Report a completed task result."
  @spec task_completed(Spark.Types.WorkerResult.t()) :: :ok
  def task_completed(result), do: GenServer.cast(__MODULE__, {:task_completed, result})

  @doc "Report a failed task result."
  @spec task_failed(Spark.Types.WorkerResult.t()) :: :ok
  def task_failed(result), do: GenServer.cast(__MODULE__, {:task_failed, result})

  @doc "Get current orchestrator state."
  @spec get_state() :: Spark.State.t()
  def get_state, do: GenServer.call(__MODULE__, :get_state, @quick_call_timeout_ms)

  # --- GenServer Callbacks ---

  @impl true
  def init(opts) do
    state = State.new(Keyword.take(opts, [:session_id, :model, :prompt_version]))

    initial_version =
      state.prompt_version ||
        try do
          Spark.Prompt.Store.version(:orchestrator)
        rescue
          _ -> "1"
        catch
          _, _ -> "1"
        end

    prefix = build_cached_prefix(initial_version)
    hash = Cache.prefix_hash(prefix)

    state = %{
      state
      | cached_prefix: prefix,
        cached_prefix_hash: hash,
        prompt_version: initial_version
    }

    # Attempt checkpoint restore for crash recovery
    state = restore_checkpoint(state)

    Logger.metadata(
      session_id: state.session_id,
      plan_id: nil,
      phase: state.phase,
      actor: :orchestrator
    )

    # Register in SessionRegistry for agent discovery (AgentProtocol)
    AgentProtocol.register(:orchestrator, state.session_id)

    # Schedule periodic checkpointing
    Process.send_after(self(), :checkpoint, 30_000)

    EventBus.subscribe("spark:hot_reload")
    {:ok, state}
  end

  # spark-anh.2: Planning flow — async Task + GenServer.reply/2
  @impl true
  def handle_call({:run, user_input}, from, %State{phase: :awaiting_input} = state) do
    prev_phase = state.phase
    state = %{state | phase: :planning}
    history_entry = %{role: "user", content: user_input}
    state = %{state | history: state.history ++ [history_entry], pending_reply: from}
    update_orch_metadata(state)

    CodePuppyCompat.publish_state_transition(prev_phase, :planning, %{session_id: state.session_id}, "user submitted goal")
    CodePuppyCompat.publish_reasoning(:thinking, "Beginning analysis of user goal: #{String.slice(user_input, 0, 80)}", %{session_id: state.session_id, source: :orchestrator})

    messages = build_messages(state, user_input)

    Logger.info("Orchestrator: calling LLM for goal: #{String.slice(user_input, 0, 80)}")

    parent = self()
    session_id = state.session_id

    llm_timeout = Spark.Config.get([:orchestrator, :llm_timeout_ms], 120_000)
    timer_ref = Process.send_after(self(), {:llm_timeout, :run, from}, llm_timeout)

    Elixir.Task.Supervisor.async_nolink(Spark.ToolSupervisor, fn ->
      result =
        Client.complete(:orchestrator, messages, %{
          session_id: session_id,
          mock_caller_pid: parent
        })

      send(parent, {:llm_response, :run, from, result, user_input})
    end)

    state = %{state | pending_llm_timer: timer_ref}
    {:noreply, state}
  end

  def handle_call({:run, _user_input}, _from, state) do
    {:reply, {:error, {:invalid_phase, state.phase}}, state}
  end

  # Phase 3: Streaming LLM call
  def handle_call(
        {:run_streaming, user_input, tui_pid},
        from,
        %State{phase: :awaiting_input} = state
      ) do
    prev_phase = state.phase
    state = %{state | phase: :planning}
    history_entry = %{role: "user", content: user_input}
    state = %{state | history: state.history ++ [history_entry], pending_reply: from}
    update_orch_metadata(state)

    CodePuppyCompat.publish_state_transition(prev_phase, :planning, %{session_id: state.session_id}, "user submitted goal (streaming)")
    CodePuppyCompat.publish_reasoning(:thinking, "Beginning streaming analysis of user goal: #{String.slice(user_input, 0, 80)}", %{session_id: state.session_id, source: :orchestrator})

    messages = build_messages(state, user_input)

    Logger.info("Orchestrator: streaming LLM for goal: #{String.slice(user_input, 0, 80)}")

    # Send stream_started immediately so TUI shows the planning canvas
    # before the first token arrives
    send(tui_pid, {:stream_started, %{goal: String.slice(user_input, 0, 80)}})

    parent = self()
    session_id = state.session_id

    stream_callback = fn
      {:chunk, %{delta: %{content: text}}} when is_binary(text) and text != "" ->
        Logger.debug("Orchestrator stream: sending #{byte_size(text)} bytes to TUI")
        send(tui_pid, {:stream_chunk, text})

      {:chunk, %{delta: %{content: text}, type: :reasoning}} when is_binary(text) and text != "" ->
        Logger.debug("Orchestrator stream: sending #{byte_size(text)} reasoning bytes to TUI")
        send(tui_pid, {:stream_chunk, %{type: :reasoning, text: text}})

      {:done, {:ok, response}} ->
        Logger.info("Orchestrator stream: done OK, forwarding to parent")
        send(tui_pid, {:stream_done, %{}})
        send(parent, {:llm_response, :run, from, {:ok, response}, user_input})

      {:done, {:error, reason}} ->
        Logger.warning("Orchestrator stream: done ERROR #{inspect(reason)}")
        send(tui_pid, {:stream_error, reason})
        send(parent, {:llm_response, :run, from, {:error, reason}, user_input})

      other ->
        Logger.debug("Orchestrator stream: unexpected callback event #{inspect(other)}")
        :ok
    end

    llm_timeout = Spark.Config.get([:orchestrator, :llm_timeout_ms], 120_000)
    timer_ref = Process.send_after(self(), {:llm_timeout, :run, from}, llm_timeout)

    Elixir.Task.start(fn ->
      Logger.info("Orchestrator stream: starting Client.stream for goal")

      try do
        result =
          Client.stream(
            :orchestrator,
            messages,
            %{session_id: session_id, mock_caller_pid: parent},
            stream_callback
          )

        Logger.info("Orchestrator stream: Client.stream returned with #{inspect(result)}")

        case result do
          {:error, reason} ->
            Logger.error("Orchestrator stream: Client.stream error: #{inspect(reason)}")
            # Callback {:done, _} never fired, so we must notify both TUI and orchestrator
            send(tui_pid, {:stream_error, reason})
            send(parent, {:llm_response, :run, from, {:error, reason}, user_input})

          _ ->
            :ok
        end
      rescue
        e ->
          Logger.error("Orchestrator stream: Client.stream crashed: #{Exception.message(e)}")

          send(
            tui_pid,
            {:stream_error, {:stream_crash, Exception.message(e)}}
          )

          send(
            parent,
            {:llm_response, :run, from, {:error, {:stream_crash, Exception.message(e)}},
             user_input}
          )
      catch
        :exit, reason ->
          Logger.error("Orchestrator stream: Client.stream exit: #{inspect(reason)}")
          send(tui_pid, {:stream_error, {:stream_exit, reason}})
          send(parent, {:llm_response, :run, from, {:error, {:stream_exit, reason}}, user_input})
      end

      :ok
    end)

    state = %{state | pending_llm_timer: timer_ref}
    {:noreply, state}
  end

  def handle_call({:run_streaming, _user_input, _tui_pid}, _from, state) do
    {:reply, {:error, {:invalid_phase, state.phase}}, state}
  end

  # spark-anh.3: Approval gate — approve
  @impl true
  def handle_call({:approve_plan, plan_id}, _from, %State{phase: :awaiting_approval} = state) do
    case state.active_plan do
      %Plan{id: ^plan_id, approval_status: :awaiting_approval} = plan ->
        case Plan.approve(plan) do
          {:ok, approved} ->
            state = %{state | phase: :executing, active_plan: approved}
            update_orch_metadata(state)
            maybe_checkpoint(state)

            CodePuppyCompat.publish_state_transition(:awaiting_approval, :executing, %{session_id: state.session_id, plan_id: plan_id}, "plan approved")
            CodePuppyCompat.publish_reasoning(:handoff, CodePuppyCompat.handoff_phrase(), %{session_id: state.session_id, plan_id: plan_id, source: :orchestrator})

            # Publish explicit coding_handoff event for TUI
            EventBus.publish_event(:coding_handoff, %{message: CodePuppyCompat.handoff_phrase(), plan_id: plan_id},
              session_id: state.session_id,
              plan_id: plan_id,
              source: :orchestrator
            )

            # Agent Protocol: wrap each task into a TaskRequest envelope
            # (formal contract — existing enqueue call still works, P2.8 migrates)
            _task_requests =
              for task <- approved.tasks do
                TaskRequest.new(%{
                  plan_id: plan_id,
                  task_spec: %{
                    id: task.id,
                    title: task.title,
                    description: task.description,
                    risk: task.risk,
                    read_paths: task.read_paths,
                    write_paths: task.write_paths,
                    depends_on: task.depends_on
                  },
                  context: %{session_id: state.session_id},
                  timeout_ms: task.timeout_ms
                })
              end

            :ok = Spark.Dispatcher.enqueue(plan_id, approved.tasks, session_id: state.session_id)
            EventBus.publish_plan(plan_id, :plan_approved, %{plan_id: plan_id})
            {:reply, {:ok, approved}, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      %Plan{id: ^plan_id} ->
        {:reply, {:error, :plan_not_awaiting_approval}, state}

      _ ->
        {:reply, {:error, :plan_id_mismatch}, state}
    end
  end

  def handle_call({:approve_plan, _plan_id}, _from, state) do
    {:reply, {:error, {:invalid_phase, state.phase}}, state}
  end

  # spark-anh.3: Approval gate — reject
  @impl true
  def handle_call(
        {:reject_plan, plan_id, reason},
        _from,
        %State{phase: :awaiting_approval} = state
      ) do
    case state.active_plan do
      %Plan{id: ^plan_id, approval_status: :awaiting_approval} = plan ->
        {:ok, rejected} = Plan.reject(plan)
        state = %{state | phase: :awaiting_input, active_plan: nil}
        update_orch_metadata(state)

        CodePuppyCompat.publish_state_transition(:awaiting_approval, :awaiting_input, %{session_id: state.session_id, plan_id: plan_id}, "plan rejected: #{reason}")

        EventBus.publish_plan(plan_id, :plan_rejected, %{plan_id: plan_id, reason: reason})
        {:reply, {:ok, rejected}, state}

      %Plan{id: ^plan_id} ->
        {:reply, {:error, :plan_not_awaiting_approval}, state}

      _ ->
        {:reply, {:error, :plan_id_mismatch}, state}
    end
  end

  def handle_call({:reject_plan, _plan_id, _reason}, _from, state) do
    {:reply, {:error, {:invalid_phase, state.phase}}, state}
  end

  # spark-anh.3: Approval gate — modify (async Task + GenServer.reply/2)
  @impl true
  def handle_call(
        {:modify_plan, plan_id, instruction},
        from,
        %State{phase: :awaiting_approval} = state
      ) do
    case state.active_plan do
      %Plan{id: ^plan_id} = plan ->
        modified = Plan.modify(plan, %{"modification_instruction" => instruction})
        mod_entry = %{role: "user", content: "Modify the plan: #{instruction}"}

        state = %{
          state
          | history: state.history ++ [mod_entry],
            phase: :planning,
            pending_reply: from
        }

        update_orch_metadata(state)

        CodePuppyCompat.publish_state_transition(:awaiting_approval, :planning, %{session_id: state.session_id, plan_id: plan_id}, "plan modification requested: #{String.slice(instruction, 0, 80)}")

        messages = build_messages(state, "Modify the plan: #{instruction}")

        parent = self()
        session_id = state.session_id

        Elixir.Task.start(fn ->
          result =
            Client.complete(:orchestrator, messages, %{
              session_id: session_id,
              mock_caller_pid: parent
            })

          send(parent, {:llm_response, :modify_plan, from, result, modified})
        end)

        {:noreply, state}

      _ ->
        {:reply, {:error, :plan_id_mismatch}, state}
    end
  end

  def handle_call({:modify_plan, _plan_id, _instruction}, _from, state) do
    {:reply, {:error, {:invalid_phase, state.phase}}, state}
  end

  @impl true
  def handle_call(:get_state, _from, state), do: {:reply, state, state}

  # spark-anh.4: Result reconciliation
  # Agent Protocol: receiving side — Dispatcher casts these via
  # AgentProtocol.report_completion/1 (formal contract in P2.8)
  @impl true
  def handle_cast({:task_completed, %WorkerResult{} = result}, %State{phase: :executing} = state) do
    state = State.add_result(state, result)
    state = maybe_transition_to_review(state)
    {:noreply, state}
  end

  def handle_cast({:task_failed, %WorkerResult{} = result}, %State{phase: :executing} = state) do
    # Agent Protocol: receiving side — see AgentProtocol.report_completion/1
    state = State.add_failed(state, result)
    state = maybe_transition_to_review(state)
    {:noreply, state}
  end

  def handle_cast({:task_completed, _}, state), do: {:noreply, state}
  def handle_cast({:task_failed, _}, state), do: {:noreply, state}

  # spark-anh.2/3: LLM response handlers — receive Task results and reply via GenServer.reply/2
  @impl true
  def handle_info({:llm_response, :run, from, result, user_input}, state) do
    state = cancel_llm_timer(state)

    case process_run_result(result, user_input, state) do
      {:retry, new_state} ->
        # Store from in metadata for the retry handler
        {:noreply, %{new_state | metadata: Map.put(new_state.metadata, :pending_from, from)}}

      {reply, new_state} ->
        new_state = %{new_state | pending_reply: nil}
        GenServer.reply(from, reply)
        {:noreply, new_state}
    end
  end

  def handle_info({:llm_response, :run_retry, result, user_input}, state) do
    state = cancel_llm_timer(state)
    from = Map.get(state.metadata, :pending_from)
    {reply, new_state} = process_run_result(result, user_input, state)

    new_state = %{
      new_state
      | pending_reply: nil,
        metadata: Map.delete(new_state.metadata, :pending_from)
    }

    if from, do: GenServer.reply(from, reply)
    {:noreply, new_state}
  end

  # LLM timeout handler — reply to the pending caller with an error
  def handle_info({:llm_timeout, :run, from}, state) do
    Logger.error(
      "Orchestrator: LLM call timed out after #{Spark.Config.get([:orchestrator, :llm_timeout_ms], 120_000)}ms"
    )

    state = %{state | phase: :awaiting_input, active_plan: nil, pending_reply: nil}
    update_orch_metadata(state)

    CodePuppyCompat.publish_state_transition(:planning, :awaiting_input, %{session_id: state.session_id}, "LLM call timed out")

    GenServer.reply(from, {:error, :llm_timeout})
    {:noreply, state}
  end

  def handle_info({:llm_response, :modify_plan, from, result, modified}, state) do
    state = %{state | pending_reply: nil}
    {reply, new_state} = process_modify_result(result, modified, state)
    GenServer.reply(from, reply)
    {:noreply, new_state}
  end

  # spark-anh.5: Final review — async Task for LLM call
  @impl true
  def handle_info(:do_final_review, %State{phase: :reviewing} = state) do
    results = State.all_results(state)
    plan = state.active_plan

    EventBus.publish_plan(plan.id, :orchestrator_review_started, %{
      plan_id: plan.id,
      session_id: state.session_id
    })

    review_messages = build_review_messages(state, results, plan)

    parent = self()
    session_id = state.session_id
    plan_id = plan.id

    Elixir.Task.start(fn ->
      result =
        Client.complete(:orchestrator, review_messages, %{
          session_id: session_id,
          mock_caller_pid: parent
        })

      send(parent, {:llm_response, :final_review, result, plan_id, session_id})
    end)

    {:noreply, state}
  end

  def handle_info({:llm_response, :final_review, result, plan_id, session_id}, state) do
    case result do
      {:ok, response} ->
        review_content = extract_content(response)
        state = %{state | phase: :completed}
        update_orch_metadata(state)
        maybe_checkpoint(state)

        CodePuppyCompat.publish_state_transition(:reviewing, :completed, %{session_id: session_id, plan_id: plan_id}, "review completed successfully")

        EventBus.publish_plan(plan_id, :orchestrator_review_completed, %{
          plan_id: plan_id,
          session_id: session_id,
          review: review_content
        })

        {:noreply, state}

      {:error, reason} ->
        Logger.error("Orchestrator: final review LLM error: #{inspect(reason)}")
        state = %{state | phase: :completed}
        update_orch_metadata(state)
        maybe_checkpoint(state)

        CodePuppyCompat.publish_state_transition(:reviewing, :completed, %{session_id: session_id, plan_id: plan_id}, "review failed")

        EventBus.publish_plan(plan_id, :orchestrator_review_completed, %{
          plan_id: plan_id,
          session_id: session_id,
          review: "Review failed: #{inspect(reason)}"
        })

        {:noreply, state}
    end
  end

  # spark-anh.6: Hot reload — prompt
  @impl true
  def handle_info(%Spark.Types.Event{type: :prompt_reloaded}, state) do
    Logger.info("Orchestrator: prompt reloaded, rebuilding cached prefix")

    new_version =
      try do
        Spark.Prompt.Store.version(:orchestrator)
      rescue
        _ -> "v_#{:erlang.unique_integer([:positive])}"
      catch
        _, _ -> "v_#{:erlang.unique_integer([:positive])}"
      end

    prefix = build_cached_prefix(new_version)
    hash = Cache.prefix_hash(prefix)

    state = %{
      state
      | cached_prefix: prefix,
        cached_prefix_hash: hash,
        prompt_version: new_version
    }

    {:noreply, state}
  end

  # spark-anh.6: Hot reload — policy
  def handle_info(
        %Spark.Types.Event{type: :policy_reloaded},
        %State{phase: :awaiting_approval} = state
      ) do
    Logger.info("Orchestrator: policy reloaded, revalidating draft plan")

    case state.active_plan do
      %Plan{} = plan ->
        case Plan.validate(plan) do
          :ok ->
            {:noreply, state}

          {:error, errors} ->
            Logger.warning("Orchestrator: plan invalidated by policy reload: #{inspect(errors)}")
            {:noreply, state}
        end

      nil ->
        {:noreply, state}
    end
  end

  def handle_info(%Spark.Types.Event{type: :policy_reloaded}, state), do: {:noreply, state}

  # spark-anh.6: Hot reload — config
  def handle_info(%Spark.Types.Event{type: :config_reloaded}, state) do
    Logger.info("Orchestrator: config reloaded, updating model for future calls")
    new_model = Spark.Config.get([:llm, :orchestrator_model])
    state = %{state | model: new_model}
    {:noreply, state}
  end

  # spark-anh.6: Hot reload — code
  def handle_info(%Spark.Types.Event{type: :code_reloaded, payload: payload}, state) do
    Logger.info("Orchestrator: code reloaded, running state migration hook")
    state = migrate_state(state, payload)
    {:noreply, state}
  end

  # Periodic state checkpointing
  @impl true
  def handle_info(:checkpoint, state) do
    Checkpoint.save(state)
    Process.send_after(self(), :checkpoint, 30_000)
    {:noreply, state}
  end

  # Catch-all for other EventBus events
  def handle_info(%Spark.Types.Event{type: type}, state) do
    Logger.debug("Orchestrator: ignoring event #{type}")
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Private: LLM result processing ---

  defp has_empty_tasks_error?(errors) do
    Enum.any?(errors, fn
      {:tasks, "must not be empty"} -> true
      _ -> false
    end)
  end

  defp process_run_result({:ok, response}, user_input, state) do
    Logger.info("Orchestrator: LLM response received, parsing plan")

    case parse_plan(response, user_input) do
      {:ok, plan} ->
        case Plan.validate(plan) do
          :ok ->
            plan = Plan.awaiting_approval(plan)
            state = %{state | phase: :awaiting_approval, active_plan: plan}
            update_orch_metadata(state)
            maybe_checkpoint(state)

            CodePuppyCompat.publish_state_transition(:planning, :awaiting_approval, %{session_id: state.session_id, plan_id: plan.id}, "plan parsed successfully: #{String.slice(plan.summary, 0, 80)}")
            CodePuppyCompat.publish_reasoning(:planning, "Plan generated: #{String.slice(plan.summary, 0, 100)}", %{session_id: state.session_id, plan_id: plan.id, source: :orchestrator})

            EventBus.publish_plan(plan.id, :plan_awaiting_approval, %{
              plan_id: plan.id,
              summary: plan.summary
            })

            {{:ok, plan}, state}

          {:error, errors} ->
            if has_empty_tasks_error?(errors) and
                 not Map.get(state.metadata, :empty_tasks_retried, false) do
              Logger.warning(
                "Orchestrator: plan has empty tasks — retrying LLM call with schema reminder"
              )

              retry_state = %{
                state
                | metadata: Map.put(state.metadata, :empty_tasks_retried, true)
              }

              messages = build_messages(retry_state, user_input)

              schema_reminder = %{
                role: "system",
                content:
                  "CRITICAL: Your previous response was missing the required \"tasks\" array in the JSON output. The JSON MUST include a non-empty \"tasks\" array with at least one task object. Each task must have: id, title, description, risk (low|medium|high), read_paths (array of file paths), write_paths (array of file paths), depends_on (array of task IDs). See the JSON OUTPUT SCHEMA FORMAT in your system prompt. Return a complete JSON response with a non-empty tasks array NOW."
              }

              parent = self()
              session_id = retry_state.session_id

              Elixir.Task.start(fn ->
                result =
                  Client.complete(:orchestrator, [schema_reminder | messages], %{
                    session_id: session_id,
                    mock_caller_pid: parent
                  })

                send(parent, {:llm_response, :run_retry, result, user_input})
              end)

              {:retry, retry_state}
            else
              state = %{state | phase: :awaiting_input}
              update_orch_metadata(state)
              CodePuppyCompat.publish_state_transition(:planning, :awaiting_input, %{session_id: state.session_id}, "plan validation failed")
              {{:error, {:plan_validation, errors}}, state}
            end
        end

      {:error, reason} ->
        state = %{state | phase: :awaiting_input}
        update_orch_metadata(state)
        CodePuppyCompat.publish_state_transition(:planning, :awaiting_input, %{session_id: state.session_id}, "plan parse failed")
        {{:error, {:plan_parse, reason}}, state}
    end
  end

  defp process_run_result({:error, reason}, _user_input, state) do
    Logger.error("Orchestrator: LLM call failed: #{inspect(reason)}")
    state = %{state | phase: :awaiting_input}
    update_orch_metadata(state)
    CodePuppyCompat.publish_state_transition(:planning, :awaiting_input, %{session_id: state.session_id}, "LLM call failed")
    {{:error, {:llm_error, reason}}, state}
  end

  defp process_modify_result({:ok, response}, modified, state) do
    case parse_plan(response, modified.user_goal) do
      {:ok, new_plan} ->
        case Plan.validate(new_plan) do
          :ok ->
            new_plan = Plan.awaiting_approval(new_plan)
            state = %{state | phase: :awaiting_approval, active_plan: new_plan}
            update_orch_metadata(state)
            maybe_checkpoint(state)

            CodePuppyCompat.publish_state_transition(:planning, :awaiting_approval, %{session_id: state.session_id, plan_id: new_plan.id}, "plan modified successfully")

            EventBus.publish_plan(new_plan.id, :plan_awaiting_approval, %{
              plan_id: new_plan.id,
              summary: new_plan.summary
            })

            {{:ok, new_plan}, state}

          {:error, errors} ->
            state = %{state | phase: :awaiting_approval, active_plan: modified}
            update_orch_metadata(state)
            {{:error, {:plan_validation, errors}}, state}
        end

      {:error, reason} ->
        state = %{state | phase: :awaiting_approval, active_plan: modified}
        update_orch_metadata(state)
        {{:error, {:plan_parse, reason}}, state}
    end
  end

  defp process_modify_result({:error, reason}, modified, state) do
    state = %{state | phase: :awaiting_approval, active_plan: modified}
    update_orch_metadata(state)
    {{:error, {:llm_error, reason}}, state}
  end

  # --- Private: Planning ---

  defp build_messages(state, user_input) do
    parts = [
      static_prefix: state.cached_prefix,
      session_history: format_history(state.history),
      current_user_input: [%{role: "user", content: user_input}]
    ]

    Cache.build_messages(parts, prompt_version: state.prompt_version || "1")
  end

  defp format_history(history) do
    Enum.map(history, fn entry ->
      %{role: to_string(entry.role), content: entry.content}
    end)
  end

  defp build_cached_prefix(_version) do
    prompt =
      try do
        Spark.Prompt.Store.get(:orchestrator)
      rescue
        _ -> @orchestrator_prompt
      catch
        _, _ -> @orchestrator_prompt
      end

    [%{role: "system", content: prompt}]
  end

  defp parse_plan(response, user_goal) do
    content = extract_content(response)

    case extract_json(content) do
      {:ok, json} -> build_plan(json, user_goal)
      :no_json -> {:error, :no_json_in_response}
    end
  end

  defp extract_content(%{choices: [%{message: %{content: content}} | _]}), do: content
  defp extract_content(%{"choices" => [%{"message" => %{"content" => content}} | _]}), do: content
  defp extract_content(content) when is_binary(content), do: content
  defp extract_content(_), do: ""

  defp extract_json(content) when is_binary(content) do
    cond do
      match = Regex.run(~r/```json\s*(.*?)\s*```/s, content) ->
        {:ok, Enum.at(match, 1)}

      match = Regex.run(~r/\{.*\}/s, content) ->
        {:ok, Enum.at(match, 0)}

      true ->
        :no_json
    end
  end

  defp extract_json(_), do: :no_json

  defp build_plan(json_str, user_goal) do
    case Jason.decode(json_str) do
      {:ok, json} ->
        plan_id = json["id"] || generate_plan_id()

        # Normalize: some LLMs nest tasks under "plan" key
        normalized = normalize_plan_json(json)
        tasks = build_tasks(normalized, plan_id)

        summary =
          normalized["summary"] ||
            json["plan"]["summary"] ||
            "Auto-generated plan"

        plan =
          Plan.new(%{
            id: plan_id,
            user_goal: normalized["user_goal"] || json["goal"] || user_goal,
            summary: summary,
            tasks: tasks
          })

        {:ok, plan}

      {:error, _reason} ->
        {:error, :json_decode_failed}
    end
  end

  # Handles different JSON schemas from various LLMs:
  #   1. Direct: {"user_goal": ..., "tasks": [...]}
  #   2. Nested: {"goal": ..., "plan": {"tasks": [...]}}
  #   3. Flat: {"tasks": [...]}
  defp normalize_plan_json(json) do
    cond do
      is_list(json["tasks"]) ->
        json

      is_map(json["plan"]) and is_list(json["plan"]["tasks"]) ->
        # Flatten nested structure
        nested = json["plan"]

        Map.merge(json, %{
          "tasks" => nested["tasks"],
          "summary" => nested["summary"],
          "user_goal" => json["user_goal"] || json["goal"]
        })

      true ->
        json
    end
  end

  defp build_tasks(%{"tasks" => task_list}, plan_id) when is_list(task_list) do
    if task_list == [] do
      Logger.warning("Orchestrator: LLM returned plan JSON with empty \"tasks\" array")
    end

    Enum.map(task_list, fn t ->
      # Normalize: some LLMs use "instruction" or "description" field
      description = t["description"] || t["instruction"] || t["action"] || ""
      title = t["title"] || t["agent"] || infer_title(description) || "Untitled task"

      Task.new(%{
        id: t["id"] || generate_task_id(),
        title: title,
        description: description,
        plan_id: t["plan_id"] || plan_id,
        risk: parse_risk(t["risk"]),
        write_paths: t["write_paths"] || infer_paths(description, :write),
        read_paths: t["read_paths"] || infer_paths(description, :read),
        depends_on: t["depends_on"] || []
      })
    end)
  end

  defp build_tasks(_, _plan_id) do
    Logger.warning(
      "Orchestrator: LLM returned plan JSON without \"tasks\" key or with non-list tasks — falling back to empty list"
    )

    []
  end

  defp generate_plan_id do
    "plan_" <> (:crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false))
  end

  defp generate_task_id do
    "task_" <> (:crypto.strong_rand_bytes(4) |> Base.url_encode64(padding: false))
  end

  defp parse_risk("low"), do: :low
  defp parse_risk("high"), do: :high
  defp parse_risk(_), do: :medium

  # Infer a title from the first line of the description
  defp infer_title(description) when is_binary(description) and byte_size(description) > 0 do
    description
    |> String.split(~r/\n/, parts: 2)
    |> hd()
    |> String.slice(0, 60)
    |> String.trim()
  end

  defp infer_title(_), do: nil

  # Infer file paths from the description text (e.g. "Create hello.ex")
  defp infer_paths(description, :write) when is_binary(description) do
    Regex.scan(
      ~r/(?:create|write|modify|edit)\s+([\w.\/-]+\.(?:ex|exs|erl|json|yaml|yml|md|txt|toml|cfg|conf))/i,
      description
    )
    |> Enum.map(&List.first/1)
    |> Enum.reject(&is_nil/1)
  end

  defp infer_paths(description, :read) when is_binary(description) do
    Regex.scan(
      ~r/(?:read|inspect|analyze|check)\s+([\w.\/-]+\.(?:ex|exs|erl|json|yaml|yml|md|txt|toml|cfg|conf))/i,
      description
    )
    |> Enum.map(&List.first/1)
    |> Enum.reject(&is_nil/1)
  end

  defp infer_paths(_, _), do: []

  # --- Private: Result reconciliation ---

  defp maybe_transition_to_review(%State{active_plan: nil} = state), do: state

  defp maybe_transition_to_review(%State{active_plan: plan} = state) do
    all_ids = Plan.task_ids(plan) |> MapSet.new()

    done_ids =
      MapSet.union(
        MapSet.new(Map.keys(state.completed_results)),
        MapSet.new(Map.keys(state.failed_results))
      )

    if MapSet.subset?(all_ids, done_ids) do
      state = %{state | phase: :reviewing}
      update_orch_metadata(state)
      maybe_checkpoint(state)
      CodePuppyCompat.publish_state_transition(:executing, :reviewing, %{session_id: state.session_id, plan_id: state.active_plan.id}, "all tasks completed")
      send(self(), :do_final_review)
      state
    else
      state
    end
  end

  # --- Private: Final review ---

  defp build_review_messages(state, results, plan) do
    result_summaries =
      results
      |> Enum.map(fn {task_id, result} ->
        %{task_id: task_id, status: result.status, summary: result.summary}
      end)

    review_payload = %{
      plan_id: plan.id,
      goal: plan.user_goal,
      total_tasks: length(plan.tasks),
      results: result_summaries
    }

    parts = [
      static_prefix: state.cached_prefix,
      session_history: format_history(state.history),
      worker_result: [
        %{
          role: "system",
          content:
            "Review the following task results:\n#{Jason.encode!(review_payload, pretty: true)}"
        }
      ]
    ]

    Cache.build_messages(parts, prompt_version: state.prompt_version || "1")
  end

  # --- Private: State migration ---

  defp migrate_state(state, _payload), do: state

  # --- Private: Checkpointing ---

  @checkpoint_phases [:awaiting_approval, :executing, :reviewing, :completed]

  defp maybe_checkpoint(%State{phase: phase} = state) when phase in @checkpoint_phases do
    Checkpoint.save(state)
  end

  defp maybe_checkpoint(_state), do: :ok

  defp update_orch_metadata(state) do
    Logger.metadata(
      session_id: state.session_id,
      plan_id: if(state.active_plan, do: state.active_plan.id, else: nil),
      phase: state.phase,
      actor: :orchestrator
    )
  end

  defp cancel_llm_timer(%{pending_llm_timer: nil} = state), do: state

  defp cancel_llm_timer(%{pending_llm_timer: ref} = state) when is_reference(ref) do
    Process.cancel_timer(ref)
    %{state | pending_llm_timer: nil}
  end

  defp cancel_llm_timer(state), do: %{state | pending_llm_timer: nil}

  defp restore_checkpoint(%State{session_id: session_id} = state) do
    case Checkpoint.restore(session_id) do
      {:ok, cp} ->
        Logger.info(
          "Orchestrator: restored checkpoint for session #{session_id} (phase: #{cp.phase})"
        )

        state = %{
          state
          | phase: cp.phase,
            active_plan: cp.active_plan,
            completed_results: cp.completed_results,
            failed_results: cp.failed_results
        }

        update_orch_metadata(state)
        state

      :no_checkpoint ->
        state

      {:error, :stale_checkpoint} ->
        Logger.info("Orchestrator: stale checkpoint for session #{session_id}, starting fresh")
        state

      {:error, reason} ->
        Logger.warning("Orchestrator: checkpoint restore failed: #{inspect(reason)}")
        state
    end
  end
end
