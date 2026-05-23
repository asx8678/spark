defmodule Spark.Dispatcher.RetryPolicyTest do
  use ExUnit.Case, async: true

  alias Spark.Dispatcher.RetryPolicy
  alias Spark.Types.Task

  defp make_task(opts \\ %{}) do
    Task.new(Map.merge(%{plan_id: "p1", title: "T", max_retries: 3}, opts))
  end

  describe "should_retry?/1" do
    test "allows retry when under max" do
      task = make_task(%{retry_count: 0, max_retries: 3})
      assert RetryPolicy.should_retry?(task)
    end

    test "allows retry at max-1" do
      task = make_task(%{retry_count: 2, max_retries: 3})
      assert RetryPolicy.should_retry?(task)
    end

    test "denies retry at max" do
      task = make_task(%{retry_count: 3, max_retries: 3})
      refute RetryPolicy.should_retry?(task)
    end

    test "denies retry over max" do
      task = make_task(%{retry_count: 5, max_retries: 3})
      refute RetryPolicy.should_retry?(task)
    end

    test "zero max_retries denies retry" do
      task = make_task(%{retry_count: 0, max_retries: 0})
      refute RetryPolicy.should_retry?(task)
    end
  end

  describe "retryable?/2" do
    test "LLM timeout is retryable" do
      assert RetryPolicy.retryable?(make_task(), :llm_timeout)
    end

    test "temporary HTTP failure is retryable" do
      assert RetryPolicy.retryable?(make_task(), :http_temporary)
    end

    test "tool timeout is retryable" do
      assert RetryPolicy.retryable?(make_task(), :tool_timeout)
    end

    test "worker crash is retryable" do
      assert RetryPolicy.retryable?(make_task(), :worker_crash)
    end

    test "connection error is retryable" do
      assert RetryPolicy.retryable?(make_task(), :connection_error)
    end

    test "rate limited is retryable" do
      assert RetryPolicy.retryable?(make_task(), :rate_limited)
    end

    test "policy violation is not retryable" do
      refute RetryPolicy.retryable?(make_task(), :policy_violation)
    end

    test "invalid task contract is not retryable" do
      refute RetryPolicy.retryable?(make_task(), :invalid_task_contract)
    end

    test "write conflict is not retryable" do
      refute RetryPolicy.retryable?(make_task(), :write_conflict)
    end

    test "tool forbidden is not retryable" do
      refute RetryPolicy.retryable?(make_task(), :tool_forbidden)
    end

    test "permanent failure is not retryable" do
      refute RetryPolicy.retryable?(make_task(), :permanent_failure)
    end

    test "unknown reason defaults to retryable" do
      assert RetryPolicy.retryable?(make_task(), :something_unusual)
    end
  end

  describe "decide/2" do
    test "retryable reason with retries remaining → {:retry, updated_task}" do
      task = make_task(%{retry_count: 0, max_retries: 3})
      assert {:retry, updated} = RetryPolicy.decide(task, :llm_timeout)
      assert updated.retry_count == 1
      assert updated.status == :queued
    end

    test "non-retryable reason → {:give_up, task}" do
      task = make_task(%{retry_count: 0, max_retries: 3})
      assert {:give_up, ^task} = RetryPolicy.decide(task, :policy_violation)
    end

    test "retryable reason but max retries exceeded → {:give_up, task}" do
      task = make_task(%{retry_count: 3, max_retries: 3})
      assert {:give_up, _task} = RetryPolicy.decide(task, :llm_timeout)
    end

    test "zero max_retries → {:give_up, task}" do
      task = make_task(%{retry_count: 0, max_retries: 0})
      assert {:give_up, _task} = RetryPolicy.decide(task, :llm_timeout)
    end
  end

  describe "reason lists" do
    test "retryable_reasons returns list" do
      reasons = RetryPolicy.retryable_reasons()
      assert :llm_timeout in reasons
      assert :worker_crash in reasons
    end

    test "non_retryable_reasons returns list" do
      reasons = RetryPolicy.non_retryable_reasons()
      assert :policy_violation in reasons
      assert :invalid_task_contract in reasons
    end

    test "no overlap between retryable and non-retryable" do
      r = RetryPolicy.retryable_reasons()
      nr = RetryPolicy.non_retryable_reasons()
      assert MapSet.disjoint?(MapSet.new(r), MapSet.new(nr))
    end
  end
end
