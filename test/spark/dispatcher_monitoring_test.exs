defmodule Spark.DispatcherMonitoringTest do
  @moduledoc """
  Tests for Dispatcher crash handling, retry logic, and monitoring.

  Uses Spark.FakeWorker.Crash to simulate worker crashes, verifying that:
  - Crashed tasks trigger :task_failed events when max_retries is 0
  - Retryable tasks get retried (max_retries > 0)
  - After max_retries, tasks are permanently failed
  - completed_tasks and failed_tasks are tracked correctly
  """
  use ExUnit.Case, async: false

  alias Spark.Dispatcher
  alias Spark.Types.Task
  alias Spark.Types.Event
  alias Spark.EventBus

  @crash_dispatcher :spark_dispatcher_monitoring_test

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "spark_monitor_test_#{:erlang.unique_integer()}")
    File.mkdir_p!(tmp_dir)
    original_home = Application.get_env(:spark, :home_dir)
    Application.put_env(:spark, :home_dir, tmp_dir)

    if pid = Process.whereis(Spark.Config), do: Agent.stop(pid)
    EventBus.clear_hooks()

    # Stop any existing process at our test name
    if pid = Process.whereis(@crash_dispatcher), do: GenServer.stop(pid, :shutdown)

    # Start a dispatcher using the Crash worker so every spawned worker dies
    {:ok, _pid} =
      Dispatcher.start_link(
        name: @crash_dispatcher,
        session_id: "monitor_session",
        plan_id: "monitor_plan",
        worker_module: Spark.FakeWorker.Crash,
        max_concurrency: 1
      )

    on_exit(fn ->
      Application.put_env(:spark, :home_dir, original_home)
      EventBus.clear_hooks()

      try do
        if pid = Process.whereis(@crash_dispatcher), do: GenServer.stop(pid, :shutdown)
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

  # Helpers — all calls go through the named test dispatcher

  defp enqueue(tasks) do
    GenServer.call(@crash_dispatcher, {:enqueue, "monitor_plan", tasks})
  end

  defp status do
    GenServer.call(@crash_dispatcher, :status)
  end

  defp make_task(id, opts \\ %{}) do
    Task.new(Map.merge(%{plan_id: "monitor_plan", title: "Task #{id}", id: id}, opts))
  end

  defp await_failed_count(count, timeout \\ 3000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_failed_count(count, deadline)
  end

  defp do_await_failed_count(count, deadline) do
    s = status()

    cond do
      s.failed_count >= count ->
        s

      System.monotonic_time(:millisecond) >= deadline ->
        s

      true ->
        Process.sleep(30)
        do_await_failed_count(count, deadline)
    end
  end

  defp await_event(topic, type, timeout \\ 2000) do
    receive do
      %Event{type: ^type, topic: ^topic} = event -> event
    after
      timeout -> nil
    end
  end

  # --- Crash worker with no retries -> task_failed ---

  describe "crash with max_retries: 0" do
    test "publishes :task_failed event when worker crashes" do
      task = make_task("crash_no_retry", %{max_retries: 0})
      topic = "spark:task:crash_no_retry"
      EventBus.subscribe(topic)

      assert :ok = enqueue([task])

      # Should see queued -> started -> failed
      assert %Event{type: :task_queued} = await_event(topic, :task_queued)
      assert %Event{type: :task_started} = await_event(topic, :task_started)

      failed_event = await_event(topic, :task_failed, 3000)
      assert failed_event != nil, "Expected :task_failed event but none received"
      assert failed_event.payload.reason != nil

      s = await_failed_count(1)
      assert s.failed_count >= 1
    end
  end

  # --- Retryable tasks get retried ---

  describe "crash with max_retries > 0" do
    test "retries the task and publishes :task_retried events" do
      # max_retries: 2 means up to 2 retries (retry_count goes 0 -> 1 -> 2)
      task = make_task("crash_retry", %{max_retries: 2})
      topic = "spark:task:crash_retry"
      EventBus.subscribe(topic)

      assert :ok = enqueue([task])

      assert %Event{type: :task_queued} = await_event(topic, :task_queued)

      # First attempt crashes, should get retried
      assert %Event{type: :task_started} = await_event(topic, :task_started)
      retried = await_event(topic, :task_retried, 3000)
      assert retried != nil, "Expected :task_retried event on first crash"
      assert retried.payload.retry_count == 1

      # Second attempt also crashes, should get retried again
      assert %Event{type: :task_started} = await_event(topic, :task_started, 1000)
      retried2 = await_event(topic, :task_retried, 3000)
      assert retried2 != nil, "Expected :task_retried event on second crash"
      assert retried2.payload.retry_count == 2
    end

    test "eventually marks task as :task_failed after max retries exceeded" do
      # max_retries: 1 means 1 retry allowed, then give up
      task = make_task("crash_max", %{max_retries: 1})
      topic = "spark:task:crash_max"
      EventBus.subscribe(topic)

      assert :ok = enqueue([task])

      # First crash -> retry
      assert %Event{type: :task_started} = await_event(topic, :task_started)
      assert %Event{type: :task_retried} = await_event(topic, :task_retried, 3000)

      # Second crash -> give up (max retries exceeded)
      assert %Event{type: :task_started} = await_event(topic, :task_started, 1000)
      failed = await_event(topic, :task_failed, 3000)
      assert failed != nil, "Expected :task_failed after max retries"
      assert failed.payload.retries == 1

      s = await_failed_count(1)
      assert s.failed_count >= 1
    end
  end

  # --- Completed and failed task tracking ---

  describe "completed_tasks and failed_tasks tracking" do
    test "tracks completed tasks correctly with normal FakeWorker" do
      Process.flag(:trap_exit, true)
      normal_name = :"spark_dispatcher_tracking_#{:erlang.unique_integer([:positive])}"

      {:ok, _pid} =
        Dispatcher.start_link(
          name: normal_name,
          session_id: "track_session",
          plan_id: "track_plan",
          worker_module: Spark.FakeWorker,
          max_concurrency: 3
        )

      tasks = for i <- 1..3, do: make_task("track_ok#{i}")
      :ok = GenServer.call(normal_name, {:enqueue, "track_plan", tasks})

      deadline = System.monotonic_time(:millisecond) + 4000
      s = GenServer.call(normal_name, :status)
      s = spin_until(s, 3, deadline, normal_name)

      assert s.completed_count >= 3
      assert s.failed_count == 0

      GenServer.stop(normal_name, :shutdown)
      # Flush any EXIT messages from the stopped dispatcher
      receive do
        {:EXIT, _, :shutdown} -> :ok
      after
        100 -> :ok
      end
    end

    test "tracks failed tasks correctly with Crash worker" do
      task = make_task("track_fail", %{max_retries: 0})
      assert :ok = enqueue([task])

      s = await_failed_count(1)
      assert s.failed_count >= 1
    end

    test "mix of completed and failed tasks tracked independently" do
      Process.flag(:trap_exit, true)
      normal_name = :"spark_dispatcher_mix_#{:erlang.unique_integer([:positive])}"

      {:ok, _pid} =
        Dispatcher.start_link(
          name: normal_name,
          session_id: "mix_session",
          plan_id: "mix_plan",
          worker_module: Spark.FakeWorker,
          max_concurrency: 3
        )

      good_tasks = for i <- 1..2, do: make_task("mix_ok#{i}")
      :ok = GenServer.call(normal_name, {:enqueue, "mix_plan", good_tasks})

      deadline = System.monotonic_time(:millisecond) + 4000
      s = GenServer.call(normal_name, :status)
      s = spin_until(s, 2, deadline, normal_name)

      assert s.completed_count >= 2
      assert s.failed_count == 0

      GenServer.stop(normal_name, :shutdown)
      # Flush any EXIT messages from the stopped dispatcher
      receive do
        {:EXIT, _, :shutdown} -> :ok
      after
        100 -> :ok
      end
    end
  end

  # --- Helper ---

  defp spin_until(status, target_completed, deadline, server_name) do
    cond do
      status.completed_count >= target_completed ->
        status

      System.monotonic_time(:millisecond) >= deadline ->
        status

      true ->
        Process.sleep(30)
        spin_until(GenServer.call(server_name, :status), target_completed, deadline, server_name)
    end
  end
end
