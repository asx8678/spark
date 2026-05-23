defmodule Spark.DispatcherRetryTest do
  @moduledoc """
  Tests for spark-u4b.5: Retry policy.

  Verifies:
  - Retryable reasons allow retry
  - Non-retryable reasons deny retry
  - Max retries exceeded returns {:give_up, task} even for retryable reason
  """
  use ExUnit.Case, async: true

  alias Spark.Dispatcher.RetryPolicy
  alias Spark.Types.Task

  defp make_task(opts \\ %{}) do
    Task.new(Map.merge(%{plan_id: "p1", title: "T", max_retries: 3}, opts))
  end

  # --- Retryable reasons allow retry ---

  describe "retryable reasons" do
    test ":llm_timeout is retryable" do
      assert RetryPolicy.retryable?(make_task(), :llm_timeout)
    end

    test ":http_temporary is retryable" do
      assert RetryPolicy.retryable?(make_task(), :http_temporary)
    end

    test ":tool_timeout is retryable" do
      assert RetryPolicy.retryable?(make_task(), :tool_timeout)
    end

    test ":worker_crash is retryable" do
      assert RetryPolicy.retryable?(make_task(), :worker_crash)
    end

    test ":connection_error is retryable" do
      assert RetryPolicy.retryable?(make_task(), :connection_error)
    end

    test ":rate_limited is retryable" do
      assert RetryPolicy.retryable?(make_task(), :rate_limited)
    end

    test ":timeout (spec) is retryable" do
      assert RetryPolicy.retryable?(make_task(), :timeout)
    end

    test ":crash (spec) is retryable" do
      assert RetryPolicy.retryable?(make_task(), :crash)
    end

    test ":transient (spec) is retryable" do
      assert RetryPolicy.retryable?(make_task(), :transient)
    end

    test ":http_error (spec) is retryable" do
      assert RetryPolicy.retryable?(make_task(), :http_error)
    end

    test "retryable reason with retries remaining → {:retry, _}" do
      task = make_task(%{retry_count: 0, max_retries: 3})
      assert {:retry, updated} = RetryPolicy.decide(task, :timeout)
      assert updated.retry_count == 1
      assert updated.status == :queued
    end
  end

  # --- Non-retryable reasons deny retry ---

  describe "non-retryable reasons" do
    test ":policy_violation is not retryable" do
      refute RetryPolicy.retryable?(make_task(), :policy_violation)
    end

    test ":invalid_task_contract is not retryable" do
      refute RetryPolicy.retryable?(make_task(), :invalid_task_contract)
    end

    test ":write_conflict is not retryable" do
      refute RetryPolicy.retryable?(make_task(), :write_conflict)
    end

    test ":tool_forbidden is not retryable" do
      refute RetryPolicy.retryable?(make_task(), :tool_forbidden)
    end

    test ":permanent_failure is not retryable" do
      refute RetryPolicy.retryable?(make_task(), :permanent_failure)
    end

    test ":invalid_task (spec) is not retryable" do
      refute RetryPolicy.retryable?(make_task(), :invalid_task)
    end

    test ":forbidden (spec) is not retryable" do
      refute RetryPolicy.retryable?(make_task(), :forbidden)
    end

    test ":permanent (spec) is not retryable" do
      refute RetryPolicy.retryable?(make_task(), :permanent)
    end

    test "non-retryable reason → {:give_up, task}" do
      task = make_task(%{retry_count: 0, max_retries: 3})
      assert {:give_up, ^task} = RetryPolicy.decide(task, :policy_violation)
    end
  end

  # --- Max retries exceeded ---

  describe "max retries exceeded" do
    test "retryable reason but max retries exceeded → {:give_up, task}" do
      task = make_task(%{retry_count: 3, max_retries: 3})
      assert {:give_up, _task} = RetryPolicy.decide(task, :timeout)
    end

    test "retryable reason but max retries exceeded with :crash" do
      task = make_task(%{retry_count: 3, max_retries: 3})
      assert {:give_up, _task} = RetryPolicy.decide(task, :crash)
    end

    test "zero max_retries → {:give_up, task} for retryable reason" do
      task = make_task(%{retry_count: 0, max_retries: 0})
      assert {:give_up, _task} = RetryPolicy.decide(task, :connection_error)
    end
  end
end
