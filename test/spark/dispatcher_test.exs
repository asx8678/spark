defmodule Spark.DispatcherTest do
  use ExUnit.Case, async: false

  alias Spark.Dispatcher
  alias Spark.Types.Task
  alias Spark.EventBus
  alias Spark.Types.Event

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "spark_disp_test_#{:erlang.unique_integer()}")
    File.mkdir_p!(tmp_dir)
    original_home = Application.get_env(:spark, :home_dir)
    Application.put_env(:spark, :home_dir, tmp_dir)

    if pid = Process.whereis(Spark.Config), do: Agent.stop(pid)
    EventBus.clear_hooks()

    if pid = Process.whereis(Spark.Dispatcher), do: GenServer.stop(pid, :shutdown)

    {:ok, _pid} = Dispatcher.start_link(session_id: "test_session", plan_id: "test_plan")

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
    Task.new(Map.merge(%{plan_id: "test_plan", title: "Task #{id}", id: id}, opts))
  end

  defp await_completed_count(count, timeout \\ 2000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_completed_count(count, deadline)
  end

  defp do_await_completed_count(count, deadline) do
    status = Dispatcher.status()

    cond do
      status.completed_count >= count ->
        status

      System.monotonic_time(:millisecond) >= deadline ->
        status

      true ->
        Process.sleep(20)
        do_await_completed_count(count, deadline)
    end
  end

  # --- enqueue ---

  describe "enqueue/2" do
    test "enqueues tasks and publishes task_queued events" do
      EventBus.subscribe("spark:task:t1")
      EventBus.subscribe("spark:task:t2")

      tasks = [make_task("t1"), make_task("t2")]
      assert :ok = Dispatcher.enqueue("plan_1", tasks)

      assert_receive %Event{type: :task_queued, task_id: "t1"}, 500
      assert_receive %Event{type: :task_queued, task_id: "t2"}, 500
    after
      EventBus.unsubscribe("spark:task:t1")
      EventBus.unsubscribe("spark:task:t2")
    end

    test "rejects invalid tasks" do
      bad_task = %Task{id: nil, plan_id: "", title: "bad"}
      assert {:error, _} = Dispatcher.enqueue("plan_1", [bad_task])
    end
  end

  # --- spawning ---

  describe "worker spawning" do
    test "spawns workers for ready tasks" do
      EventBus.subscribe("spark:task:t1")

      Dispatcher.enqueue("plan_1", [make_task("t1")])

      assert_receive %Event{type: :task_queued, task_id: "t1"}, 500
      assert_receive %Event{type: :task_started, task_id: "t1"}, 500
    after
      EventBus.unsubscribe("spark:task:t1")
    end

    test "marks task completed when FakeWorker finishes" do
      EventBus.subscribe("spark:task:t1")

      Dispatcher.enqueue("plan_1", [make_task("t1")])

      assert_receive %Event{type: :task_started, task_id: "t1"}, 500
      assert_receive %Event{type: :task_completed, task_id: "t1"}, 2000

      status = await_completed_count(1)
      assert status.completed_count >= 1
    after
      EventBus.unsubscribe("spark:task:t1")
    end

    test "handle_worker_complete processes completion" do
      EventBus.subscribe("spark:task:t1")

      Dispatcher.enqueue("plan_1", [make_task("t1")])
      assert_receive %Event{type: :task_started, task_id: "t1"}, 500

      Dispatcher.handle_worker_complete("t1", %{status: :success})

      assert_receive %Event{type: :task_completed, task_id: "t1"}, 500
    after
      EventBus.unsubscribe("spark:task:t1")
    end

    test "handle_worker_failed marks task failed" do
      EventBus.subscribe("spark:task:t1")

      Dispatcher.enqueue("plan_1", [make_task("t1")])
      assert_receive %Event{type: :task_started, task_id: "t1"}, 500

      Dispatcher.handle_worker_failed("t1", :llm_timeout)

      receive do
        %Event{type: type, task_id: "t1"} when type in [:task_failed, :task_retried] -> :ok
      after
        500 -> flunk("Expected task_failed or task_retried event")
      end
    after
      EventBus.unsubscribe("spark:task:t1")
    end
  end

  # --- concurrency limits ---

  describe "concurrency limits" do
    test "respects max concurrency" do
      tasks = for i <- 1..5, do: make_task("ct#{i}")
      Dispatcher.enqueue("plan_1", tasks)

      status = Dispatcher.status()
      assert status.active_count <= status.max_concurrency
    end

    test "spawns remaining tasks after workers finish" do
      tasks = for i <- 1..4, do: make_task("drain#{i}")
      Dispatcher.enqueue("plan_1", tasks)

      status = await_completed_count(4, 4000)
      assert status.completed_count >= 4
    end
  end

  # --- dependency resolution ---

  describe "dependency resolution" do
    test "only spawns tasks with met dependencies" do
      EventBus.subscribe("spark:task:dep_t1")
      EventBus.subscribe("spark:task:dep_t2")

      t1 = make_task("dep_t1")
      t2 = make_task("dep_t2", %{depends_on: ["dep_t1"]})

      Dispatcher.enqueue("plan_1", [t1, t2])

      # t1 should start first
      assert_receive %Event{type: :task_started, task_id: "dep_t1"}, 500

      # Both should eventually complete, with t1 before t2
      assert_receive %Event{type: :task_completed, task_id: "dep_t1"}, 2000
      assert_receive %Event{type: :task_started, task_id: "dep_t2"}, 500
      assert_receive %Event{type: :task_completed, task_id: "dep_t2"}, 2000

      EventBus.unsubscribe("spark:task:dep_t1")
      EventBus.unsubscribe("spark:task:dep_t2")
    end
  end

  # --- pause/resume ---

  describe "pause/0 and resume/0" do
    test "pause stops spawning" do
      assert :ok = Dispatcher.pause()
      status = Dispatcher.status()
      assert status.paused? == true
    end

    test "resume enables spawning" do
      Dispatcher.pause()
      assert :ok = Dispatcher.resume()
      status = Dispatcher.status()
      assert status.paused? == false
    end

    test "paused dispatcher does not spawn workers" do
      Dispatcher.pause()
      Dispatcher.enqueue("plan_1", [make_task("paused_t")])

      status = Dispatcher.status()
      assert status.paused? == true
      assert status.active_count == 0
    end

    test "resume spawns queued tasks" do
      EventBus.subscribe("spark:task:resume_t")

      Dispatcher.pause()
      Dispatcher.enqueue("plan_1", [make_task("resume_t")])

      assert Dispatcher.status().active_count == 0

      Dispatcher.resume()

      assert_receive %Event{type: :task_started, task_id: "resume_t"}, 500
    after
      EventBus.unsubscribe("spark:task:resume_t")
    end
  end

  # --- status ---

  describe "status/0" do
    test "returns expected fields" do
      status = Dispatcher.status()

      assert Map.has_key?(status, :active_count)
      assert Map.has_key?(status, :max_concurrency)
      assert Map.has_key?(status, :paused?)
      assert Map.has_key?(status, :queue_length)
      assert Map.has_key?(status, :completed_count)
      assert Map.has_key?(status, :failed_count)
      assert Map.has_key?(status, :can_spawn?)
    end

    test "reflects queue growth after enqueue" do
      tasks = for i <- 1..3, do: make_task("sq#{i}", %{depends_on: ["nonexistent"]})
      Dispatcher.enqueue("plan_1", tasks)

      Process.sleep(50)
      status = Dispatcher.status()
      assert status.queue_length > 0
    end
  end

  # --- task_statuses ---

  describe "task_statuses/0" do
    test "returns empty list for fresh dispatcher" do
      assert Dispatcher.task_statuses() == []
    end

    test "includes queued tasks when paused" do
      Dispatcher.pause()
      Dispatcher.enqueue("plan_1", [make_task("ts_q1", %{title: "Queued task"})])

      statuses = Dispatcher.task_statuses()
      assert length(statuses) >= 1
      assert Enum.any?(statuses, &(&1.task_id == "ts_q1" and &1.status == :queued))
    end

    test "includes running and completed tasks after execution" do
      EventBus.subscribe("spark:task:ts_run")
      Dispatcher.enqueue("plan_1", [make_task("ts_run", %{title: "Running task"})])

      assert_receive %Event{type: :task_completed, task_id: "ts_run"}, 2000

      # Small delay to let dispatcher state catch up (cast-based update)
      Process.sleep(50)
      statuses = Dispatcher.task_statuses()
      assert Enum.any?(statuses, &(&1.task_id == "ts_run" and &1.status == :completed))
    after
      EventBus.unsubscribe("spark:task:ts_run")
    end

    test "returns list of maps with required keys" do
      Dispatcher.pause()
      Dispatcher.enqueue("plan_1", [make_task("ts_keys")])

      statuses = Dispatcher.task_statuses()

      for entry <- statuses do
        assert Map.has_key?(entry, :task_id)
        assert Map.has_key?(entry, :title)
        assert Map.has_key?(entry, :status)
        assert entry.status in [:queued, :running, :completed, :failed]
      end
    end
  end
end
