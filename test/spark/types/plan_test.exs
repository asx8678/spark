defmodule Spark.Types.PlanTest do
  use ExUnit.Case, async: true

  alias Spark.Types.Plan
  alias Spark.Types.Task

  defp valid_task(attrs \\ %{}) do
    Task.new(Map.merge(%{plan_id: "plan_1", title: "Do thing"}, attrs))
  end

  describe "new/1" do
    test "creates a valid plan with defaults" do
      plan =
        Plan.new(%{user_goal: "Add auth", summary: "Add authentication", tasks: [valid_task()]})

      assert plan.id != nil
      assert plan.user_goal == "Add auth"
      assert plan.summary == "Add authentication"
      assert plan.approval_status == :draft
      assert plan.created_at != nil
      assert plan.approved_at == nil
      assert plan.metadata == %{}
    end

    test "uses provided id when given" do
      plan = Plan.new(%{id: "my_plan", user_goal: "G", summary: "S", tasks: [valid_task()]})
      assert plan.id == "my_plan"
    end
  end

  describe "validate/1" do
    test "valid plan returns :ok" do
      plan =
        Plan.new(%{user_goal: "Add auth", summary: "Add authentication", tasks: [valid_task()]})

      assert :ok = Plan.validate(plan)
    end

    test "duplicate task IDs rejected" do
      t1 = %{valid_task() | id: "dup_id"}
      t2 = %{valid_task() | id: "dup_id"}
      plan = Plan.new(%{user_goal: "G", summary: "S", tasks: [t1, t2]})
      assert {:error, errors} = Plan.validate(plan)
      assert Enum.any?(errors, fn {k, _} -> k == :tasks end)
    end

    test "invalid nested task rejected" do
      bad_task = %{valid_task() | plan_id: ""}
      plan = Plan.new(%{user_goal: "G", summary: "S", tasks: [bad_task]})
      assert {:error, errors} = Plan.validate(plan)
      assert Enum.any?(errors, fn {k, _} -> k == :task_validation end)
    end

    test "empty tasks rejected" do
      plan = %{Plan.new(%{user_goal: "G", summary: "S"}) | tasks: []}
      assert {:error, errors} = Plan.validate(plan)
      assert {:tasks, "must not be empty"} in errors
    end

    test "missing user_goal rejected" do
      plan = %{Plan.new(%{summary: "S", tasks: [valid_task()]}) | user_goal: ""}
      assert {:error, errors} = Plan.validate(plan)
      assert {:user_goal, "must not be empty"} in errors
    end

    test "missing summary rejected" do
      plan = %{Plan.new(%{user_goal: "G", tasks: [valid_task()]}) | summary: ""}
      assert {:error, errors} = Plan.validate(plan)
      assert {:summary, "must not be empty"} in errors
    end
  end

  describe "approval state machine" do
    test "awaiting_approval sets status" do
      plan = Plan.new(%{user_goal: "G", summary: "S", tasks: [valid_task()]})
      assert plan.approval_status == :draft
      updated = Plan.awaiting_approval(plan)
      assert updated.approval_status == :awaiting_approval
    end

    test "approve plan sets status and timestamp" do
      plan =
        Plan.new(%{user_goal: "G", summary: "S", tasks: [valid_task()]})
        |> Plan.awaiting_approval()

      {:ok, approved} = Plan.approve(plan)
      assert approved.approval_status == :approved
      assert match?(%DateTime{}, approved.approved_at)
    end

    test "approve non-awaiting plan fails" do
      plan = Plan.new(%{user_goal: "G", summary: "S", tasks: [valid_task()]})
      assert {:error, _} = Plan.approve(plan)
    end

    test "reject plan sets status" do
      plan =
        Plan.new(%{user_goal: "G", summary: "S", tasks: [valid_task()]})
        |> Plan.awaiting_approval()

      {:ok, rejected} = Plan.reject(plan)
      assert rejected.approval_status == :rejected
    end

    test "reject non-awaiting plan fails" do
      plan = Plan.new(%{user_goal: "G", summary: "S", tasks: [valid_task()]})
      assert {:error, _} = Plan.reject(plan)
    end

    test "modify plan resets status" do
      plan =
        Plan.new(%{user_goal: "G", summary: "S", tasks: [valid_task()]})
        |> Plan.awaiting_approval()

      modified = Plan.modify(plan, %{"reason" => "need more tests"})
      assert modified.approval_status == :modified
      assert modified.metadata["reason"] == "need more tests"
    end
  end

  describe "task_ids/1" do
    test "returns all task IDs" do
      t1 = %{valid_task() | id: "t1"}
      t2 = %{valid_task() | id: "t2"}
      plan = Plan.new(%{user_goal: "G", summary: "S", tasks: [t1, t2]})
      assert Plan.task_ids(plan) == ["t1", "t2"]
    end
  end
end
