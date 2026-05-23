defmodule Spark.AgentManagerTest do
  use ExUnit.Case, async: false

  setup do
    # Reset persisted agents so each test starts from defaults
    Spark.Config.put(["agents"], %{})
    # Start AgentManager for each test
    {:ok, pid} = Spark.AgentManager.start_link(name: Spark.AgentManager)
    on_exit(fn -> 
      Process.exit(pid, :normal) 
    end)
    :ok
  end

  describe "list_agents/0" do
    test "returns planning and coding agents" do
      agents = Spark.AgentManager.list_agents()
      assert is_map_key(agents, "planning")
      assert is_map_key(agents, "coding")
    end
  end

  describe "get_agent/1" do
    test "returns planning agent with expected fields" do
      agent = Spark.AgentManager.get_agent("planning")
      assert agent != nil
      assert agent["actor_type"] == "orchestrator"
      assert agent["provider"] == "deepseek"
      assert agent["model"] == "deepseek-v4-pro"
    end

    test "returns coding agent with expected fields" do
      agent = Spark.AgentManager.get_agent("coding")
      assert agent != nil
      assert agent["actor_type"] == "worker"
      assert agent["provider"] == "wafer"
      assert agent["model"] == "glm-5.1"
    end

    test "returns nil for unknown agent" do
      assert Spark.AgentManager.get_agent("nonexistent") == nil
    end
  end

  describe "resolve_for_actor/1" do
    test "resolves :orchestrator to planning agent" do
      agent = Spark.AgentManager.resolve_for_actor(:orchestrator)
      assert agent != nil
      assert agent["provider"] == "deepseek"
    end

    test "resolves :worker to coding agent" do
      agent = Spark.AgentManager.resolve_for_actor(:worker)
      assert agent != nil
      assert agent["provider"] == "wafer"
    end

    test "returns nil for unknown actor type" do
      assert Spark.AgentManager.resolve_for_actor(:unknown) == nil
    end
  end

  describe "pin_model/2" do
    test "pins a valid model to planning agent" do
      {:ok, agent} = Spark.AgentManager.pin_model("planning", "deepseek-v4-flash")
      assert agent["model"] == "deepseek-v4-flash"
    end

    test "returns error for unknown agent" do
      assert {:error, msg} = Spark.AgentManager.pin_model("unknown", "deepseek-v4-flash")
      assert msg =~ "Unknown agent"
    end

    test "returns error for invalid model" do
      assert {:error, msg} = Spark.AgentManager.pin_model("planning", "nonexistent-model")
      assert msg =~ "Unknown model"
    end
  end
end
