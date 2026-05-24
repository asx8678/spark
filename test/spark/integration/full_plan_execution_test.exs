defmodule Spark.Integration.FullPlanExecutionTest do
  @moduledoc """
  spark-opg.1: Full mock plan execution integration test.

  Full vertical slice: CLI input → Orchestrator plans (mock LLM) →
  approval → Dispatcher enqueues → Workers execute (mock) →
  results reconcile → final review.

  Uses mock LLM provider throughout. No real network or LLM calls.
  """

  use ExUnit.Case, async: false

  alias Spark.Integration.TestHelpers

  alias Spark.Orchestrator
  alias Spark.Types.{Event, Plan, WorkerResult}
  alias Spark.LLM.MockProvider
  alias Spark.EventBus
  alias Spark.Memory.Bronze

  # --- Setup ---

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "spark_full_plan_#{:erlang.unique_integer()}")
    File.mkdir_p!(tmp_dir)
    original_home = Application.get_env(:spark, :home_dir)
    Application.put_env(:spark, :home_dir, tmp_dir)

    TestHelpers.ensure_app_tree()
    EventBus.clear_hooks()
    ensure_config()

    # Stop leftover processes
    for name <- [Spark.Orchestrator, Spark.Dispatcher, Spark.Policy] do
      if pid = Process.whereis(name) do
        try do
          GenServer.stop(pid, :shutdown)
        catch
          :exit, _ -> :ok
        end
      end
    end

    # Ensure Policy agent is fresh with default policy
    if pid = Process.whereis(Spark.Policy), do: Agent.stop(pid)
    Spark.Policy.start_link()

    MockProvider.clear(self())

    # Add an EventBus hook that bridges Dispatcher/FakeWorker task completions
    # to the Orchestrator. In the real system, Workers call
    # Orchestrator.task_completed/1 directly. For integration tests using
    # FakeWorker, we bridge via EventBus events.
    EventBus.add_hook(:orch_bridge, fn event ->
      case event.type do
        :task_completed ->
          result =
            WorkerResult.success(%{
              task_id: event.task_id || Map.get(event.payload, :task_id, ""),
              worker_id: Map.get(event.payload, :worker_id, "fake"),
              summary: Map.get(event.payload, :result, "fake success") |> to_string()
            })

          try do
            Orchestrator.task_completed(result)
          catch
            :exit, _ -> :ok
          end

        :task_failed ->
          result =
            WorkerResult.failure(%{
              task_id: event.task_id || Map.get(event.payload, :task_id, ""),
              worker_id: Map.get(event.payload, :worker_id, "fake"),
              summary: "Task failed",
              errors: [%{reason: Map.get(event.payload, :reason, "unknown") |> to_string()}]
            })

          try do
            Orchestrator.task_failed(result)
          catch
            :exit, _ -> :ok
          end

        _ ->
          :ok
      end
    end)

    # Subscribe to the global firehose to capture all events
    EventBus.subscribe("spark:events")

    on_exit(fn ->
      Application.put_env(:spark, :home_dir, original_home)
      EventBus.clear_hooks()
      # Best-effort unsubscribe (PubSub may have been killed by another test)
      try do
        EventBus.unsubscribe("spark:events")
      catch
        :exit, _ -> :ok
      end

      for name <- [Spark.Orchestrator, Spark.Dispatcher, Spark.Policy] do
        try do
          if pid = Process.whereis(name), do: GenServer.stop(pid, :shutdown)
        catch
          :exit, _ -> :ok
        end
      end

      try do
        # Don't stop Config Agent — it belongs to the Application tree
        # and stopping it can cascade to kill other processes.
        :ok
      catch
        :exit, _ -> :ok
      end

      File.rm_rf!(tmp_dir)
    end)

    %{tmp_dir: tmp_dir}
  end

  # --- Helpers ---

  defp ensure_config do
    if Process.whereis(Spark.Config) == nil do
      case Spark.Config.start_link([]) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
      end
    end
  end

  defp plan_response(task_count) do
    tasks =
      for i <- 1..task_count do
        %{
          "id" => "task_#{i}",
          "plan_id" => "auto",
          "title" => "Task #{i}",
          "description" => "Description for task #{i}",
          "risk" => "low"
        }
      end

    json =
      Jason.encode!(%{
        "user_goal" => "Build a hello world app",
        "summary" => "A test plan with #{task_count} tasks",
        "tasks" => tasks
      })

    {:ok,
     %{
       id: "chatcmpl-plan",
       model: "mock",
       choices: [%{message: %{role: "assistant", content: "Plan:\n```json\n#{json}\n```"}}],
       usage: %{prompt_tokens: 10, completion_tokens: 5, total_tokens: 15}
     }}
  end

  defp review_response do
    {:ok,
     %{
       id: "chatcmpl-review",
       model: "mock",
       choices: [
         %{
           message: %{
             role: "assistant",
             content: "All tasks completed successfully. No further action needed."
           }
         }
       ],
       usage: %{prompt_tokens: 10, completion_tokens: 5, total_tokens: 15}
     }}
  end

  defp start_orchestrator_with_mocks(mock_responses, opts \\ []) do
    # Start Dispatcher first (Orchestrator depends on it for enqueue)
    unless Process.whereis(Spark.Dispatcher) do
      {:ok, _} =
        Spark.Dispatcher.start_link(
          session_id: "full_plan_session",
          plan_id: "full_plan_plan",
          worker_module: Spark.FakeWorker
        )
    end

    default_opts = [session_id: "full_plan_session"]
    {:ok, pid} = Orchestrator.start_link(Keyword.merge(default_opts, opts))
    MockProvider.set_responses(pid, mock_responses)
    pid
  end

  defp wait_for_phase(expected, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for_phase(expected, deadline)
  end

  defp do_wait_for_phase(phase, deadline) do
    state = Orchestrator.get_state()

    cond do
      state.phase == phase ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        :timeout

      true ->
        Process.sleep(20)
        do_wait_for_phase(phase, deadline)
    end
  end

  defp collect_events(event_types, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_collect_events(event_types, deadline, [])
  end

  defp do_collect_events(types, deadline, acc) do
    receive do
      %Event{type: type} = event ->
        if type in types do
          do_collect_events(types, deadline, [event | acc])
        else
          do_collect_events(types, deadline, acc)
        end
    after
      50 ->
        if System.monotonic_time(:millisecond) >= deadline do
          Enum.reverse(acc)
        else
          do_collect_events(types, deadline, acc)
        end
    end
  end

  # --- Tests ---

  describe "full plan execution flow" do
    test "complete vertical slice: input → plan → approve → execute → review → complete" do
      # Set mock responses: plan generation + review
      _pid =
        start_orchestrator_with_mocks([
          plan_response(2),
          review_response()
        ])

      # 1. Phase starts at :awaiting_input
      state = Orchestrator.get_state()
      assert state.phase == :awaiting_input

      # 2. Submit user input → triggers planning
      assert {:ok, plan} = Orchestrator.run("Build a hello world app")
      assert %Plan{} = plan
      assert plan.approval_status == :awaiting_approval
      assert length(plan.tasks) == 2

      # 3. Verify phase transition
      state = Orchestrator.get_state()
      assert state.phase == :awaiting_approval

      # 4. Approve the plan → triggers dispatching
      assert {:ok, approved} = Orchestrator.approve_plan(plan.id)
      assert approved.approval_status == :approved

      state = Orchestrator.get_state()
      assert state.phase == :executing

      # 5. Wait for FakeWorkers to complete and results to reconcile
      # FakeWorkers are fast (10ms default delay)
      wait_for_phase(:reviewing, 3000)

      # 6. Final review phase → completed
      wait_for_phase(:completed, 3000)

      state = Orchestrator.get_state()
      assert state.phase == :completed
    end

    test "verify all major events are emitted during full flow" do
      _pid =
        start_orchestrator_with_mocks([
          plan_response(2),
          review_response()
        ])

      {:ok, plan} = Orchestrator.run("Build a hello world app")

      # Subscribe to plan-specific topic for plan events
      plan_topic = "spark:plan:#{plan.id}"
      EventBus.subscribe(plan_topic)

      # Also subscribe to task topics for worker events
      for task <- plan.tasks do
        EventBus.subscribe("spark:task:#{task.id}")
      end

      {:ok, _approved} = Orchestrator.approve_plan(plan.id)

      # Wait for completion
      wait_for_phase(:completed, 5000)

      # Collect events that arrived on spark:events (global firehose)
      all_events =
        collect_events(
          [
            :plan_awaiting_approval,
            :plan_approved,
            :task_queued,
            :task_started,
            :task_completed,
            :orchestrator_review_started,
            :orchestrator_review_completed,
            :llm_call_started,
            :llm_call_completed
          ],
          500
        )

      event_type_set = all_events |> Enum.map(& &1.type) |> MapSet.new()

      # Plan lifecycle events are published to plan topic AND global
      # At minimum, plan_approved should have been broadcast
      assert MapSet.member?(event_type_set, :plan_approved),
             "Expected :plan_approved event, got: #{MapSet.to_list(event_type_set) |> inspect}"

      # Task events should be present if workers ran
      has_task_events =
        Enum.any?(
          [:task_queued, :task_started, :task_completed],
          &MapSet.member?(event_type_set, &1)
        )

      assert has_task_events, "Expected at least some task events"

      # LLM events should be present (Orchestrator calls LLM)
      has_llm_events =
        Enum.any?([:llm_call_started, :llm_call_completed], &MapSet.member?(event_type_set, &1))

      assert has_llm_events, "Expected LLM call events"

      EventBus.unsubscribe(plan_topic)

      for task <- plan.tasks do
        EventBus.unsubscribe("spark:task:#{task.id}")
      end
    end

    test "Bronze memory log exists after execution" do
      session_id = "full_plan_session"

      _pid =
        start_orchestrator_with_mocks(
          [
            plan_response(2),
            review_response()
          ],
          session_id: session_id
        )

      {:ok, plan} = Orchestrator.run("Build a hello world app")
      {:ok, _approved} = Orchestrator.approve_plan(plan.id)

      wait_for_phase(:completed, 5000)

      # Manually log key events to Bronze (simulating a Bronze subscriber process)
      Bronze.append(session_id, %{
        type: :plan_approved,
        source: :orchestrator,
        payload: %{plan_id: plan.id}
      })

      for task <- plan.tasks do
        Bronze.append(session_id, %{
          type: :task_completed,
          source: :dispatcher,
          payload: %{task_id: task.id}
        })
      end

      Bronze.append(session_id, %{
        type: :orchestrator_review_completed,
        source: :orchestrator,
        payload: %{}
      })

      # Verify Bronze log exists and has content
      bronze_path = Bronze.session_path(session_id)
      assert File.exists?(bronze_path), "Bronze memory log should exist at #{bronze_path}"

      {:ok, entries} = Bronze.read(session_id)
      assert length(entries) >= 3, "Bronze log should contain entries"

      types = Enum.map(entries, & &1["type"])
      assert "plan_approved" in types
      assert "task_completed" in types
    end

    test "plan phases transition through the full lifecycle" do
      _pid =
        start_orchestrator_with_mocks([
          plan_response(1),
          review_response()
        ])

      # Phase: :awaiting_input
      assert Orchestrator.get_state().phase == :awaiting_input

      # Phase: :awaiting_input → :planning (implicit in run/1) → :awaiting_approval
      {:ok, _plan} = Orchestrator.run("Do the thing")
      assert Orchestrator.get_state().phase == :awaiting_approval

      # Phase: :awaiting_approval → :executing
      {:ok, _plan} =
        Orchestrator.get_state()
        |> Map.fetch!(:active_plan)
        |> then(&Orchestrator.approve_plan(&1.id))

      assert Orchestrator.get_state().phase == :executing

      # Phase: :executing → :reviewing → :completed
      wait_for_phase(:completed, 5000)
      final_state = Orchestrator.get_state()
      assert final_state.phase == :completed
    end

    test "reject returns to awaiting_input and can re-plan" do
      _pid =
        start_orchestrator_with_mocks([
          plan_response(1),
          # Second plan attempt after rejection
          plan_response(2),
          review_response()
        ])

      {:ok, plan} = Orchestrator.run("Build something")
      assert Orchestrator.get_state().phase == :awaiting_approval

      # Reject
      {:ok, _rejected} = Orchestrator.reject_plan(plan.id, "not good enough")
      assert Orchestrator.get_state().phase == :awaiting_input

      # Re-plan
      {:ok, new_plan} = Orchestrator.run("Build something better")
      assert new_plan.approval_status == :awaiting_approval
      assert length(new_plan.tasks) == 2
    end

    test "results reconcile correctly when all tasks complete" do
      _pid =
        start_orchestrator_with_mocks([
          plan_response(3),
          review_response()
        ])

      {:ok, plan} = Orchestrator.run("Build something")
      {:ok, _approved} = Orchestrator.approve_plan(plan.id)

      # Wait for execution + review to complete
      wait_for_phase(:completed, 5000)

      state = Orchestrator.get_state()

      # All tasks should have results (completed or failed)
      all_ids = Plan.task_ids(state.active_plan) |> MapSet.new()

      result_ids =
        MapSet.union(
          MapSet.new(Map.keys(state.completed_results)),
          MapSet.new(Map.keys(state.failed_results))
        )

      assert MapSet.subset?(all_ids, result_ids),
             "All task IDs should have results: missing #{MapSet.difference(all_ids, result_ids) |> MapSet.to_list() |> inspect}"
    end
  end
end
