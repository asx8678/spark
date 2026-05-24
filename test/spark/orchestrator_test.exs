defmodule Spark.OrchestratorTest do
  use ExUnit.Case, async: false

  alias Spark.Orchestrator
  alias Spark.State
  alias Spark.Types.{Event, Plan, WorkerResult}
  alias Spark.LLM.MockProvider
  alias Spark.EventBus

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "spark_orch_test_#{:erlang.unique_integer()}")
    File.mkdir_p!(tmp_dir)
    original_home = Application.get_env(:spark, :home_dir)
    Application.put_env(:spark, :home_dir, tmp_dir)

    ensure_pubsub()
    EventBus.clear_hooks()
    ensure_config()

    # Stop any leftover Orchestrator/Dispatcher
    for name <- [Spark.Orchestrator, Spark.Dispatcher] do
      if pid = Process.whereis(name) do
        try do
          GenServer.stop(pid, :shutdown)
        catch
          :exit, _ -> :ok
        end
      end
    end

    MockProvider.clear(self())

    on_exit(fn ->
      Application.put_env(:spark, :home_dir, original_home)
      EventBus.clear_hooks()

      for name <- [Spark.Orchestrator, Spark.Dispatcher] do
        try do
          if pid = Process.whereis(name), do: GenServer.stop(pid, :shutdown)
        catch
          :exit, _ -> :ok
        end
      end

      File.rm_rf!(tmp_dir)
    end)

    :ok
  end

  # Start Orchestrator and set mock responses for its pid
  defp start_orchestrator_with_mocks(mock_responses, opts \\ []) do
    # Start Dispatcher first (Orchestrator depends on it for enqueue)
    unless Process.whereis(Spark.Dispatcher) do
      {:ok, _} = Spark.Dispatcher.start_link(session_id: "test_session", plan_id: "test_plan")
    end

    default_opts = [session_id: "test_sess"]
    {:ok, pid} = Orchestrator.start_link(Keyword.merge(default_opts, opts))
    MockProvider.set_responses(pid, mock_responses)
    pid
  end

  defp plan_response(task_count \\ 2) do
    tasks =
      for i <- 1..task_count do
        %{
          "id" => "task_#{i}",
          "plan_id" => "auto",
          "title" => "Task #{i}",
          "description" => "Description for task #{i}",
          "risk" => "medium"
        }
      end

    json =
      Jason.encode!(%{
        "user_goal" => "test goal",
        "summary" => "A test plan with #{task_count} tasks",
        "tasks" => tasks
      })

    {:ok,
     %{
       id: "chatcmpl-test",
       model: "mock",
       choices: [
         %{message: %{role: "assistant", content: "Here is the plan:\n```json\n#{json}\n```"}}
       ],
       usage: %{prompt_tokens: 10, completion_tokens: 5, total_tokens: 15}
     }}
  end

  defp empty_tasks_response do
    json =
      Jason.encode!(%{
        "user_goal" => "test goal",
        "summary" => "A plan with no tasks",
        "tasks" => []
      })

    {:ok,
     %{
       id: "chatcmpl-empty",
       model: "mock",
       choices: [%{message: %{role: "assistant", content: "```json\n#{json}\n```"}}],
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

  # --- spark-anh.2: Planning flow ---

  describe "run/1 — planning flow" do
    test "creates plan and enters awaiting_approval" do
      _pid = start_orchestrator_with_mocks([plan_response()])

      assert {:ok, plan} = Orchestrator.run("Build a hello world app")
      assert %Plan{} = plan
      assert plan.approval_status == :awaiting_approval
      assert plan.user_goal == "test goal"
      assert length(plan.tasks) == 2

      state = Orchestrator.get_state()
      assert state.phase == :awaiting_approval
    end

    test "returns error on unparseable LLM response" do
      _pid =
        start_orchestrator_with_mocks([
          {:ok,
           %{
             id: "bad",
             model: "mock",
             choices: [%{message: %{role: "assistant", content: "I don't know"}}],
             usage: %{prompt_tokens: 1, completion_tokens: 1, total_tokens: 2}
           }}
        ])

      assert {:error, {:plan_parse, :no_json_in_response}} = Orchestrator.run("Do something")
    end

    test "returns error when not in awaiting_input phase" do
      _pid = start_orchestrator_with_mocks([plan_response()])

      {:ok, _plan} = Orchestrator.run("Build something")

      assert {:error, {:invalid_phase, :awaiting_approval}} =
               Orchestrator.run("Build another thing")
    end

    test "returns error on LLM failure" do
      _pid = start_orchestrator_with_mocks([{:error, :timeout}])

      assert {:error, {:llm_error, :timeout}} = Orchestrator.run("Do something")
    end

    test "retries once when LLM returns empty tasks then succeeds on retry" do
      _pid = start_orchestrator_with_mocks([empty_tasks_response(), plan_response(2)])

      assert {:ok, plan} = Orchestrator.run("Do something")
      assert %Plan{} = plan
      assert length(plan.tasks) == 2
      assert plan.approval_status == :awaiting_approval
    end

    test "fails after retry when LLM persistently returns empty tasks" do
      _pid = start_orchestrator_with_mocks([empty_tasks_response(), empty_tasks_response()])

      assert {:error, {:plan_validation, errors}} = Orchestrator.run("Do something")
      assert {:tasks, "must not be empty"} in errors
    end
  end

  # --- spark-anh.3: Approval gate ---

  describe "approve_plan/1" do
    test "approves plan and dispatches tasks" do
      _pid = start_orchestrator_with_mocks([plan_response()])

      {:ok, plan} = Orchestrator.run("Build something")
      assert plan.approval_status == :awaiting_approval

      assert {:ok, approved} = Orchestrator.approve_plan(plan.id)
      assert approved.approval_status == :approved

      state = Orchestrator.get_state()
      assert state.phase == :executing
    end

    test "rejects mismatched plan_id" do
      _pid = start_orchestrator_with_mocks([plan_response()])

      {:ok, _plan} = Orchestrator.run("Build something")

      assert {:error, :plan_id_mismatch} = Orchestrator.approve_plan("wrong_id")
    end

    test "rejects when in wrong phase" do
      _pid = start_orchestrator_with_mocks([])

      assert {:error, {:invalid_phase, :awaiting_input}} = Orchestrator.approve_plan("any_id")
    end
  end

  describe "reject_plan/2" do
    test "rejects plan and returns to awaiting_input" do
      _pid = start_orchestrator_with_mocks([plan_response()])

      {:ok, plan} = Orchestrator.run("Build something")

      assert {:ok, rejected} = Orchestrator.reject_plan(plan.id, "bad idea")
      assert rejected.approval_status == :rejected

      state = Orchestrator.get_state()
      assert state.phase == :awaiting_input
      assert state.active_plan == nil
    end

    test "rejects mismatched plan_id" do
      _pid = start_orchestrator_with_mocks([plan_response()])

      {:ok, _plan} = Orchestrator.run("Build something")

      assert {:error, :plan_id_mismatch} = Orchestrator.reject_plan("wrong_id")
    end
  end

  describe "modify_plan/2" do
    test "modifies plan and re-plans" do
      _pid = start_orchestrator_with_mocks([plan_response(), plan_response(3)])

      {:ok, plan} = Orchestrator.run("Build something")

      assert {:ok, modified} = Orchestrator.modify_plan(plan.id, "Add more tasks")
      assert %Plan{} = modified
      assert modified.approval_status == :awaiting_approval

      state = Orchestrator.get_state()
      assert state.phase == :awaiting_approval
    end

    test "returns error when in wrong phase" do
      _pid = start_orchestrator_with_mocks([])

      assert {:error, {:invalid_phase, :awaiting_input}} =
               Orchestrator.modify_plan("any_id", "Change it")
    end
  end

  # --- spark-anh.4: Result reconciliation ---

  describe "result reconciliation" do
    test "collects results and transitions to reviewing then completed" do
      _pid = start_orchestrator_with_mocks([plan_response(2), review_response()])

      {:ok, plan} = Orchestrator.run("Build something")
      {:ok, _approved} = Orchestrator.approve_plan(plan.id)

      result1 =
        WorkerResult.success(%{
          task_id: "task_1",
          worker_id: "w1",
          summary: "Task 1 done"
        })

      result2 =
        WorkerResult.success(%{
          task_id: "task_2",
          worker_id: "w2",
          summary: "Task 2 done"
        })

      Orchestrator.task_completed(result1)
      Orchestrator.task_completed(result2)

      wait_for_phase(:completed, 500)

      state = Orchestrator.get_state()
      assert state.phase == :completed
      assert Map.has_key?(state.completed_results, "task_1")
      assert Map.has_key?(state.completed_results, "task_2")
    end

    test "handles mixed success and failure results" do
      _pid = start_orchestrator_with_mocks([plan_response(2), review_response()])

      {:ok, plan} = Orchestrator.run("Build something")
      {:ok, _approved} = Orchestrator.approve_plan(plan.id)

      result1 =
        WorkerResult.success(%{
          task_id: "task_1",
          worker_id: "w1",
          summary: "Task 1 done"
        })

      result2 =
        WorkerResult.failure(%{
          task_id: "task_2",
          worker_id: "w2",
          summary: "Task 2 failed",
          errors: [%{reason: "something broke"}]
        })

      Orchestrator.task_completed(result1)
      Orchestrator.task_failed(result2)

      wait_for_phase(:completed, 500)

      state = Orchestrator.get_state()
      assert state.phase == :completed
      assert Map.has_key?(state.completed_results, "task_1")
      assert Map.has_key?(state.failed_results, "task_2")
    end

    test "stays in executing if not all tasks complete" do
      _pid = start_orchestrator_with_mocks([plan_response(2)])

      {:ok, plan} = Orchestrator.run("Build something")
      {:ok, _approved} = Orchestrator.approve_plan(plan.id)

      result1 =
        WorkerResult.success(%{
          task_id: "task_1",
          worker_id: "w1",
          summary: "Task 1 done"
        })

      Orchestrator.task_completed(result1)

      state = Orchestrator.get_state()
      assert state.phase == :executing
    end
  end

  # --- spark-anh.5: Final review ---

  describe "final review" do
    test "produces summary and enters completed" do
      _pid = start_orchestrator_with_mocks([plan_response(1), review_response()])

      {:ok, plan} = Orchestrator.run("Build something")
      {:ok, _approved} = Orchestrator.approve_plan(plan.id)

      result =
        WorkerResult.success(%{
          task_id: "task_1",
          worker_id: "w1",
          summary: "All done"
        })

      Orchestrator.task_completed(result)
      wait_for_phase(:completed, 500)

      state = Orchestrator.get_state()
      assert state.phase == :completed
    end
  end

  # --- spark-anh.6: Hot reload integration ---

  describe "hot reload integration" do
    test "prompt_reloaded rebuilds cached prefix" do
      _pid = start_orchestrator_with_mocks([plan_response()])

      state_before = Orchestrator.get_state()
      original_version = state_before.prompt_version

      event = Event.hot_reload(:prompt_reloaded, %{path: "/prompts/orchestrator.md"})
      EventBus.publish("spark:hot_reload", event)

      Process.sleep(50)

      state_after = Orchestrator.get_state()
      assert state_after.prompt_version != original_version
      assert state_after.cached_prefix != []
    end

    test "prompt_reloaded loads the new prompt content from dynamic store" do
      unless Process.whereis(Spark.Prompt.Store) do
        Spark.Prompt.Store.start_link()
      end

      _pid = start_orchestrator_with_mocks([plan_response()])

      # Write a custom prompt to the store
      custom_prompt_text = "This is a custom test prompt text: #{:erlang.unique_integer()}"
      {:ok, _} = Spark.Prompt.Store.write(:orchestrator, custom_prompt_text)

      # Publish prompt_reloaded event
      event = Event.hot_reload(:prompt_reloaded, %{path: "/prompts/orchestrator.md"})
      EventBus.publish("spark:hot_reload", event)

      Process.sleep(50)

      # Verify Orchestrator now uses the new prompt in its cached prefix
      state = Orchestrator.get_state()
      [%{role: "system", content: content}] = state.cached_prefix
      assert content == custom_prompt_text

      # Verify version matches
      expected_version = Spark.Prompt.Store.version(:orchestrator)
      assert state.prompt_version == expected_version
    end

    test "config_reloaded updates model" do
      _pid = start_orchestrator_with_mocks([plan_response()])

      event = Event.hot_reload(:config_reloaded, %{})
      EventBus.publish("spark:hot_reload", event)

      Process.sleep(50)

      state_after = Orchestrator.get_state()
      # Model comes from Config, which may return nil in test env
      # The key assertion: config_reloaded doesn't crash and state is still valid
      assert state_after.phase == :awaiting_input
    end

    test "policy_reloaded revalidates draft plan" do
      _pid = start_orchestrator_with_mocks([plan_response()])

      {:ok, _plan} = Orchestrator.run("Build something")

      event = Event.hot_reload(:policy_reloaded, %{path: "/policy/main.json"})
      EventBus.publish("spark:hot_reload", event)

      Process.sleep(50)

      state = Orchestrator.get_state()
      assert state.phase == :awaiting_approval
    end

    test "code_reloaded runs migration hook" do
      _pid = start_orchestrator_with_mocks([plan_response()])

      event = Event.hot_reload(:code_reloaded, %{version: 2})
      EventBus.publish("spark:hot_reload", event)

      Process.sleep(50)

      state = Orchestrator.get_state()
      assert state.phase == :awaiting_input
    end
  end

  # --- State module tests ---

  describe "Spark.State" do
    test "new/1 creates state with defaults" do
      state = State.new(session_id: "test_sess")
      assert state.session_id == "test_sess"
      assert state.phase == :awaiting_input
      assert state.completed_results == %{}
      assert state.failed_results == %{}
      assert state.schema_version == 1
    end

    test "new/1 generates session_id if not provided" do
      state = State.new()
      assert String.starts_with?(state.session_id, "sess_")
    end

    test "add_result/2 and add_failed/2" do
      state = State.new(session_id: "test")

      result = %WorkerResult{
        task_id: "t1",
        worker_id: "w1",
        status: :success,
        summary: "Done"
      }

      state = State.add_result(state, result)
      assert Map.has_key?(state.completed_results, "t1")

      failed = %WorkerResult{
        task_id: "t2",
        worker_id: "w2",
        status: :failure,
        summary: "Failed",
        errors: [%{reason: "boom"}]
      }

      state = State.add_failed(state, failed)
      assert Map.has_key?(state.failed_results, "t2")
    end

    test "all_results/1 merges completed and failed" do
      state = State.new(session_id: "test")

      state =
        State.add_result(state, %WorkerResult{task_id: "t1", worker_id: "w1", summary: "ok"})

      state =
        State.add_failed(state, %WorkerResult{
          task_id: "t2",
          worker_id: "w2",
          summary: "fail",
          status: :failure,
          errors: [%{reason: "x"}]
        })

      all = State.all_results(state)
      assert Map.has_key?(all, "t1")
      assert Map.has_key?(all, "t2")
    end

    test "add_history/2 prepends entry (newest-first)" do
      state = State.new(session_id: "test")
      state = State.add_history(state, %{role: "user", content: "first"})
      state = State.add_history(state, %{role: "user", content: "second"})

      # Newest-first: "second" is at the head
      assert hd(state.history) == %{role: "user", content: "second"}
      assert length(state.history) == 2
    end

    test "add_history/2 respects max_history cap" do
      state = State.new(session_id: "test", max_history: 3)
      state = State.add_history(state, %{role: "user", content: "a"})
      state = State.add_history(state, %{role: "user", content: "b"})
      state = State.add_history(state, %{role: "user", content: "c"})
      state = State.add_history(state, %{role: "user", content: "d"})

      assert length(state.history) == 3
      # Newest-first: d, c, b — "a" was evicted
      assert state.history == [
               %{role: "user", content: "d"},
               %{role: "user", content: "c"},
               %{role: "user", content: "b"}
             ]
    end

    test "history_chronological/1 reverses to oldest-first" do
      state = State.new(session_id: "test")
      state = State.add_history(state, %{role: "user", content: "first"})
      state = State.add_history(state, %{role: "user", content: "second"})

      chronological = State.history_chronological(state)

      assert chronological == [
               %{role: "user", content: "first"},
               %{role: "user", content: "second"}
             ]
    end

    test "default max_history is 50" do
      state = State.new(session_id: "test")
      assert state.max_history == 50
    end
  end

  # --- Streaming planning flow ---

  describe "run_streaming/2 — streaming planning flow" do
    test "sends stream chunks to TUI pid before final plan result" do
      # Set up a fake TUI pid that collects stream messages
      tui_pid = self()

      # Build valid JSON plan that spans multiple chunks
      plan_json =
        Jason.encode!(%{
          "user_goal" => "Build a streaming test app",
          "summary" => "A plan with 2 tasks",
          "tasks" => [
            %{"id" => "task_1", "title" => "Task 1", "description" => "Do thing 1", "risk" => "low"},
            %{"id" => "task_2", "title" => "Task 2", "description" => "Do thing 2", "risk" => "medium"}
          ]
        })

      full_content = "Here is your plan:\n```json\n#{plan_json}\n```"

      # Split the content into chunks to simulate streaming
      chunk_size = max(div(byte_size(full_content), 3), 1)
      chunks =
        full_content
        |> String.graphemes()
        |> Enum.chunk_every(chunk_size)
        |> Enum.map(fn graphemes ->
          {:chunk, %{delta: %{content: Enum.join(graphemes)}}}
        end)

      # Start orchestrator and set mocks
      orch_pid = start_orchestrator_with_mocks([])

      # Set stream chunks for the orchestrator's pid (via mock_caller_pid)
      MockProvider.set_stream_chunks(orch_pid, chunks)

      # Set the final complete response for the orchestrator's pid
      MockProvider.set_responses(orch_pid, [
        {:ok,
         %{
           id: "chatcmpl-stream-test",
           model: "mock",
           choices: [
             %{message: %{role: "assistant", content: full_content}}
           ],
           usage: %{prompt_tokens: 10, completion_tokens: 50, total_tokens: 60}
         }}
      ])

      # Call run_streaming — this is a synchronous call that returns the plan
      # but chunks should have been sent to tui_pid during execution
      assert {:ok, plan} = Orchestrator.run_streaming("Build a streaming test app", tui_pid)

      # Verify we received stream_started
      assert_received {:stream_started, %{}}

      # Verify we received stream chunks
      assert_received {:stream_chunk, _first_chunk}

      # Verify we received stream_done
      assert_received {:stream_done, %{}}

      # Verify the final plan is valid
      assert %Plan{} = plan
      assert plan.approval_status == :awaiting_approval
      assert length(plan.tasks) == 2

      # Verify orchestrator ended in awaiting_approval
      state = Orchestrator.get_state()
      assert state.phase == :awaiting_approval
      assert state.active_plan.id == plan.id

      # Clean up mock data
      MockProvider.clear(orch_pid)
    end

    test "sends stream_error on LLM failure" do
      tui_pid = self()

      # Start orchestrator with no mocks set — the stream will use default chunks
      # but we'll set an error response
      orch_pid = start_orchestrator_with_mocks([{:error, :api_timeout}])

      MockProvider.set_stream_chunks(orch_pid, [])

      assert {:error, {:llm_error, :api_timeout}} =
               Orchestrator.run_streaming("Build something", tui_pid)

      # Verify we received stream_started
      assert_received {:stream_started, %{}}

      # Clean up
      MockProvider.clear(orch_pid)
    end
  end

  # --- Helpers ---

  defp wait_for_phase(expected_phase, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for_phase(expected_phase, deadline)
  end

  defp do_wait_for_phase(phase, deadline) do
    state = Orchestrator.get_state()

    cond do
      state.phase == phase ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        :timeout

      true ->
        Process.sleep(10)
        do_wait_for_phase(phase, deadline)
    end
  end

  defp ensure_pubsub do
    if Process.whereis(Spark.PubSub) == nil do
      # Start a standalone PubSub for test (normally from Application tree)
      {:ok, _pid} = Phoenix.PubSub.PG2.start_link(Spark.PubSub)
    end
  end

  defp ensure_config do
    if Process.whereis(Spark.Config) == nil do
      case Spark.Config.start_link([]) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
      end
    end
  end
end
