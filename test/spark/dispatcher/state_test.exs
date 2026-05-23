defmodule Spark.Dispatcher.StateTest do
  use ExUnit.Case, async: false

  alias Spark.Dispatcher.State
  alias Spark.Types.Task

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "spark_disp_state_test_#{:erlang.unique_integer()}")
    File.mkdir_p!(tmp_dir)
    original_home = Application.get_env(:spark, :home_dir)
    Application.put_env(:spark, :home_dir, tmp_dir)

    if pid = Process.whereis(Spark.Config) do
      Agent.stop(pid)
    end

    on_exit(fn ->
      Application.put_env(:spark, :home_dir, original_home)
      try do
        if pid = Process.whereis(Spark.Config), do: Agent.stop(pid)
      catch :exit, _ -> :ok
      end
      File.rm_rf!(tmp_dir)
    end)

    :ok
  end

  defp make_task(id, opts \\ %{}) do
    Task.new(Map.merge(%{plan_id: "plan_1", title: "Task #{id}", id: id}, opts))
  end

  describe "new/1" do
    test "creates default state" do
      state = State.new()
      assert state.max_concurrency == 3
      assert state.paused? == false
      assert State.active_count(state) == 0
    end

    test "accepts overrides" do
      state = State.new(max_concurrency: 5, session_id: "sess_1", plan_id: "plan_1")
      assert state.max_concurrency == 5
      assert state.session_id == "sess_1"
      assert state.plan_id == "plan_1"
    end
  end

  describe "enqueue/2" do
    test "enqueues valid tasks" do
      state = State.new()
      task = make_task("t1")
      assert {:ok, new_state} = State.enqueue(state, [task])
      assert State.ready_tasks(new_state) != []
    end

    test "enqueues multiple tasks" do
      state = State.new()
      tasks = [make_task("t1"), make_task("t2"), make_task("t3")]
      {:ok, new_state} = State.enqueue(state, tasks)
      assert State.ready_tasks(new_state) |> length() == 3
    end

    test "rejects invalid tasks" do
      state = State.new()
      bad_task = %Task{id: "", plan_id: "p1", title: "Bad"}
      {:error, invalid} = State.enqueue(state, [bad_task])
      assert length(invalid) == 1
    end

    test "mixed valid and invalid: valid enqueued, invalid reported" do
      state = State.new()
      good = make_task("good")
      bad = %Task{id: "", plan_id: "p1", title: "Bad"}
      {:error, invalid} = State.enqueue(state, [good, bad])
      assert length(invalid) == 1
    end
  end

  describe "dequeue/2" do
    test "dequeues up to n ready tasks" do
      state = State.new()
      tasks = [make_task("t1"), make_task("t2"), make_task("t3")]
      {:ok, state} = State.enqueue(state, tasks)

      {dequeued, _state} = State.dequeue(state, 2)
      assert length(dequeued) == 2
    end

    test "returns fewer if not enough ready" do
      state = State.new()
      {:ok, state} = State.enqueue(state, [make_task("t1")])
      {dequeued, _} = State.dequeue(state, 5)
      assert length(dequeued) == 1
    end

    test "returns empty when queue empty" do
      state = State.new()
      {dequeued, _} = State.dequeue(state, 5)
      assert dequeued == []
    end

    test "does not dequeue tasks with unmet dependencies" do
      t1 = make_task("t1")
      t2 = make_task("t2", %{depends_on: ["t1"]})
      state = State.new()
      {:ok, state} = State.enqueue(state, [t1, t2])

      # Dequeue one at a time: t2 should not be ready until t1 is completed
      {[first], state} = State.dequeue(state, 1)
      assert first.id == "t1"

      # t2 is still in queue and not ready (t1 not completed yet)
      ready = State.ready_tasks(state)
      refute Enum.any?(ready, &(&1.id == "t2"))
    end

    test "dequeues dependent task after dependency completed" do
      t1 = make_task("t1")
      t2 = make_task("t2", %{depends_on: ["t1"]})
      state = State.new()
      {:ok, state} = State.enqueue(state, [t1, t2])
      {[_t1], state} = State.dequeue(state, 1)
      state = State.mark_completed(state, "t1")

      {dequeued, _} = State.dequeue(state, 5)
      ids = Enum.map(dequeued, & &1.id)
      assert "t2" in ids
    end
  end

  describe "next_ready/2" do
    test "returns :empty when queue is empty" do
      state = State.new()
      assert State.next_ready(state, []) == :empty
    end

    test "pulls task whose deps are satisfied" do
      state = State.new()
      t1 = make_task("t1")
      t2 = make_task("t2", %{depends_on: ["t1"]})
      {:ok, state} = State.enqueue(state, [t1, t2])

      # t1 has no deps, should be ready
      {task, state2} = State.next_ready(state, [])
      assert task.id == "t1"

      # t2 depends on t1, not ready with empty completed list
      assert State.next_ready(state2, []) == :empty

      # t2 is ready when t1 is in completed_ids
      {task2, _state3} = State.next_ready(state2, ["t1"])
      assert task2.id == "t2"
    end

    test "removes returned task from queue" do
      state = State.new()
      {:ok, state} = State.enqueue(state, [make_task("t1")])
      {_task, state2} = State.next_ready(state, [])
      assert :queue.len(state2.queue) == 0
    end
  end

  describe "write conflict detection" do
    test "does not dequeue task conflicting with active worker" do
      t1 = make_task("t1", %{write_paths: ["lib/foo.ex"]})
      t2 = make_task("t2", %{write_paths: ["lib/foo.ex"]})
      state = State.new()
      {:ok, state} = State.enqueue(state, [t1, t2])

      {[_t1], state} = State.dequeue(state, 1)
      state = State.add_active(state, "t1", %{
        pid: self(), monitor_ref: make_ref(), worker_id: "w1",
        started_at: DateTime.utc_now(), task: t1
      })

      # t2 should NOT be ready (write conflict with active t1)
      ready = State.ready_tasks(state)
      refute Enum.any?(ready, &(&1.id == "t2"))
    end

    test "non-conflicting task is ready" do
      t1 = make_task("t1", %{write_paths: ["lib/foo.ex"]})
      t2 = make_task("t2", %{write_paths: ["lib/bar.ex"]})
      state = State.new()
      {:ok, state} = State.enqueue(state, [t1, t2])
      {[_t1], state} = State.dequeue(state, 1)
      state = State.add_active(state, "t1", %{
        pid: self(), monitor_ref: make_ref(), worker_id: "w1",
        started_at: DateTime.utc_now(), task: t1
      })

      ready = State.ready_tasks(state)
      assert Enum.any?(ready, &(&1.id == "t2"))
    end
  end

  describe "active workers" do
    test "add and remove active workers" do
      state = State.new()
      state = State.add_active(state, "t1", %{pid: self(), monitor_ref: make_ref(), worker_id: "w1", started_at: DateTime.utc_now(), task: make_task("t1")})
      assert State.active_count(state) == 1

      state = State.remove_active(state, "t1")
      assert State.active_count(state) == 0
    end
  end

  describe "mark_completed/2 and mark_failed/3" do
    test "marks task completed" do
      state = State.new()
      state = State.mark_completed(state, "t1")
      assert MapSet.member?(state.completed_tasks, "t1")
    end

    test "marks task failed with info" do
      state = State.new()
      info = %{reason: :timeout, retries_used: 2}
      state = State.mark_failed(state, "t1", info)
      assert state.failed_tasks["t1"] == info
    end

    test "completed task satisfies dependencies" do
      t1 = make_task("t1")
      t2 = make_task("t2", %{depends_on: ["t1"]})
      state = State.new()
      {:ok, state} = State.enqueue(state, [t1, t2])

      state = State.mark_completed(state, "t1")
      ready = State.ready_tasks(state)
      assert Enum.any?(ready, &(&1.id == "t2"))
    end
  end

  describe "pause/1 and resume/1" do
    test "pause stops spawning" do
      state = State.new() |> State.pause()
      assert state.paused? == true
      refute State.can_spawn?(state)
    end

    test "resume enables spawning" do
      state = State.new() |> State.pause() |> State.resume()
      assert state.paused? == false
      assert State.can_spawn?(state)
    end

    test "can_spawn? respects concurrency limit" do
      state = State.new(max_concurrency: 1)
      assert State.can_spawn?(state)

      state = State.add_active(state, "t1", %{
        pid: self(), monitor_ref: make_ref(), worker_id: "w1",
        started_at: DateTime.utc_now(), task: make_task("t1")
      })

      refute State.can_spawn?(state)
    end
  end

  describe "status_map/1" do
    test "returns expected fields" do
      state = State.new(max_concurrency: 5, session_id: "s1", plan_id: "p1")
      status = State.status_map(state)

      assert status.active_count == 0
      assert status.max_concurrency == 5
      assert status.paused? == false
      assert status.queue_length == 0
      assert status.completed_count == 0
      assert status.failed_count == 0
      assert status.can_spawn? == true
      assert status.session_id == "s1"
      assert status.plan_id == "p1"
    end
  end

  describe "update_config/2" do
    test "updates max_concurrency" do
      state = State.new(max_concurrency: 3)
      state = State.update_config(state, %{"max_concurrency" => 5})
      assert state.max_concurrency == 5
    end

    test "rejects invalid max_concurrency" do
      state = State.new(max_concurrency: 3)
      state = State.update_config(state, %{"max_concurrency" => -1})
      assert state.max_concurrency == 3
    end

    test "rejects zero max_concurrency" do
      state = State.new(max_concurrency: 3)
      state = State.update_config(state, %{"max_concurrency" => 0})
      assert state.max_concurrency == 3
    end

    test "nil value keeps old" do
      state = State.new(max_concurrency: 3)
      state = State.update_config(state, %{"max_concurrency" => nil})
      assert state.max_concurrency == 3
    end
  end
end
