defmodule Spark.Dispatcher.RetryPolicy do
  @moduledoc """
  Determines whether a failed task should be retried.

  Retryable failures: LLM timeout, temporary HTTP error, tool timeout,
  worker crash without file mutation.

  Non-retryable: policy violation, invalid task contract, repeated write
  conflict, tool forbidden by risk rules, max retries exceeded.
  """

  alias Spark.Types.Task

  @retryable_reasons [
    :llm_timeout,
    :http_temporary,
    :tool_timeout,
    :worker_crash,
    :connection_error,
    :rate_limited,
    :timeout,
    :crash,
    :transient,
    :http_error
  ]

  @non_retryable_reasons [
    :policy_violation,
    :invalid_task_contract,
    :write_conflict,
    :tool_forbidden,
    :permanent_failure,
    :invalid_task,
    :forbidden,
    :permanent
  ]

  @doc """
  Checks if a task can be retried (retry_count < max_retries).
  """
  @spec should_retry?(Task.t()) :: boolean()
  def should_retry?(%Task{retry_count: count, max_retries: max}) do
    count < max
  end

  @doc """
  Determines if a failure reason is retryable.

  Retryable: LLM timeout, temporary HTTP failure, tool timeout,
  worker crash without file mutation, connection errors, rate limiting.

  Non-retryable: policy violation, invalid task contract,
  repeated write conflict, tool forbidden by risk rules.
  """
  @spec retryable?(Task.t(), atom()) :: boolean()
  def retryable?(_task, reason) when reason in @retryable_reasons, do: true
  def retryable?(_task, reason) when reason in @non_retryable_reasons, do: false

  def retryable?(_task, reason) do
    # Unknown reasons default to non-retryable (conservative)
    reason not in @non_retryable_reasons
  end

  @doc """
  Full retry decision: checks both should_retry? and retryable?.
  Returns {:retry, updated_task} or {:give_up, task}.
  """
  @spec decide(Task.t(), atom()) :: {:retry, Task.t()} | {:give_up, Task.t()}
  def decide(%Task{} = task, reason) do
    if should_retry?(task) and retryable?(task, reason) do
      case Task.increment_retry(task) do
        {:ok, updated} -> {:retry, updated}
        {:error, :max_retries_exceeded} -> {:give_up, task}
      end
    else
      {:give_up, task}
    end
  end

  @doc "Lists all retryable reason atoms."
  @spec retryable_reasons() :: [atom()]
  def retryable_reasons, do: @retryable_reasons

  @doc "Lists all non-retryable reason atoms."
  @spec non_retryable_reasons() :: [atom()]
  def non_retryable_reasons, do: @non_retryable_reasons
end
