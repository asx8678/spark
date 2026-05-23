defmodule Spark.Types.TaskTest do
  use ExUnit.Case, async: true

  alias Spark.Types.Task

  describe "new/1" do
    test "creates a valid task with defaults" do
      task = Task.new(%{plan_id: "plan_abc", title: "Fix bug"})

      assert task.id != nil
      assert task.plan_id == "plan_abc"
      assert task.title == "Fix bug"
      assert task.status == :queued
      assert task.priority == 0
      assert task.depends_on == []
      assert task.read_paths == []
      assert task.write_paths == []
      assert task.risk == :medium
      assert task.max_retries == 3
      assert task.retry_count == 0
      assert task.timeout_ms == 300_000
      assert task.created_at != nil
      assert task.started_at == nil
      assert task.completed_at == nil
      assert task.context == %{}
    end

    test "allows overriding defaults" do
      task =
        Task.new(%{
          plan_id: "plan_abc",
          title: "Refactor",
          risk: :high,
          priority: 5,
          max_retries: 1,
          timeout_ms: 60_000
        })

      assert task.risk == :high
      assert task.priority == 5
      assert task.max_retries == 1
      assert task.timeout_ms == 60_000
    end

    test "uses provided id when given" do
      task = Task.new(%{id: "my_task", plan_id: "plan_abc", title: "Do thing"})
      assert task.id == "my_task"
    end
  end

  describe "validate/1" do
    test "valid task returns :ok" do
      task = Task.new(%{plan_id: "plan_abc", title: "Fix bug"})
      assert :ok = Task.validate(task)
    end

    test "missing id is rejected" do
      task = %{Task.new(%{plan_id: "p1", title: "T"}) | id: ""}
      assert {:error, [{:id, "must not be empty"} | _]} = Task.validate(task)
    end

    test "nil id is rejected" do
      task = %{Task.new(%{plan_id: "p1", title: "T"}) | id: nil}
      assert {:error, errors} = Task.validate(task)
      assert {:id, "must not be empty"} in errors
    end

    test "missing plan_id is rejected" do
      task = %{Task.new(%{title: "T"}) | plan_id: ""}
      assert {:error, errors} = Task.validate(task)
      assert {:plan_id, "must not be empty"} in errors
    end

    test "invalid risk is rejected" do
      task = %{Task.new(%{plan_id: "p1", title: "T"}) | risk: :critical}
      assert {:error, [{:risk, "invalid risk"}]} = Task.validate(task)
    end

    test "invalid status is rejected" do
      task = %{Task.new(%{plan_id: "p1", title: "T"}) | status: :unknown}
      assert {:error, [{:status, "invalid status"}]} = Task.validate(task)
    end

    test "negative retry_count is rejected" do
      task = %{Task.new(%{plan_id: "p1", title: "T"}) | retry_count: -1}
      assert {:error, [{:retry_count, "cannot be negative"}]} = Task.validate(task)
    end

    test "negative max_retries is rejected" do
      task = %{Task.new(%{plan_id: "p1", title: "T"}) | max_retries: -1}
      assert {:error, [{:max_retries, "cannot be negative"}]} = Task.validate(task)
    end

    test "zero timeout_ms is rejected" do
      task = %{Task.new(%{plan_id: "p1", title: "T"}) | timeout_ms: 0}
      assert {:error, [{:timeout_ms, "must be positive"}]} = Task.validate(task)
    end

    test "multiple errors collected" do
      task = %Task{id: "", plan_id: "", risk: :invalid}
      assert {:error, errors} = Task.validate(task)
      assert length(errors) >= 3
    end
  end

  describe "ready?/2" do
    test "queued task with no dependencies is ready" do
      task = Task.new(%{plan_id: "p1", title: "T"})
      assert Task.ready?(task, [])
    end

    test "queued task with met dependencies is ready" do
      task = Task.new(%{plan_id: "p1", title: "T", depends_on: ["task_a", "task_b"]})
      assert Task.ready?(task, ["task_a", "task_b", "task_c"])
    end

    test "queued task with unmet dependencies is not ready" do
      task = Task.new(%{plan_id: "p1", title: "T", depends_on: ["task_a", "task_b"]})
      refute Task.ready?(task, ["task_a"])
    end

    test "running task is not ready" do
      task = %{Task.new(%{plan_id: "p1", title: "T"}) | status: :running}
      refute Task.ready?(task, [])
    end

    test "completed task is not ready" do
      task = %{Task.new(%{plan_id: "p1", title: "T"}) | status: :completed}
      refute Task.ready?(task, [])
    end
  end

  describe "write_conflicts?/2" do
    test "overlapping write paths detected" do
      task_a = Task.new(%{plan_id: "p1", title: "A", write_paths: ["lib/foo.ex"]})
      task_b = Task.new(%{plan_id: "p1", title: "B", write_paths: ["lib/foo.ex", "lib/bar.ex"]})
      assert Task.write_conflicts?(task_a, task_b)
    end

    test "non-overlapping write paths" do
      task_a = Task.new(%{plan_id: "p1", title: "A", write_paths: ["lib/foo.ex"]})
      task_b = Task.new(%{plan_id: "p1", title: "B", write_paths: ["lib/bar.ex"]})
      refute Task.write_conflicts?(task_a, task_b)
    end

    test "empty write paths no conflict" do
      task_a = Task.new(%{plan_id: "p1", title: "A", write_paths: []})
      task_b = Task.new(%{plan_id: "p1", title: "B", write_paths: ["lib/bar.ex"]})
      refute Task.write_conflicts?(task_a, task_b)
    end

    test "both empty no conflict" do
      task_a = Task.new(%{plan_id: "p1", title: "A", write_paths: []})
      task_b = Task.new(%{plan_id: "p1", title: "B", write_paths: []})
      refute Task.write_conflicts?(task_a, task_b)
    end
  end

  describe "high_risk?/1" do
    test "high risk returns true" do
      task = Task.new(%{plan_id: "p1", title: "T", risk: :high})
      assert Task.high_risk?(task)
    end

    test "medium risk returns false" do
      task = Task.new(%{plan_id: "p1", title: "T", risk: :medium})
      refute Task.high_risk?(task)
    end

    test "low risk returns false" do
      task = Task.new(%{plan_id: "p1", title: "T", risk: :low})
      refute Task.high_risk?(task)
    end
  end

  describe "increment_retry/1" do
    test "increments retry count and resets status" do
      task = %{Task.new(%{plan_id: "p1", title: "T"}) | status: :failed, retry_count: 0}
      {:ok, updated} = Task.increment_retry(task)
      assert updated.retry_count == 1
      assert updated.status == :queued
      assert updated.started_at == nil
      assert updated.completed_at == nil
    end

    test "returns error when max retries exceeded" do
      task = %{Task.new(%{plan_id: "p1", title: "T", max_retries: 2}) | retry_count: 2}
      assert {:error, :max_retries_exceeded} = Task.increment_retry(task)
    end

    test "allows retry when under max" do
      task = %{Task.new(%{plan_id: "p1", title: "T", max_retries: 3}) | retry_count: 2}
      assert {:ok, _} = Task.increment_retry(task)
    end
  end
end
