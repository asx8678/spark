defmodule Spark.DispatcherCompletionTest do
  @moduledoc """
  Tests for spark-u4b.4: Task completion handling.

  Verifies:
  - handle_worker_complete removes active worker, marks completed, publishes event
  - Completion triggers spawn of next queued task
  - handle_worker_failed explicit failure path works
  - Failed retryable task gets retried via RetryPolicy
  """
  use ExUnit.Case, async: false

  alias Spark.Dispatcher
  alias Spark.Types.Task
  alias Spark.EventBus
  alias Spark.Types.Event

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "spark_completion_#{:erlang.unique_integer()}")
    File.mkdir_p!(tmp_dir)
    original_home = Application.get_env(:spark, :home_dir)
    Application.put_env(:spark, :home_dir, tmp_dir)

    if pid = Process.whereis(Spark.Config), do: Agent.stop(pid)
    EventBus.clear_hooks()

    if pid = Process.whereis(Spark.Dispatcher), do: GenServer.stop(pid, :shutdown)

    {:ok, _pid} =
      Dispatcher.start_link(
        max_concurrency: 1,
        session_id: "completion_session",
        plan_id: "completion_plan"
      )

    on_exit(fn ->
      Application.put_env(:spark, :home_dir, original_home)
      EventBus.clear_hooks()

      try do
        if pid = Process.whereis(Spark.Dispatcher), do: GenServer.stop(pid, :shutdown)
      catch
        :exit, _ -> :ok
      end

      try do
        if pid = Process.whereis(Spark.Config), do: Agent.stop(pid)
      catch
        :exit, _ -> :ok
      end

      File.rm_rf!(tmp_dir)
    end)

    :ok
  end

  defp make_task(id, opts \\ %{}) do
    Task.new(Map.merge(%{plan_id: "completion_plan", title: "Task #{id}", id: id}, opts))
  end

  defp await_failed_count(count, timeout \\ 2000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    spin(deadline, &(&1.failed_count >= count))
  end

  defp spin(deadline, check) do
    status = Dispatcher.status()

    cond do
      check.(status) ->
        status

      System.monotonic_time(:millisecond) >= deadline ->
        status

      true ->
        Process.sleep(20)
        spin(deadline, check)
    end
  end

  # --- Completion removes active worker ---

  describe "handle_worker_complete/2" do
    test "removes task from active workers" do
      EventBus.subscribe("spark:task:comp_t1")

      Dispatcher.enqueue("completion_plan", [make_task("comp_t1")])
      assert_receive %Event{type: :task_started, task_id: "comp_t1"}, 500

      # Before completion, task is active
      assert Dispatcher.status().active_count >= 1

      # Explicit completion via GenServer call
      assert :ok = Dispatcher.handle_worker_complete("comp_t1", %{status: :success})

      # Active worker removed
      status = Dispatcher.status()
      assert status.active_count == 0
      assert status.completed_count >= 1

      # Event published
      assert_receive %Event{type: :task_completed, task_id: "comp_t1"}, 500
    after
      EventBus.unsubscribe("spark:task:comp_t1")
    end

    test "spawns next queued task after completion" do
      EventBus.subscribe("spark:task:spawn_t1")
      EventBus.subscribe("spark:task:spawn_t2")

      # With max_concurrency=1, only first task starts
      Dispatcher.enqueue("completion_plan", [
        make_task("spawn_t1"),
        make_task("spawn_t2")
      ])

      # First task starts, second waits
      assert_receive %Event{type: :task_started, task_id: "spawn_t1"}, 500

      # Complete first task explicitly
      assert :ok = Dispatcher.handle_worker_complete("spawn_t1", %{status: :success})

      assert_receive %Event{type: :task_completed, task_id: "spawn_t1"}, 500
      # Second task should now be spawned
      assert_receive %Event{type: :task_started, task_id: "spawn_t2"}, 1000
    after
      EventBus.unsubscribe("spark:task:spawn_t1")
      EventBus.unsubscribe("spark:task:spawn_t2")
    end
  end

  # --- Explicit failure path ---

  describe "handle_worker_failed/2" do
    test "marks task as failed for non-retryable reason" do
      EventBus.subscribe("spark:task:fail_t1")

      task = make_task("fail_t1", %{max_retries: 0})
      Dispatcher.enqueue("completion_plan", [task])
      assert_receive %Event{type: :task_started, task_id: "fail_t1"}, 500

      # Explicit failure via GenServer call with non-retryable reason
      assert :ok = Dispatcher.handle_worker_failed("fail_t1", :policy_violation)

      # Should get either task_failed or task_retried
      receive do
        %Event{type: type, task_id: "fail_t1"} when type in [:task_failed, :task_retried] -> :ok
      after
        500 -> flunk("Expected task event for fail_t1")
      end

      status = await_failed_count(1)
      assert status.failed_count >= 1
    after
      EventBus.unsubscribe("spark:task:fail_t1")
    end

    test "retries retryable task when retries remain" do
      EventBus.subscribe("spark:task:retry_t1")

      task = make_task("retry_t1", %{max_retries: 2})
      Dispatcher.enqueue("completion_plan", [task])
      assert_receive %Event{type: :task_started, task_id: "retry_t1"}, 500

      # Explicit failure with retryable reason — should trigger retry
      assert :ok = Dispatcher.handle_worker_failed("retry_t1", :llm_timeout)

      # Should receive task_retried event
      assert_receive %Event{type: :task_retried, task_id: "retry_t1"}, 500

      # Task should be re-enqueued (not in failed)
      status = Dispatcher.status()
      assert status.failed_count == 0
    after
      EventBus.unsubscribe("spark:task:retry_t1")
    end

    test "eventually fails after max retries exhausted" do
      EventBus.subscribe("spark:task:exhaust_t1")

      task = make_task("exhaust_t1", %{max_retries: 1})
      Dispatcher.enqueue("completion_plan", [task])
      assert_receive %Event{type: :task_started, task_id: "exhaust_t1"}, 500

      # First failure — should retry
      assert :ok = Dispatcher.handle_worker_failed("exhaust_t1", :llm_timeout)
      assert_receive %Event{type: :task_retried, task_id: "exhaust_t1"}, 500

      # Wait for retry to start
      assert_receive %Event{type: :task_started, task_id: "exhaust_t1"}, 1000

      # Second failure — max retries exceeded, should give up
      assert :ok = Dispatcher.handle_worker_failed("exhaust_t1", :llm_timeout)

      receive do
        %Event{type: type, task_id: "exhaust_t1"} when type in [:task_failed, :task_retried] ->
          :ok
      after
        500 -> flunk("Expected task event after retry exhaustion")
      end

      status = await_failed_count(1)
      assert status.failed_count >= 1
    after
      EventBus.unsubscribe("spark:task:exhaust_t1")
    end
  end
end
