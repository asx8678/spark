defmodule Spark.Types.WorkerResultTest do
  use ExUnit.Case, async: true

  alias Spark.Types.WorkerResult

  describe "success/1" do
    test "creates a valid success result" do
      result =
        WorkerResult.success(%{
          task_id: "t1",
          worker_id: "w1",
          summary: "Fixed the bug",
          files_read: ["lib/foo.ex"],
          files_changed: ["lib/foo.ex"],
          started_at: DateTime.utc_now()
        })

      assert result.status == :success
      assert result.task_id == "t1"
      assert result.worker_id == "w1"
      assert result.summary == "Fixed the bug"
      assert result.completed_at != nil
    end
  end

  describe "failure/1" do
    test "creates a valid failure result" do
      result =
        WorkerResult.failure(%{
          task_id: "t1",
          worker_id: "w1",
          summary: "Failed to edit",
          errors: [%{reason: "file not found"}],
          started_at: DateTime.utc_now()
        })

      assert result.status == :failure
      assert result.errors == [%{reason: "file not found"}]
    end
  end

  describe "partial/1" do
    test "creates a valid partial result" do
      result =
        WorkerResult.partial(%{
          task_id: "t1",
          worker_id: "w1",
          summary: "Partially done",
          errors: [%{reason: "timeout on second file"}],
          started_at: DateTime.utc_now()
        })

      assert result.status == :partial
    end
  end

  describe "validate/1" do
    test "valid success result" do
      result =
        WorkerResult.success(%{
          task_id: "t1",
          worker_id: "w1",
          summary: "Done",
          started_at: DateTime.utc_now()
        })

      assert :ok = WorkerResult.validate(result)
    end

    test "valid failure result with errors" do
      result =
        WorkerResult.failure(%{
          task_id: "t1",
          worker_id: "w1",
          summary: "Failed",
          errors: [%{reason: "crash"}],
          started_at: DateTime.utc_now()
        })

      assert :ok = WorkerResult.validate(result)
    end

    test "failure without errors rejected" do
      result = %WorkerResult{
        task_id: "t1",
        worker_id: "w1",
        status: :failure,
        summary: "Failed",
        errors: [],
        started_at: DateTime.utc_now(),
        completed_at: DateTime.utc_now()
      }

      assert {:error, errors} = WorkerResult.validate(result)
      assert {:errors, "failure/partial must include errors"} in errors
    end

    test "partial without errors rejected" do
      result = %WorkerResult{
        task_id: "t1",
        worker_id: "w1",
        status: :partial,
        summary: "Partial",
        errors: [],
        started_at: DateTime.utc_now(),
        completed_at: DateTime.utc_now()
      }

      assert {:error, errors} = WorkerResult.validate(result)
      assert {:errors, "failure/partial must include errors"} in errors
    end

    test "missing task_id rejected" do
      result = %WorkerResult{
        task_id: "",
        worker_id: "w1",
        summary: "Done",
        started_at: DateTime.utc_now(),
        completed_at: DateTime.utc_now()
      }

      assert {:error, errors} = WorkerResult.validate(result)
      assert {:task_id, "must not be empty"} in errors
    end

    test "missing worker_id rejected" do
      result = %WorkerResult{
        task_id: "t1",
        worker_id: "",
        summary: "Done",
        started_at: DateTime.utc_now(),
        completed_at: DateTime.utc_now()
      }

      assert {:error, errors} = WorkerResult.validate(result)
      assert {:worker_id, "must not be empty"} in errors
    end

    test "invalid status rejected" do
      result = %WorkerResult{
        task_id: "t1",
        worker_id: "w1",
        status: :unknown,
        summary: "Done",
        started_at: DateTime.utc_now(),
        completed_at: DateTime.utc_now()
      }

      assert {:error, [{:status, "invalid status"}]} = WorkerResult.validate(result)
    end

    test "timestamp ordering validated - completed before started" do
      started = ~U[2026-01-01 12:00:00Z]
      completed = ~U[2026-01-01 11:00:00Z]

      result = %WorkerResult{
        task_id: "t1",
        worker_id: "w1",
        summary: "Done",
        started_at: started,
        completed_at: completed
      }

      assert {:error, errors} = WorkerResult.validate(result)
      assert {:completed_at, "must be after started_at"} in errors
    end

    test "timestamp ordering valid - completed after started" do
      started = ~U[2026-01-01 11:00:00Z]
      completed = ~U[2026-01-01 12:00:00Z]

      result = %WorkerResult{
        task_id: "t1",
        worker_id: "w1",
        summary: "Done",
        started_at: started,
        completed_at: completed
      }

      assert :ok = WorkerResult.validate(result)
    end
  end

  describe "retry_recommended?/1" do
    test "retryable error recommended" do
      result = %WorkerResult{
        status: :failure,
        errors: [%{reason: "LLM timeout waiting for response"}]
      }

      assert WorkerResult.retry_recommended?(result)
    end

    test "transient error recommended" do
      result = %WorkerResult{
        status: :failure,
        errors: [%{reason: "temporary connection failure"}]
      }

      assert WorkerResult.retry_recommended?(result)
    end

    test "429 rate limit recommended" do
      result = %WorkerResult{
        status: :failure,
        errors: [%{reason: "429 rate limit exceeded"}]
      }

      assert WorkerResult.retry_recommended?(result)
    end

    test "policy denied not recommended" do
      result = %WorkerResult{
        status: :failure,
        errors: [%{reason: "policy_denied: cannot write file"}]
      }

      refute WorkerResult.retry_recommended?(result)
    end

    test "invalid task not recommended" do
      result = %WorkerResult{
        status: :failure,
        errors: [%{reason: "invalid_task contract"}]
      }

      refute WorkerResult.retry_recommended?(result)
    end

    test "mixed retryable + non-retryable not recommended" do
      result = %WorkerResult{
        status: :failure,
        errors: [%{reason: "timeout"}, %{reason: "policy_denied"}]
      }

      refute WorkerResult.retry_recommended?(result)
    end

    test "success result not recommended" do
      result = %WorkerResult{status: :success, errors: []}
      refute WorkerResult.retry_recommended?(result)
    end

    test "empty errors not recommended" do
      result = %WorkerResult{status: :failure, errors: []}
      refute WorkerResult.retry_recommended?(result)
    end
  end
end
