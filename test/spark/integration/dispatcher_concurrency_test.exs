defmodule Spark.Integration.DispatcherConcurrencyTest do
  @moduledoc """
  spark-opg.2: Dispatcher concurrency test.

  Enqueue 10 tasks with max_concurrency=3.
  Verify at most 3 workers active simultaneously.
  All tasks eventually complete. Queue drains.
  """

  use ExUnit.Case, async: false

  alias Spark.Integration.TestHelpers

  alias Spark.Dispatcher
  alias Spark.Types.Task
  alias Spark.EventBus

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "spark_concurrency_#{:erlang.unique_integer()}")
    File.mkdir_p!(tmp_dir)
    original_home = Application.get_env(:spark, :home_dir)
    Application.put_env(:spark, :home_dir, tmp_dir)

    if pid = Process.whereis(Spark.Config), do: Agent.stop(pid)
    Spark.Config.ensure_home!()
    EventBus.clear_hooks()
    TestHelpers.ensure_app_tree()

    if pid = Process.whereis(Spark.Dispatcher), do: GenServer.stop(pid, :shutdown)

    on_exit(fn ->
      Application.put_env(:spark, :home_dir, original_home)
      EventBus.clear_hooks()
      try do
        if pid = Process.whereis(Spark.Dispatcher), do: GenServer.stop(pid, :shutdown)
      catch :exit, _ -> :ok
      end
      # Don't stop Config Agent — it may cascade to kill Application tree processes
      File.rm_rf!(tmp_dir)
    end)

    :ok
  end

  defp make_task(id, opts \\ %{}) do
    Task.new(Map.merge(%{plan_id: "concurrency_plan", title: "Task #{id}", id: id}, opts))
  end

  defp await_all_completed(count, timeout \\ 5000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    spin(deadline, &(&1.completed_count >= count))
  end

  defp spin(deadline, check) do
    status = Dispatcher.status()
    cond do
      check.(status) -> :ok
      System.monotonic_time(:millisecond) >= deadline -> :timeout
      true -> Process.sleep(20); spin(deadline, check)
    end
  end



  describe "concurrency enforcement with max_concurrency=3" do
    test "at most 3 workers active simultaneously" do
      {:ok, _pid} =
        Dispatcher.start_link(
          max_concurrency: 3,
          session_id: "concurrency_session",
          plan_id: "concurrency_plan",
          worker_module: Spark.FakeWorker
        )

      tasks = for i <- 1..10, do: make_task("ct#{i}")
      assert :ok = Dispatcher.enqueue("concurrency_plan", tasks)

      max_observed = observe_max_concurrency(500)
      assert max_observed <= 3,
             "Expected max active workers <= 3, observed #{max_observed}"
    end

    test "all 10 tasks eventually complete" do
      {:ok, _pid} =
        Dispatcher.start_link(
          max_concurrency: 3,
          session_id: "concurrency_session",
          plan_id: "concurrency_plan",
          worker_module: Spark.FakeWorker
        )

      tasks = for i <- 1..10, do: make_task("complete#{i}")
      assert :ok = Dispatcher.enqueue("concurrency_plan", tasks)

      :ok = await_all_completed(10, 5000)
    end

    test "queue drains completely" do
      {:ok, _pid} =
        Dispatcher.start_link(
          max_concurrency: 3,
          session_id: "concurrency_session",
          plan_id: "concurrency_plan",
          worker_module: Spark.FakeWorker
        )

      tasks = for i <- 1..10, do: make_task("drain#{i}")
      assert :ok = Dispatcher.enqueue("concurrency_plan", tasks)

      :ok = await_all_completed(10, 5000)

      status = Dispatcher.status()
      assert status.queue_length == 0, "Queue should be empty, got #{status.queue_length}"
      assert status.active_count == 0, "No active workers should remain"
      assert status.completed_count == 10
    end

    test "concurrency increases spawn rate after workers finish" do
      {:ok, _pid} =
        Dispatcher.start_link(
          max_concurrency: 3,
          session_id: "concurrency_session",
          plan_id: "concurrency_plan",
          worker_module: Spark.FakeWorker
        )

      tasks = for i <- 1..10, do: make_task("batch#{i}")
      :ok = Dispatcher.enqueue("concurrency_plan", tasks)

      Process.sleep(50)
      status = Dispatcher.status()
      assert status.active_count <= 3

      :ok = await_all_completed(10, 5000)

      final = Dispatcher.status()
      assert final.completed_count == 10
      assert final.queue_length == 0
    end
  end

  defp observe_max_concurrency(duration_ms) do
    deadline = System.monotonic_time(:millisecond) + duration_ms
    do_observe_max(deadline, 0)
  end

  defp do_observe_max(deadline, max_so_far) do
    status = Dispatcher.status()
    current = max(max_so_far, status.active_count)

    if System.monotonic_time(:millisecond) >= deadline do
      current
    else
      Process.sleep(10)
      do_observe_max(deadline, current)
    end
  end
end
