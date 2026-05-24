defmodule Spark.AgentProtocol do
  @moduledoc """
  Formal behaviour defining the contract between Planning Agent (Orchestrator)
  and Coding Agent (Workers/Dispatcher).

  All cross-agent interactions should eventually route through callbacks
  defined here. This module also provides concrete helper functions for
  agent registration and discovery via Spark.SessionRegistry.

  ## Protocol Flow

      Orchestrator --(TaskRequest)--> Dispatcher --(Task)--> Worker
      Worker --(Progress)--> Dispatcher --(WorkerResult)--> Orchestrator
      Worker --(cancel_task)--> Dispatcher

  For now this FORMALIZES the protocol — existing ad-hoc calls still work.
  Refactoring to use these callbacks exclusively is tracked as P2.8.
  """

  alias Spark.Types.{TaskRequest, Progress, Task, WorkerResult}

  @doc """
  Handle an incoming task request from the Orchestrator.
  Returns the accepted Task or an error.
  """
  @callback handle_task_request(TaskRequest.t()) :: {:ok, Task.t()} | {:error, term()}

  @doc """
  Report progress on an executing task.
  """
  @callback report_progress(Progress.t()) :: :ok

  @doc """
  Report task completion (success or failure) back up the chain.
  """
  @callback report_completion(WorkerResult.t()) :: :ok

  @doc """
  Cancel a running or queued task by ID.
  """
  @callback cancel_task(task_id :: String.t()) :: :ok | {:error, term()}

  # --- Concrete helper functions ---

  @doc """
  Registers the calling process in Spark.SessionRegistry under {session_id, role}.

  Role should be an atom like :orchestrator or :dispatcher.
  Enables discovery via `find/2`.
  """
  @spec register(atom(), String.t()) :: :ok | {:error, term()}
  def register(role, session_id) when is_atom(role) and is_binary(session_id) do
    case Registry.register(Spark.SessionRegistry, {session_id, role}, %{role: role}) do
      {:ok, _pid} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Removes the calling process from Spark.SessionRegistry.
  """
  @spec unregister(atom(), String.t()) :: :ok
  def unregister(role, session_id) when is_atom(role) and is_binary(session_id) do
    Registry.unregister(Spark.SessionRegistry, {session_id, role})
    :ok
  end

  @doc """
  Looks up a registered agent process by role and session_id.

  Returns `{:ok, pid}` if found, `{:error, :not_found}` otherwise.
  """
  @spec find(atom(), String.t()) :: {:ok, pid()} | {:error, :not_found}
  def find(role, session_id) when is_atom(role) and is_binary(session_id) do
    case Registry.lookup(Spark.SessionRegistry, {session_id, role}) do
      [{pid, _value}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end
end
