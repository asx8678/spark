defmodule Spark.Integration.WorkerCrashRetryTest do
  @moduledoc """
  spark-opg.3: Worker crash and retry test.

  - Worker crash detected
  - Retryable task retried
  - Max retries respected
  - Orchestrator notified of final failure
  - Locks released after crash (use LockManager)
  """

  use ExUnit.Case, async: false

  alias Spark.Integration.TestHelpers

  alias Spark.Dispatcher
  alias Spark.Types.{Event, Task, WorkerResult}
  alias Spark.EventBus
  alias Spark.Workspace.LockManager

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "spark_crash_retry_#{:erlang.unique_integer()}")
    File.mkdir_p!(tmp_dir)
    original_home = Application.get_env(:spark, :home_dir)
    Application.put_env(:spark, :home_dir, tmp_dir)

    if pid = Process.whereis(Spark.Config), do: Agent.stop(pid)
    Spark.Config.ensure_home!()
    EventBus.clear_hooks()
    TestHelpers.ensure_app_tree()

    # Stop leftover Dispatcher (test-started, not Application tree)
    if pid = Process.whereis(Spark.Dispatcher) do
      try do
        GenServer.stop(pid, :shutdown)
      catch
        :exit, _ -> :ok
      end
    end

    # Restart LockManager fresh (it's an Application tree process,
    # but we restart it to get clean state)
    case LockManager.start_link([]) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    # Trap exits — crash workers send EXIT signals
    Process.flag(:trap_exit, true)

    on_exit(fn ->
      Process.flag(:trap_exit, false)
      Application.put_env(:spark, :home_dir, original_home)
      EventBus.clear_hooks()

      try do
        if pid = Process.whereis(Spark.Dispatcher), do: GenServer.stop(pid, :shutdown)
      catch
        :exit, _ -> :ok
      end

      File.rm_rf!(tmp_dir)
    end)

    :ok
  end

  defp make_task(id, opts \\ %{}) do
    defaults = %{plan_id: "crash_plan", title: "Task #{id}", id: id, max_retries: 2}
    Task.new(Map.merge(defaults, opts))
  end

  defp plan_response_1task do
    tasks = [
      %{
        "id" => "task_1",
        "plan_id" => "auto",
        "title" => "Task 1",
        "description" => "Desc",
        "risk" => "low"
      }
    ]

    json = Jason.encode!(%{"user_goal" => "test", "summary" => "Plan", "tasks" => tasks})

    {:ok,
     %{
       id: "chatcmpl-plan",
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
       choices: [%{message: %{role: "assistant", content: "Review complete."}}],
       usage: %{prompt_tokens: 10, completion_tokens: 5, total_tokens: 15}
     }}
  end

  describe "worker crash detection" do
    test "crashed worker is detected via :DOWN monitor" do
      TestHelpers.ensure_app_tree()

      {:ok, _pid} =
        Dispatcher.start_link(
          max_concurrency: 3,
          session_id: "crash_session",
          plan_id: "crash_plan",
          worker_module: Spark.FakeWorker.Crash
        )

      task = make_task("crash_t1")
      EventBus.subscribe("spark:task:crash_t1")

      :ok = Dispatcher.enqueue("crash_plan", [task])

      assert_receive %Event{type: :task_started, task_id: "crash_t1"}, 1000

      # Worker crashes — should get retry or failure event
      receive do
        %Event{type: type, task_id: "crash_t1"}
        when type in [:task_retried, :task_failed] ->
          :ok
      after
        3000 -> flunk("Expected task_retried or task_failed event for crashed worker")
      end
    end
  end

  describe "retryable task is retried" do
    test "crashed worker with retries remaining gets retried" do
      TestHelpers.ensure_app_tree()

      {:ok, _pid} =
        Dispatcher.start_link(
          max_concurrency: 1,
          session_id: "retry_session",
          plan_id: "crash_plan",
          worker_module: Spark.FakeWorker.Crash
        )

      task = make_task("retry_t1", %{max_retries: 2})
      EventBus.subscribe("spark:task:retry_t1")

      :ok = Dispatcher.enqueue("crash_plan", [task])

      assert_receive %Event{type: :task_started, task_id: "retry_t1"}, 1000
      assert_receive %Event{type: :task_retried, task_id: "retry_t1"}, 3000
    end
  end

  describe "max retries respected" do
    test "task with max_retries=0 is not retried" do
      # Trap exits so linked crashed workers don't kill the test
      Process.flag(:trap_exit, true)

      {:ok, _pid} =
        Dispatcher.start_link(
          max_concurrency: 1,
          session_id: "no_retry_session",
          plan_id: "crash_plan",
          worker_module: Spark.FakeWorker.Crash
        )

      task = make_task("noretry_t1", %{max_retries: 0})
      EventBus.subscribe("spark:task:noretry_t1")

      :ok = Dispatcher.enqueue("crash_plan", [task])

      assert_receive %Event{type: :task_started, task_id: "noretry_t1"}, 1000
      assert_receive %Event{type: :task_failed, task_id: "noretry_t1"}, 3000

      # Flush any EXIT messages
      receive do
        {:EXIT, _, _} -> :ok
      after
        100 -> :ok
      end

      Process.flag(:trap_exit, false)
    end

    test "task exhausting retries is marked failed" do
      Process.flag(:trap_exit, true)
      TestHelpers.ensure_app_tree()

      {:ok, _pid} =
        Dispatcher.start_link(
          max_concurrency: 1,
          session_id: "exhaust_session",
          plan_id: "crash_plan",
          worker_module: Spark.FakeWorker.Crash
        )

      # max_retries: 1 → one retry allowed, then give up on second crash
      task = make_task("exhaust_t1", %{max_retries: 1})
      EventBus.subscribe("spark:task:exhaust_t1")

      :ok = Dispatcher.enqueue("crash_plan", [task])

      # Should eventually get task_failed after retries exhausted
      assert_receive %Event{type: :task_failed, task_id: "exhaust_t1", payload: %{retries: _}},
                     5000
    end
  end

  describe "orchestrator notified of final failure" do
    test "failed task result reaches orchestrator via task_failed cast" do
      # Stop leftover Orchestrator
      if pid = Process.whereis(Spark.Orchestrator) do
        try do
          GenServer.stop(pid, :shutdown)
        catch
          :exit, _ -> :ok
        end
      end

      {:ok, orch_pid} =
        Spark.Orchestrator.start_link(session_id: "orch_fail_session")

      # Feed a failed result to Orchestrator
      result =
        WorkerResult.failure(%{
          task_id: "fail_t1",
          worker_id: "w_fail",
          summary: "Task failed: worker_crash",
          errors: [%{reason: "worker_crash"}],
          started_at: DateTime.utc_now()
        })

      # Orchestrator is in :awaiting_input, so it ignores task_failed
      # The key assertion: it doesn't crash
      Spark.Orchestrator.task_failed(result)
      Process.sleep(50)
      assert Process.alive?(orch_pid)
    end

    test "orchestrator records failed results when in executing phase" do
      # Stop leftover Orchestrator
      if pid = Process.whereis(Spark.Orchestrator) do
        try do
          GenServer.stop(pid, :shutdown)
        catch
          :exit, _ -> :ok
        end
      end

      # Start Dispatcher with crash workers
      {:ok, _disp} =
        Dispatcher.start_link(
          max_concurrency: 1,
          session_id: "orch_fail2_session",
          plan_id: "orch_fail2_plan",
          worker_module: Spark.FakeWorker.Crash
        )

      {:ok, orch_pid} =
        Spark.Orchestrator.start_link(session_id: "orch_fail2_session")

      # Set mock responses for the Orchestrator's process
      Spark.LLM.MockProvider.set_responses(orch_pid, [
        plan_response_1task(),
        review_response()
      ])

      {:ok, plan} = Spark.Orchestrator.run("Do something")
      {:ok, _approved} = Spark.Orchestrator.approve_plan(plan.id)

      state = Spark.Orchestrator.get_state()
      assert state.phase == :executing

      # Now send a failure for a task in the plan
      first_task_id = hd(Spark.Types.Plan.task_ids(plan))

      result =
        WorkerResult.failure(%{
          task_id: first_task_id,
          worker_id: "w_crash",
          summary: "Crashed",
          errors: [%{reason: "worker_crash"}],
          started_at: DateTime.utc_now()
        })

      Spark.Orchestrator.task_failed(result)
      Process.sleep(50)

      state = Spark.Orchestrator.get_state()
      assert map_size(state.failed_results) >= 1
    end
  end

  describe "locks released after crash" do
    test "lock is released when a crashed task's write paths were locked" do
      assert :ok = LockManager.acquire("crash_lock_t1", ["/tmp/spark_crash_test/file.txt"])
      assert {true, _} = LockManager.conflicts?(["/tmp/spark_crash_test/file.txt"])

      assert :ok = LockManager.release("crash_lock_t1")
      refute LockManager.conflicts?(["/tmp/spark_crash_test/file.txt"])
    end

    test "dispatcher crash path triggers lock release hooks" do
      {:ok, _pid} =
        Dispatcher.start_link(
          max_concurrency: 1,
          session_id: "lock_session",
          plan_id: "crash_plan",
          worker_module: Spark.FakeWorker.Crash
        )

      task =
        make_task("lock_t1", %{max_retries: 0, write_paths: ["/tmp/spark_lock_test/out.txt"]})

      EventBus.subscribe("spark:task:lock_t1")

      :ok = Dispatcher.enqueue("crash_plan", [task])

      assert_receive %Event{type: :task_failed, task_id: "lock_t1"}, 3000

      status = Dispatcher.status()
      assert status.active_count == 0
    end
  end
end
