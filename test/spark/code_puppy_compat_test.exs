defmodule Spark.CodePuppyCompatTest do
  use ExUnit.Case, async: false

  alias Spark.CodePuppyCompat
  alias Spark.EventBus

  setup do
    EventBus.clear_hooks()

    on_exit(fn ->
      EventBus.clear_hooks()
    end)

    :ok
  end

  # ─── Prompt Tests ───────────────────────────────────────────────────

  describe "orchestrator_prompt/0" do
    test "contains ZERO-FRICTION INITIALIZATION" do
      prompt = CodePuppyCompat.orchestrator_prompt()
      assert prompt =~ "ZERO-FRICTION INITIALIZATION"
    end

    test "contains THINK pipeline directive" do
      prompt = CodePuppyCompat.orchestrator_prompt()
      assert prompt =~ "THINK"
      assert prompt =~ "PLAN"
      assert prompt =~ "Approval Gate"
    end

    test "contains handoff phrase via handoff_phrase/0" do
      prompt = CodePuppyCompat.orchestrator_prompt()
      # The handoff phrase is no longer in the prompt text — it's in handoff_phrase/0
      assert CodePuppyCompat.handoff_phrase() == "Handing off to Coding Agent..."
      # But the prompt still references the approval gate
      assert prompt =~ "approve"
    end

    test "contains approval gate phrase" do
      prompt = CodePuppyCompat.orchestrator_prompt()
      assert prompt =~ "Does this plan look good to you?"
    end

    test "contains JSON schema requirements" do
      prompt = CodePuppyCompat.orchestrator_prompt()
      assert prompt =~ "user_goal"
      assert prompt =~ "summary"
      assert prompt =~ "tasks"
    end

    test "contains Orchestrator identity" do
      prompt = CodePuppyCompat.orchestrator_prompt()
      assert prompt =~ "Orchestrator"
    end
  end

  describe "worker_prompt/0" do
    test "worker prompt encourages tool usage" do
      prompt = CodePuppyCompat.worker_prompt()
      assert prompt =~ "Use tools to get things done"
    end

    test "worker prompt contains explore-before-modify directive" do
      prompt = CodePuppyCompat.worker_prompt()
      assert prompt =~ "Explore directories before modifying"
    end

    test "worker prompt contains read-before-modify directive" do
      prompt = CodePuppyCompat.worker_prompt()
      assert prompt =~ "Read existing files before editing"
    end

    test "worker prompt contains targeted edits preference" do
      prompt = CodePuppyCompat.worker_prompt()
      assert prompt =~ "replace_in_file"
    end

    test "worker prompt contains DRY/YAGNI/SOLID principles" do
      prompt = CodePuppyCompat.worker_prompt()
      assert prompt =~ "DRY"
      assert prompt =~ "YAGNI"
      assert prompt =~ "SOLID"
    end

    test "worker prompt encourages autonomous work" do
      prompt = CodePuppyCompat.worker_prompt()
      assert prompt =~ "autonomously"
    end
  end

  describe "handoff_phrase/0" do
    test "returns exact handoff phrase" do
      assert CodePuppyCompat.handoff_phrase() == "Handing off to Coding Agent..."
    end
  end

  # ─── Telemetry Tests ────────────────────────────────────────────────

  describe "publish_state_transition/4" do
    test "publishes :state_transition event" do
      EventBus.add_hook(:test_collector, fn event -> send(self(), {:event, event}) end)

      CodePuppyCompat.publish_state_transition(:planning, :executing, %{session_id: "test"}, "approved")

      assert_receive {:event, %{type: :state_transition, payload: %{message: msg}}}
      assert msg =~ "PLANNING"
      assert msg =~ "EXECUTING"
      assert msg =~ "approved"
    end

    test "is crash-proof with nil context" do
      # Should not raise
      CodePuppyCompat.publish_state_transition(:planning, :executing, nil, "test")
    end
  end

  describe "publish_reasoning/3" do
    test "publishes :agent_reasoning event" do
      EventBus.add_hook(:test_collector, fn event -> send(self(), {:event, event}) end)

      CodePuppyCompat.publish_reasoning(:thinking, "Analyzing codebase", %{session_id: "test"})

      assert_receive {:event, %{type: :agent_reasoning, payload: %{stage: :thinking, message: msg}}}
      assert msg =~ "Analyzing codebase"
    end
  end

  describe "publish_tool_preflight/4" do
    test "publishes :tool_preflight and :agent_reasoning events" do
      EventBus.add_hook(:test_collector, fn event -> send(self(), {:event, event}) end)

      CodePuppyCompat.publish_tool_preflight("read_file", %{path: "/foo"}, %{session_id: "test"}, "Read a file")

      assert_receive {:event, %{type: :tool_preflight, payload: %{tool: "read_file"}}}
      assert_receive {:event, %{type: :agent_reasoning, payload: %{stage: :tool_preflight}}}
    end

    test "includes reason in message" do
      EventBus.add_hook(:test_collector, fn event -> send(self(), {:event, event}) end)

      CodePuppyCompat.publish_tool_preflight("read_file", %{}, %{}, "")

      assert_receive {:event, %{type: :tool_preflight, payload: %{message: msg}}}
      assert msg =~ "understand the current content"
    end
  end

  describe "publish_tool_summary/3" do
    test "publishes :tool_result_summary for success" do
      EventBus.add_hook(:test_collector, fn event -> send(self(), {:event, event}) end)

      CodePuppyCompat.publish_tool_summary("read_file", {:ok, %{status: :ok, result: "data"}}, %{session_id: "test"})

      assert_receive {:event, %{type: :tool_result_summary, payload: %{status: "success"}}}
    end

    test "publishes :tool_result_summary for timeout" do
      EventBus.add_hook(:test_collector, fn event -> send(self(), {:event, event}) end)

      CodePuppyCompat.publish_tool_summary("bash", {:error, %{status: :timeout}}, %{})

      assert_receive {:event, %{type: :tool_result_summary, payload: %{status: "timeout"}}}
    end

    test "publishes :tool_result_summary for crash" do
      EventBus.add_hook(:test_collector, fn event -> send(self(), {:event, event}) end)

      CodePuppyCompat.publish_tool_summary("bash", {:error, %{status: :crashed}}, %{})

      assert_receive {:event, %{type: :tool_result_summary, payload: %{status: "crashed"}}}
    end

    test "redacts secrets from string values" do
      EventBus.add_hook(:test_collector, fn event -> send(self(), {:event, event}) end)

      # Use a string key that matches the secret pattern in values
      CodePuppyCompat.publish_tool_preflight("bash", %{"config" => "api_key=sk-super-secret-key-12345"}, %{}, "Run command")

      assert_receive {:event, %{type: :tool_preflight, payload: %{args_preview: args_preview}}}
      # The secret value should be redacted in the args_preview
      inspected = inspect(args_preview)
      refute inspected =~ "sk-super-secret-key-12345"
    end
  end
end
