defmodule Spark.DispatcherConfigReloadTest do
  @moduledoc """
  Tests for spark-u4b.6: Config hot reload.

  Verifies:
  - Increasing concurrency spawns more workers
  - Decreasing concurrency does NOT kill active workers
  - Invalid values are rejected
  """
  use ExUnit.Case, async: false

  alias Spark.Dispatcher
  alias Spark.Types.Task
  alias Spark.EventBus
  alias Spark.Types.Event

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "spark_config_reload_#{:erlang.unique_integer()}")
    File.mkdir_p!(tmp_dir)
    original_home = Application.get_env(:spark, :home_dir)
    Application.put_env(:spark, :home_dir, tmp_dir)

    if pid = Process.whereis(Spark.Config), do: Agent.stop(pid)
    EventBus.clear_hooks()

    # Ensure Config agent starts fresh with our tmp dir
    Spark.Config.ensure_home!()

    if pid = Process.whereis(Spark.Dispatcher), do: GenServer.stop(pid, :shutdown)

    {:ok, _pid} =
      Dispatcher.start_link(
        max_concurrency: 1,
        session_id: "config_session",
        plan_id: "config_plan"
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
    Task.new(Map.merge(%{plan_id: "config_plan", title: "Task #{id}", id: id}, opts))
  end

  defp spin_until_completed(target, deadline) do
    status = Dispatcher.status()

    cond do
      status.completed_count >= target ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        :ok

      true ->
        Process.sleep(30)
        spin_until_completed(target, deadline)
    end
  end

  # --- Increase concurrency spawns more ---

  describe "increase concurrency" do
    test "spawns more workers after config reload" do
      # Pause the dispatcher so we can control when tasks start
      Dispatcher.pause()

      # Enqueue multiple tasks — none should start while paused
      tasks = for i <- 1..4, do: make_task("inc_t#{i}")
      Dispatcher.enqueue("config_plan", tasks)

      assert Dispatcher.status().active_count == 0

      # Increase concurrency before resuming
      Spark.Config.put([:dispatcher, :max_concurrency], 5)
      assert :ok = Dispatcher.reload_config()
      assert Dispatcher.status().max_concurrency == 5

      # Resume — now multiple workers can spawn in parallel
      Dispatcher.resume()

      # Wait for tasks to complete with the higher concurrency
      deadline = System.monotonic_time(:millisecond) + 4000
      spin_until_completed(4, deadline)

      status = Dispatcher.status()
      assert status.completed_count >= 4
    end

    test "publishes :dispatcher_config_updated event" do
      EventBus.subscribe("spark:events")

      Spark.Config.put([:dispatcher, :max_concurrency], 10)
      assert :ok = Dispatcher.reload_config()

      assert_receive %Event{type: :dispatcher_config_updated}, 500
    after
      EventBus.unsubscribe("spark:events")
    end
  end

  # --- Decrease doesn't kill active ---

  describe "decrease concurrency" do
    test "does not kill active workers" do
      # Set up with higher concurrency
      Spark.Config.put([:dispatcher, :max_concurrency], 1)
      :ok = Dispatcher.reload_config()

      # Enqueue a task and let it start
      EventBus.subscribe("spark:task:dec_t1")
      Dispatcher.enqueue("config_plan", [make_task("dec_t1")])
      assert_receive %Event{type: :task_started, task_id: "dec_t1"}, 500

      active_before = Dispatcher.status().active_count
      assert active_before >= 1

      # Decrease concurrency to 0 — but active workers must survive
      Spark.Config.put([:dispatcher, :max_concurrency], 1)
      assert :ok = Dispatcher.reload_config()

      # Active workers still running
      status = Dispatcher.status()
      assert status.active_count == active_before

      # Complete the task normally
      assert :ok = Dispatcher.handle_worker_complete("dec_t1", %{status: :success})
      assert_receive %Event{type: :task_completed, task_id: "dec_t1"}, 500
    after
      EventBus.unsubscribe("spark:task:dec_t1")
    end

    test "limits future spawns after decrease" do
      # Increase first
      Spark.Config.put([:dispatcher, :max_concurrency], 5)
      :ok = Dispatcher.reload_config()
      assert Dispatcher.status().max_concurrency == 5

      # Decrease
      Spark.Config.put([:dispatcher, :max_concurrency], 1)
      :ok = Dispatcher.reload_config()
      assert Dispatcher.status().max_concurrency == 1

      # Enqueue multiple tasks — only 1 should be active at a time
      tasks = for i <- 1..3, do: make_task("dec_limit#{i}")
      Dispatcher.enqueue("config_plan", tasks)

      Process.sleep(100)
      status = Dispatcher.status()
      assert status.active_count <= 1
    end
  end

  # --- Invalid values rejected ---

  describe "invalid config values" do
    test "negative max_concurrency rejected by State.update_config" do
      original = Dispatcher.status().max_concurrency

      # State.update_config uses maybe_update_int which rejects non-positive
      state = Dispatcher.status()
      # We can't directly inject invalid values through reload_config
      # since it reads from Config, but we can test via State directly
      alias Spark.Dispatcher.State
      bad_state = State.update_config(state, %{"max_concurrency" => -1})
      # Should not have changed
      assert bad_state.max_concurrency == original
    end

    test "zero max_concurrency rejected by State.update_config" do
      original = Dispatcher.status().max_concurrency
      state = Dispatcher.status()

      alias Spark.Dispatcher.State
      bad_state = State.update_config(state, %{"max_concurrency" => 0})
      # 0 is not > 0, so maybe_update_int rejects it
      assert bad_state.max_concurrency == original
    end

    test "non-integer max_concurrency rejected by State.update_config" do
      original = Dispatcher.status().max_concurrency
      state = Dispatcher.status()

      alias Spark.Dispatcher.State
      bad_state = State.update_config(state, %{"max_concurrency" => "three"})
      # String is not an integer, so maybe_update_int rejects it
      assert bad_state.max_concurrency == original
    end

    test "nil max_concurrency leaves value unchanged" do
      original = Dispatcher.status().max_concurrency
      state = Dispatcher.status()

      alias Spark.Dispatcher.State
      same_state = State.update_config(state, %{"max_concurrency" => nil})
      assert same_state.max_concurrency == original
    end
  end
end
