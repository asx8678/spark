defmodule Spark.Events do
  @moduledoc """
  Semantic event name constants for the Spark EventBus.

  Use these atoms instead of raw atoms to ensure consistent naming
  across the system. Each macro expands to a stable atom.
  """

  # Session
  defmacro session_started, do: :session_started
  defmacro user_input_received, do: :user_input_received

  # Plan
  defmacro plan_created, do: :plan_created
  defmacro plan_awaiting_approval, do: :plan_awaiting_approval
  defmacro plan_approved, do: :plan_approved
  defmacro plan_rejected, do: :plan_rejected

  # Task
  defmacro task_queued, do: :task_queued
  defmacro task_started, do: :task_started
  defmacro task_completed, do: :task_completed
  defmacro task_failed, do: :task_failed
  defmacro task_retried, do: :task_retried

  # Worker
  defmacro worker_started, do: :worker_started
  defmacro worker_stopped, do: :worker_stopped

  # Tool
  defmacro tool_started, do: :tool_started
  defmacro tool_completed, do: :tool_completed
  defmacro tool_failed, do: :tool_failed

  # Orchestrator
  defmacro orchestrator_review_started, do: :orchestrator_review_started
  defmacro orchestrator_review_completed, do: :orchestrator_review_completed

  # Memory
  defmacro memory_written, do: :memory_written

  # Hot Reload
  defmacro hot_reload_started, do: :hot_reload_started
  defmacro hot_reload_completed, do: :hot_reload_completed
  defmacro hot_reload_failed, do: :hot_reload_failed
  defmacro config_reloaded, do: :config_reloaded
  defmacro prompt_reloaded, do: :prompt_reloaded
  defmacro tool_reloaded, do: :tool_reloaded
  defmacro policy_reloaded, do: :policy_reloaded
  defmacro code_reloaded, do: :code_reloaded

  @doc """
  Lists all defined event type atoms.
  """
  @spec all() :: [atom()]
  def all do
    [
      session_started(), user_input_received(),
      plan_created(), plan_awaiting_approval(), plan_approved(), plan_rejected(),
      task_queued(), task_started(), task_completed(), task_failed(), task_retried(),
      worker_started(), worker_stopped(),
      tool_started(), tool_completed(), tool_failed(),
      orchestrator_review_started(), orchestrator_review_completed(),
      memory_written(),
      hot_reload_started(), hot_reload_completed(), hot_reload_failed(),
      config_reloaded(), prompt_reloaded(), tool_reloaded(),
      policy_reloaded(), code_reloaded()
    ]
  end

  @doc """
  Checks if an atom is a known event type.
  """
  @spec known?(atom()) :: boolean()
  def known?(type) when is_atom(type) do
    type in all()
  end
end
