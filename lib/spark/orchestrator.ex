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
  alias Spark.Types.{Plan, Task, WorkerResult}
  alias Spark.LLM.{Cache, Client}
  alias Spark.EventBus

  @llm_call_timeout_ms 300_000
  @quick_call_timeout_ms 30_000

  @orchestrator_prompt """
  You are Spark's planning orchestrator.

  Your job is to convert the user's coding goal into a valid JSON execution plan.

  CRITICAL OUTPUT RULES:
  - Return ONLY valid JSON.
  - Do NOT include markdown fences.
  - Do NOT include prose before or after the JSON.
  - The top-level JSON object MUST contain: "user_goal", "summary", "tasks".
  - "tasks" MUST be a non-empty array.
  - Each task MUST contain: "id", "title", "description", "risk", "read_paths", "write_paths", "depends_on".
  - "risk" MUST be one of: "low", "medium", "high".
  - "read_paths", "write_paths", and "depends_on" MUST be arrays.
  - Use stable task IDs like "task_1", "task_2".
  - Dependencies must reference earlier task IDs only.

  JSON schema example:
  {
    "user_goal": "Build a menu feature",
    "summary": "Implement a menu feature with UI, logic, and tests.",
    "tasks": [
      {
        "id": "task_1",
        "title": "Inspect existing project structure",
        "description": "Review relevant files and identify where the menu should be implemented.",
        "risk": "low",
        "read_paths": ["."],
        "write_paths": [],
        "depends_on": []
      },
      {
        "id": "task_2",
        "title": "Implement menu feature",
        "description": "Add the menu feature in the appropriate files.",
        "risk": "medium",
        "read_paths": ["."],
        "write_paths": [],
        "depends_on": ["task_1"]
      }
    ]
  }
  """

  # --- Public API ---

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Submit user input, triggers planning."
  def run(user_input),
    do: GenServer.call(__MODULE__, {:run, user_input}, @llm_call_timeout_ms)

  @doc "Approve the active plan by plan_id."
  def approve_plan(plan_id),
    do: GenServer.call(__MODULE__, {:approve_plan, plan_id}, @quick_call_timeout_ms)

  @doc "Reject the active plan by plan_id."
  def reject_plan(plan_id, reason \\ "user rejected"),
    do: GenServer.call(__MODULE__, {:reject_plan, plan_id, reason}, @quick_call_timeout_ms)

  @doc "Modify the active plan with a new instruction, triggers re-plan."
  def modify_plan(plan_id, instruction),
    do: GenServer.call(__MODULE__, {:modify_plan, plan_id, instruction}, @llm_call_timeout_ms)

  @doc "Report a completed task result."
  def task_completed(result), do: GenServer.cast(__MODULE__, {:task_completed, result})

  @doc "Report a failed task result."
  def task_failed(result), do: GenServer.cast(__MODULE__, {:task_failed, result})

  @doc "Get current orchestrator state."
  def get_state, do: GenServer.call(__MODULE__, :get_state, @quick_call_timeout_ms)

  # --- GenServer Callbacks ---

  @impl true
  def init(opts) do
    state = State.new(Keyword.take(opts, [:session_id, :model, :prompt_version]))
    prefix = build_cached_prefix(state.prompt_version || "1")
    hash = Cache.prefix_hash(prefix)
    state = %{state | cached_prefix: prefix, cached_prefix_hash: hash}
    EventBus.subscribe("spark:hot_reload")
    {:ok, state}
  end

  # spark-anh.2: Planning flow
  @impl true
  def handle_call({:run, user_input}, _from, %State{phase: :awaiting_input} = state) do
    state = %{state | phase: :planning}
    history_entry = %{role: "user", content: user_input}
    state = %{state | history: state.history ++ [history_entry]}
    messages = build_messages(state, user_input)

    Logger.info("Orchestrator: calling LLM for goal: #{String.slice(user_input, 0, 80)}")

    case Client.complete(:orchestrator, messages, %{session_id: state.session_id}) do
      {:ok, response} ->
        Logger.info("Orchestrator: LLM response received, parsing plan")
        case parse_plan(response, user_input) do
          {:ok, plan} ->
            case Plan.validate(plan) do
              :ok ->
                plan = Plan.awaiting_approval(plan)
                state = %{state | phase: :awaiting_approval, active_plan: plan}

                EventBus.publish_plan(plan.id, :plan_awaiting_approval, %{
                  plan_id: plan.id,
                  summary: plan.summary
                })

                {:reply, {:ok, plan}, state}

              {:error, errors} ->
                state = %{state | phase: :awaiting_input}
                {:reply, {:error, {:plan_validation, errors}}, state}
            end

          {:error, reason} ->
            state = %{state | phase: :awaiting_input}
            {:reply, {:error, {:plan_parse, reason}}, state}
        end

      {:error, reason} ->
        Logger.error("Orchestrator: LLM call failed: #{inspect(reason)}")
        state = %{state | phase: :awaiting_input}
        {:reply, {:error, {:llm_error, reason}}, state}
    end
  end

  def handle_call({:run, _user_input}, _from, state) do
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
            :ok = Spark.Dispatcher.enqueue(plan_id, approved.tasks)
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
  def handle_call({:reject_plan, plan_id, reason}, _from, %State{phase: :awaiting_approval} = state) do
    case state.active_plan do
      %Plan{id: ^plan_id, approval_status: :awaiting_approval} = plan ->
        {:ok, rejected} = Plan.reject(plan)
        state = %{state | phase: :awaiting_input, active_plan: nil}
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

  # spark-anh.3: Approval gate — modify
  @impl true
  def handle_call({:modify_plan, plan_id, instruction}, _from, %State{phase: :awaiting_approval} = state) do
    case state.active_plan do
      %Plan{id: ^plan_id} = plan ->
        modified = Plan.modify(plan, %{"modification_instruction" => instruction})
        mod_entry = %{role: "user", content: "Modify the plan: #{instruction}"}
        state = %{state | history: state.history ++ [mod_entry], phase: :planning}
        messages = build_messages(state, "Modify the plan: #{instruction}")

        case Client.complete(:orchestrator, messages, %{session_id: state.session_id}) do
          {:ok, response} ->
            case parse_plan(response, modified.user_goal) do
              {:ok, new_plan} ->
                case Plan.validate(new_plan) do
                  :ok ->
                    new_plan = Plan.awaiting_approval(new_plan)
                    state = %{state | phase: :awaiting_approval, active_plan: new_plan}

                    EventBus.publish_plan(new_plan.id, :plan_awaiting_approval, %{
                      plan_id: new_plan.id,
                      summary: new_plan.summary
                    })

                    {:reply, {:ok, new_plan}, state}

                  {:error, errors} ->
                    state = %{state | phase: :awaiting_approval, active_plan: modified}
                    {:reply, {:error, {:plan_validation, errors}}, state}
                end

              {:error, reason} ->
                state = %{state | phase: :awaiting_approval, active_plan: modified}
                {:reply, {:error, {:plan_parse, reason}}, state}
            end

          {:error, reason} ->
            state = %{state | phase: :awaiting_approval, active_plan: modified}
            {:reply, {:error, {:llm_error, reason}}, state}
        end

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
  @impl true
  def handle_cast({:task_completed, %WorkerResult{} = result}, %State{phase: :executing} = state) do
    state = State.add_result(state, result)
    state = maybe_transition_to_review(state)
    {:noreply, state}
  end

  def handle_cast({:task_failed, %WorkerResult{} = result}, %State{phase: :executing} = state) do
    state = State.add_failed(state, result)
    state = maybe_transition_to_review(state)
    {:noreply, state}
  end

  def handle_cast({:task_completed, _}, state), do: {:noreply, state}
  def handle_cast({:task_failed, _}, state), do: {:noreply, state}

  # spark-anh.5: Final review — MUST be before catch-all handle_info
  @impl true
  def handle_info(:do_final_review, %State{phase: :reviewing} = state) do
    results = State.all_results(state)
    plan = state.active_plan

    EventBus.publish_plan(plan.id, :orchestrator_review_started, %{
      plan_id: plan.id,
      session_id: state.session_id
    })

    review_messages = build_review_messages(state, results, plan)

    case Client.complete(:orchestrator, review_messages, %{session_id: state.session_id}) do
      {:ok, response} ->
        review_content = extract_content(response)
        state = %{state | phase: :completed}

        EventBus.publish_plan(plan.id, :orchestrator_review_completed, %{
          plan_id: plan.id,
          session_id: state.session_id,
          review: review_content
        })

        {:noreply, state}

      {:error, reason} ->
        Logger.error("Orchestrator: final review LLM error: #{inspect(reason)}")
        state = %{state | phase: :completed}

        EventBus.publish_plan(plan.id, :orchestrator_review_completed, %{
          plan_id: plan.id,
          session_id: state.session_id,
          review: "Review failed: #{inspect(reason)}"
        })

        {:noreply, state}
    end
  end

  # spark-anh.6: Hot reload — prompt
  @impl true
  def handle_info(%Spark.Types.Event{type: :prompt_reloaded}, state) do
    Logger.info("Orchestrator: prompt reloaded, rebuilding cached prefix")
    prefix = build_cached_prefix(state.prompt_version)
    hash = Cache.prefix_hash(prefix)
    new_version = "v_#{:erlang.unique_integer([:positive])}"
    state = %{state | cached_prefix: prefix, cached_prefix_hash: hash, prompt_version: new_version}
    {:noreply, state}
  end

  # spark-anh.6: Hot reload — policy
  def handle_info(%Spark.Types.Event{type: :policy_reloaded}, %State{phase: :awaiting_approval} = state) do
    Logger.info("Orchestrator: policy reloaded, revalidating draft plan")

    case state.active_plan do
      %Plan{} = plan ->
        case Plan.validate(plan) do
          :ok -> {:noreply, state}
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

  # Catch-all for other EventBus events
  def handle_info(%Spark.Types.Event{type: type}, state) do
    Logger.debug("Orchestrator: ignoring event #{type}")
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

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
    [%{role: "system", content: @orchestrator_prompt}]
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
        tasks = build_tasks(json, plan_id)

        plan = Plan.new(%{
          id: plan_id,
          user_goal: json["user_goal"] || user_goal,
          summary: json["summary"] || "Auto-generated plan",
          tasks: tasks
        })

        {:ok, plan}

      {:error, _reason} ->
        {:error, :json_decode_failed}
    end
  end

  defp build_tasks(%{"tasks" => task_list}, plan_id) when is_list(task_list) do
    Enum.map(task_list, fn t ->
      Task.new(%{
        id: t["id"],
        title: t["title"] || "Untitled task",
        description: t["description"] || "",
        plan_id: t["plan_id"] || plan_id,
        risk: parse_risk(t["risk"]),
        write_paths: t["write_paths"] || [],
        read_paths: t["read_paths"] || [],
        depends_on: t["depends_on"] || []
      })
    end)
  end

  defp build_tasks(_, _plan_id), do: []

  defp generate_plan_id do
    "plan_" <> (:crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false))
  end

  defp parse_risk("low"), do: :low
  defp parse_risk("high"), do: :high
  defp parse_risk(_), do: :medium

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
        %{role: "system", content: "Review the following task results:\n#{Jason.encode!(review_payload, pretty: true)}"}
      ]
    ]

    Cache.build_messages(parts, prompt_version: state.prompt_version || "1")
  end

  # --- Private: State migration ---

  defp migrate_state(state, _payload), do: state
end
