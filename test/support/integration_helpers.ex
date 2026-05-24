defmodule Spark.Integration.TestHelpers do
  @moduledoc """
  Shared helpers for integration tests to manage Application tree processes.

  Cross-test contamination can kill Application supervisor tree processes.
  These helpers ensure critical processes are alive before each test.
  """

  def ensure_app_tree do
    ensure_pubsub()

    for {name, start_fn} <- app_tree_processes() do
      unless Process.whereis(name) do
        case start_fn.() do
          {:ok, _} -> :ok
          {:error, {:already_started, _}} -> :ok
        end
      end
    end
  end

  defp app_tree_processes do
    [
      {Spark.WorkerSupervisor,
       fn ->
         DynamicSupervisor.start_link(
           name: Spark.WorkerSupervisor,
           strategy: :one_for_one,
           max_restarts: 100,
           max_seconds: 5
         )
       end},
      {Spark.ToolSupervisor,
       fn ->
         Elixir.Task.Supervisor.start_link(name: Spark.ToolSupervisor)
       end},
      {Spark.ToolRegistry,
       fn ->
         Spark.ToolRegistry.start_link([])
       end},
      {Spark.Guidance,
       fn ->
         Spark.Guidance.start_link([])
       end},
      {Spark.Workspace.LockManager,
       fn ->
         Spark.Workspace.LockManager.start_link([])
       end}
    ]
  end

  def ensure_pubsub do
    pid = Process.whereis(Spark.PubSub)

    cond do
      pid != nil and Process.alive?(pid) ->
        # PubSub is alive and well
        :ok

      true ->
        # PubSub is dead or missing. Start a standalone one.
        # Do NOT kill the Application supervisor's PubSub — that cascades!
        {:ok, _} =
          Supervisor.start_link(
            [{Phoenix.PubSub, name: Spark.PubSub}],
            strategy: :one_for_one
          )

        :ok
    end
  end
end
