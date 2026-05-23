defmodule Spark.Workspace.LockManagerTest do
  use ExUnit.Case, async: false

  alias Spark.Workspace.LockManager

  setup do
    # Start a fresh LockManager for each test
    name = :"lock_manager_#{:erlang.unique_integer([:positive])}"
    {:ok, pid} = LockManager.start_link(name: name)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)

    {:ok, name: name}
  end

  defp call(name, args), do: GenServer.call(name, args)

  describe "acquire/2" do
    test "acquires lock for a task on given paths", %{name: name} do
      :ok = call(name, {:acquire, "task_1", ["/project/src/foo.ex"]})
      locks = call(name, :status)
      assert locks == %{"/project/src/foo.ex" => "task_1"}
    end

    test "acquires multiple paths for same task", %{name: name} do
      :ok = call(name, {:acquire, "task_1", ["/project/a.ex", "/project/b.ex"]})
      locks = call(name, :status)
      assert locks["/project/a.ex"] == "task_1"
      assert locks["/project/b.ex"] == "task_1"
    end

    test "returns conflict when another task holds a lock", %{name: name} do
      :ok = call(name, {:acquire, "task_1", ["/project/src/foo.ex"]})
      result = call(name, {:acquire, "task_2", ["/project/src/foo.ex"]})
      assert {:error, :conflict, ["task_1"]} = result
    end

    test "allows same task to re-acquire same paths", %{name: name} do
      :ok = call(name, {:acquire, "task_1", ["/project/src/foo.ex"]})
      :ok = call(name, {:acquire, "task_1", ["/project/src/foo.ex"]})
    end

    test "detects prefix overlap — parent/child conflict", %{name: name} do
      :ok = call(name, {:acquire, "task_1", ["/project/src"]})
      result = call(name, {:acquire, "task_2", ["/project/src/foo.ex"]})
      assert {:error, :conflict, conflict_tasks} = result
      assert "task_1" in conflict_tasks
    end

    test "detects prefix overlap — child locks first, parent blocked", %{name: name} do
      :ok = call(name, {:acquire, "task_1", ["/project/src/foo.ex"]})
      result = call(name, {:acquire, "task_2", ["/project/src"]})
      assert {:error, :conflict, conflict_tasks} = result
      assert "task_1" in conflict_tasks
    end

    test "no conflict on unrelated paths", %{name: name} do
      :ok = call(name, {:acquire, "task_1", ["/project/a.ex"]})
      :ok = call(name, {:acquire, "task_2", ["/project/b.ex"]})
      locks = call(name, :status)
      assert map_size(locks) == 2
    end

    test "no partial locks on conflict", %{name: name} do
      :ok = call(name, {:acquire, "task_1", ["/project/a.ex"]})
      result = call(name, {:acquire, "task_2", ["/project/a.ex", "/project/b.ex"]})
      assert {:error, :conflict, _} = result
      # task_2 should NOT have gotten /project/b.ex either
      locks = call(name, :status)
      refute Map.has_key?(locks, "/project/b.ex")
    end
  end

  describe "release/1" do
    test "releases all locks for a task", %{name: name} do
      :ok = call(name, {:acquire, "task_1", ["/project/a.ex", "/project/b.ex"]})
      :ok = call(name, {:release, "task_1"})
      locks = call(name, :status)
      assert locks == %{}
    end

    test "release only affects the specified task", %{name: name} do
      :ok = call(name, {:acquire, "task_1", ["/project/a.ex"]})
      :ok = call(name, {:acquire, "task_2", ["/project/b.ex"]})
      :ok = call(name, {:release, "task_1"})
      locks = call(name, :status)
      assert locks == %{"/project/b.ex" => "task_2"}
    end

    test "release on unknown task is harmless", %{name: name} do
      :ok = call(name, {:release, "nonexistent"})
    end
  end

  describe "conflicts?/1" do
    test "returns false when no conflicts", %{name: name} do
      assert call(name, {:conflicts?, ["/project/a.ex"]}) == false
    end

    test "returns true with conflicting task ids", %{name: name} do
      :ok = call(name, {:acquire, "task_1", ["/project/a.ex"]})
      assert {true, tasks} = call(name, {:conflicts?, ["/project/a.ex"]})
      assert "task_1" in tasks
    end

    test "detects prefix overlap in conflicts?", %{name: name} do
      :ok = call(name, {:acquire, "task_1", ["/project/src"]})
      assert {true, _} = call(name, {:conflicts?, ["/project/src/deep/file.ex"]})
    end
  end

  describe "status/0" do
    test "returns empty map initially", %{name: name} do
      assert call(name, :status) == %{}
    end

    test "returns full lock state", %{name: name} do
      :ok = call(name, {:acquire, "task_1", ["/project/a.ex"]})
      :ok = call(name, {:acquire, "task_2", ["/project/b.ex", "/project/c.ex"]})
      locks = call(name, :status)
      assert locks["/project/a.ex"] == "task_1"
      assert locks["/project/b.ex"] == "task_2"
      assert locks["/project/c.ex"] == "task_2"
    end
  end
end
