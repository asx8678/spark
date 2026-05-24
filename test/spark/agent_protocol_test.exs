defmodule Spark.AgentProtocolTest do
  use ExUnit.Case, async: true

  alias Spark.AgentProtocol

  describe "register/2 and find/2" do
    test "registers the calling process and finds it by role and session_id" do
      session_id = "sess_agent_proto_#{:erlang.unique_integer([:positive])}"

      # AgentProtocol.register/2 registers the CALLING process
      :ok = AgentProtocol.register(:orchestrator, session_id)

      # find/2 should return the test process PID
      self_pid = self()
      assert {:ok, ^self_pid} = AgentProtocol.find(:orchestrator, session_id)

      # Clean up
      AgentProtocol.unregister(:orchestrator, session_id)
      assert {:error, :not_found} = AgentProtocol.find(:orchestrator, session_id)
    end

    test "find returns not_found for unknown registration" do
      assert {:error, :not_found} = AgentProtocol.find(:dispatcher, "nonexistent_session")
    end

    test "register returns error for duplicate registration" do
      session_id = "sess_dup_#{:erlang.unique_integer([:positive])}"
      :ok = AgentProtocol.register(:dispatcher, session_id)

      # Same process registering same key — Registry returns {:error, {:already_registered, pid}}
      result = AgentProtocol.register(:dispatcher, session_id)
      assert result != :ok

      # Clean up
      AgentProtocol.unregister(:dispatcher, session_id)
    end

    test "unregister removes the registration" do
      session_id = "sess_unreg_#{:erlang.unique_integer([:positive])}"
      :ok = AgentProtocol.register(:orchestrator, session_id)
      assert {:ok, _pid} = AgentProtocol.find(:orchestrator, session_id)

      :ok = AgentProtocol.unregister(:orchestrator, session_id)
      assert {:error, :not_found} = AgentProtocol.find(:orchestrator, session_id)
    end

    test "different roles under same session_id are independent" do
      session_id = "sess_multi_#{:erlang.unique_integer([:positive])}"

      :ok = AgentProtocol.register(:orchestrator, session_id)
      :ok = AgentProtocol.register(:dispatcher, session_id)

      self_pid = self()
      assert {:ok, ^self_pid} = AgentProtocol.find(:orchestrator, session_id)
      assert {:ok, ^self_pid} = AgentProtocol.find(:dispatcher, session_id)

      AgentProtocol.unregister(:orchestrator, session_id)
      AgentProtocol.unregister(:dispatcher, session_id)

      assert {:error, :not_found} = AgentProtocol.find(:orchestrator, session_id)
      assert {:error, :not_found} = AgentProtocol.find(:dispatcher, session_id)
    end
  end
end
