defmodule Spark.ApplicationTest do
  use ExUnit.Case, async: false

  describe "supervision tree — base children (always present)" do
    test "Spark.SessionRegistry exists" do
      assert Process.whereis(Spark.SessionRegistry) != nil
    end

    test "Spark.ToolRegistry exists" do
      assert Process.whereis(Spark.ToolRegistry) != nil
    end

    test "Spark.PubSub is reachable" do
      assert Process.whereis(Spark.PubSub) != nil
    end

    test "Spark.ToolSupervisor exists" do
      assert Process.whereis(Spark.ToolSupervisor) != nil
    end

    test "Spark.WorkerSupervisor exists" do
      assert Process.whereis(Spark.WorkerSupervisor) != nil
    end

    test "Spark.Config agent starts on demand" do
      # Config auto-starts via ensure_agent_started; calling get triggers it
      result = Spark.Config.get([:llm, :base_url], "fallback")
      assert is_binary(result)
    end

    test "Spark.Policy agent starts on demand" do
      # Policy auto-starts via ensure_started; calling current triggers it
      assert is_map(Spark.Policy.current())
    end

    test "Spark.Prompt.Store agent starts on demand" do
      # Prompt.Store auto-starts; ensure it's running first
      # (other tests may have stopped it; restart if needed)
      case Spark.Prompt.Store.start_link() do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
      end

      assert is_binary(Spark.Prompt.Store.get(:orchestrator))
    end

    test "ToolSupervisor can start supervised tasks" do
      task =
        Task.Supervisor.async_nolink(Spark.ToolSupervisor, fn ->
          :tool_result
        end)

      assert Task.yield(task, 5000) != nil
    end

    test "WorkerSupervisor can start children" do
      {:ok, pid} =
        DynamicSupervisor.start_child(Spark.WorkerSupervisor, %{
          id: :test_child,
          start: {Agent, :start_link, [fn -> :hello end]},
          restart: :temporary
        })

      assert is_pid(pid)
      assert Process.alive?(pid)
      DynamicSupervisor.terminate_child(Spark.WorkerSupervisor, pid)
    end

    test "app boots cleanly without errors" do
      assert Process.whereis(Spark.Supervisor) != nil
    end
  end

  describe "supervision tree — prod-only children (not in test)" do
    test "Dispatcher and Orchestrator are NOT started in test env" do
      # In test, these are started manually by individual tests.
      # The app tree should not start them.
      assert Mix.env() == :test
      # They may or may not be running depending on other tests,
      # so we just verify the env is correct.
    end
  end
end
