defmodule Spark.Types.TaskRequestTest do
  use ExUnit.Case, async: true

  alias Spark.Types.TaskRequest

  describe "new/1" do
    test "creates a valid request with defaults" do
      req = TaskRequest.new(%{plan_id: "plan_abc", task_spec: %{title: "Fix bug"}})

      assert req.id != nil
      assert String.starts_with?(req.id, "req_")
      assert req.plan_id == "plan_abc"
      assert req.task_spec == %{title: "Fix bug"}
      assert req.context == %{}
      assert req.timeout_ms == 300_000
      assert req.created_at != nil
    end

    test "allows overriding defaults" do
      req =
        TaskRequest.new(%{
          plan_id: "plan_abc",
          task_spec: %{title: "Do thing"},
          context: %{session_id: "sess_123"},
          timeout_ms: 60_000
        })

      assert req.context == %{session_id: "sess_123"}
      assert req.timeout_ms == 60_000
    end

    test "uses provided id when given" do
      req = TaskRequest.new(%{id: "my_req", plan_id: "plan_abc", task_spec: %{title: "T"}})
      assert req.id == "my_req"
    end
  end

  describe "validate/1" do
    test "valid request returns :ok" do
      req = TaskRequest.new(%{plan_id: "plan_abc", task_spec: %{title: "Fix bug"}})
      assert :ok = TaskRequest.validate(req)
    end

    test "missing id is rejected" do
      req = %{TaskRequest.new(%{plan_id: "p1", task_spec: %{title: "T"}}) | id: ""}
      assert {:error, errors} = TaskRequest.validate(req)
      assert {:id, "must not be empty"} in errors
    end

    test "nil id is rejected" do
      req = %{TaskRequest.new(%{plan_id: "p1", task_spec: %{title: "T"}}) | id: nil}
      assert {:error, errors} = TaskRequest.validate(req)
      assert {:id, "must not be empty"} in errors
    end

    test "missing plan_id is rejected" do
      req = %{TaskRequest.new(%{task_spec: %{title: "T"}}) | plan_id: ""}
      assert {:error, errors} = TaskRequest.validate(req)
      assert {:plan_id, "must not be empty"} in errors
    end

    test "nil task_spec is rejected" do
      req = %{TaskRequest.new(%{plan_id: "p1", task_spec: %{title: "T"}}) | task_spec: nil}
      assert {:error, errors} = TaskRequest.validate(req)
      assert {:task_spec, "must be a non-empty map"} in errors
    end

    test "empty task_spec is rejected" do
      req = %{TaskRequest.new(%{plan_id: "p1", task_spec: %{title: "T"}}) | task_spec: %{}}
      assert {:error, errors} = TaskRequest.validate(req)
      assert {:task_spec, "must be a non-empty map"} in errors
    end

    test "non-map context is rejected" do
      req = %{TaskRequest.new(%{plan_id: "p1", task_spec: %{title: "T"}}) | context: "bad"}
      assert {:error, errors} = TaskRequest.validate(req)
      assert {:context, "must be a map"} in errors
    end

    test "zero timeout_ms is rejected" do
      req = %{TaskRequest.new(%{plan_id: "p1", task_spec: %{title: "T"}}) | timeout_ms: 0}
      assert {:error, errors} = TaskRequest.validate(req)
      assert {:timeout_ms, "must be a positive integer"} in errors
    end

    test "negative timeout_ms is rejected" do
      req = %{TaskRequest.new(%{plan_id: "p1", task_spec: %{title: "T"}}) | timeout_ms: -100}
      assert {:error, errors} = TaskRequest.validate(req)
      assert {:timeout_ms, "must be a positive integer"} in errors
    end

    test "multiple errors collected" do
      req = %TaskRequest{id: "", plan_id: "", task_spec: nil, context: "bad", timeout_ms: -1}
      assert {:error, errors} = TaskRequest.validate(req)
      assert length(errors) >= 4
    end
  end
end
