defmodule Spark.TUI.UpdateTest do
  use ExUnit.Case, async: true

  alias Spark.TUI.Model
  alias Spark.TUI.Update

  setup do
    model = %Model{
      session_id: "test_session",
      width: 80,
      height: 24,
      view_mode: :welcome,
      command_mode: :chat,
      scroll_top: 0,
      selected_task_index: 0,
      scroll_offset: 0,
      agents: %{
        "planning" => %{
          "actor_type" => "orchestrator",
          "provider" => "deepseek",
          "model" => "deepseek-v4-pro"
        },
        "coding" => %{"actor_type" => "worker", "provider" => "wafer", "model" => "glm-5.1"}
      }
    }

    {:ok, model: model}
  end

  describe "streaming lifecycle" do
    test "stream_started sets streaming_active? to true" do
      model = %Model{session_id: "test", loading?: false, streaming_active?: false}
      updated = Update.update(model, {:stream_started, %{goal: "test"}})
      assert updated.streaming_active? == true
    end

    test "stream_chunk appends to streaming_content and planning_transcript" do
      model = %Model{session_id: "test", streaming_content: "", planning_transcript: "", streaming_active?: true}
      updated = Update.update(model, {:stream_chunk, "hello "})
      assert updated.streaming_content == "hello "
      assert updated.planning_transcript == "hello "

      updated2 = Update.update(updated, {:stream_chunk, "world"})
      assert updated2.streaming_content == "hello world"
      assert updated2.planning_transcript == "hello world"
    end

    test "stream_chunk with map-type chunk (%{type: :reasoning, text: text})" do
      model = %Model{session_id: "test", streaming_content: "", planning_transcript: "", streaming_active?: true}
      updated = Update.update(model, {:stream_chunk, %{type: :reasoning, text: "thinking..."}})
      assert updated.streaming_content == "thinking..."
      assert updated.planning_transcript == "thinking..."
    end

    test "stream_chunk with map-type chunk (%{text: text})" do
      model = %Model{session_id: "test", streaming_content: "", planning_transcript: "", streaming_active?: true}
      updated = Update.update(model, {:stream_chunk, %{text: "some text"}})
      assert updated.streaming_content == "some text"
      assert updated.planning_transcript == "some text"
    end

    test "multiple stream chunks concatenate correctly in both fields" do
      model = %Model{session_id: "test", streaming_content: "", planning_transcript: "", streaming_active?: true}

      model = Update.update(model, {:stream_chunk, "line1\n"})
      model = Update.update(model, {:stream_chunk, "line2\n"})
      model = Update.update(model, {:stream_chunk, "line3"})

      assert model.streaming_content == "line1\nline2\nline3"
      assert model.planning_transcript == "line1\nline2\nline3"
    end

    test "stream_done is a no-op (plan_result handles cleanup)" do
      model = %Model{
        session_id: "test",
        streaming_active?: true,
        streaming_content: "some content",
        planning_transcript: "some content",
        loading?: true
      }

      updated = Update.update(model, {:stream_done, %{}})
      # stream_done doesn't change anything; plan_result will handle the transition
      assert updated.streaming_active? == true
      assert updated.streaming_content == "some content"
      assert updated.planning_transcript == "some content"
      assert updated.loading? == true
    end

    test "stream_error resets streaming state but preserves planning_transcript" do
      model = %Model{
        session_id: "test",
        streaming_active?: true,
        streaming_content: "partial content",
        planning_transcript: "partial content",
        loading?: true
      }

      updated = Update.update(model, {:stream_error, :connection_lost})
      assert updated.streaming_active? == false
      assert updated.loading? == false
      assert updated.streaming_content == ""
      assert updated.planning_transcript == "partial content"
      assert updated.error_message =~ "connection_lost"
    end

    test "plan_result success clears streaming_active? and streaming_content, preserves planning_transcript" do
      plan = %{
        id: "plan_1",
        user_goal: "test",
        approval_status: :awaiting_approval,
        summary: "test plan",
        tasks: []
      }

      model = %Model{
        session_id: "test",
        loading?: true,
        streaming_active?: true,
        streaming_content: "streaming data",
        planning_transcript: "streaming data"
      }

      updated = Update.update(model, {:plan_result, {:ok, plan}})
      assert updated.streaming_active? == false
      assert updated.streaming_content == ""
      assert updated.loading? == false
      assert updated.active_plan.id == "plan_1"
      assert updated.planning_transcript == "streaming data"
    end

    test "plan_result success stays in :planning_session view_mode with :approve command_mode" do
      plan = %{
        id: "plan_1",
        user_goal: "test",
        approval_status: :awaiting_approval,
        summary: "test plan",
        tasks: []
      }

      model = %Model{
        session_id: "test",
        loading?: true,
        streaming_active?: true,
        streaming_content: "some output",
        planning_transcript: "some output",
        view_mode: :planning_session
      }

      updated = Update.update(model, {:plan_result, {:ok, plan}})
      assert updated.view_mode == :planning_session
      assert updated.command_mode == :approve
      assert updated.planning_transcript == "some output"
      assert updated.status_message =~ "Plan ready"
    end

    test "plan_result success copies streaming_content to transcript when transcript is empty" do
      plan = %{
        id: "plan_1",
        user_goal: "test",
        approval_status: :awaiting_approval,
        summary: "test plan",
        tasks: []
      }

      model = %Model{
        session_id: "test",
        loading?: true,
        streaming_active?: true,
        streaming_content: "model output here",
        planning_transcript: "",
        view_mode: :planning_session
      }

      updated = Update.update(model, {:plan_result, {:ok, plan}})
      assert updated.planning_transcript == "model output here"
    end

    test "plan_result error stays in :planning_session and preserves transcript" do
      model = %Model{
        session_id: "test",
        loading?: true,
        streaming_active?: true,
        streaming_content: "partial",
        planning_transcript: "partial output for debug",
        view_mode: :planning_session
      }

      updated = Update.update(model, {:plan_result, {:error, :timeout}})
      assert updated.streaming_active? == false
      assert updated.streaming_content == ""
      assert updated.loading? == false
      assert updated.view_mode == :planning_session
      assert updated.planning_transcript == "partial output for debug"
      assert updated.error_message =~ "timeout"
    end

    test "Enter key in chat starts :planning_session and clears previous transcript" do
      model = %Model{
        session_id: "test",
        command_mode: :chat,
        loading?: false,
        input_buffer: "Build an app",
        streaming_active?: false,
        planning_transcript: "old transcript",
        view_mode: :welcome
      }

      result = Update.update(model, {:event, %{key: 0x0D}})

      {updated_model, _cmd} = result
      assert updated_model.streaming_active? == true
      assert updated_model.loading? == true
      assert updated_model.streaming_content == ""
      assert updated_model.planning_transcript == ""
      assert updated_model.view_mode == :planning_session
      assert updated_model.status_message == "Planning..."
    end

    test "Esc while loading clears streaming_active? and planning_transcript" do
      model = %Model{
        session_id: "test",
        command_mode: :chat,
        loading?: true,
        streaming_active?: true,
        streaming_content: "partial",
        planning_transcript: "partial"
      }

      updated = Update.update(model, {:event, %{key: 0x1B}})
      assert updated.streaming_active? == false
      assert updated.loading? == false
      assert updated.streaming_content == ""
      assert updated.planning_transcript == ""
    end
  end

  describe "global scrolling" do
    test "increases scroll_top on positive scroll diff", %{model: model} do
      updated = Update.update(model, {:scroll, 3})
      assert updated.scroll_top == 3

      updated_further = Update.update(updated, {:scroll, 5})
      assert updated_further.scroll_top == 8
    end

    test "decreases scroll_top but bounds at 0", %{model: model} do
      model = %{model | scroll_top: 5}
      updated = Update.update(model, {:scroll, -2})
      assert updated.scroll_top == 3

      updated_bounded = Update.update(updated, {:scroll, -10})
      assert updated_bounded.scroll_top == 0
    end
  end

  describe "slash command navigation resets scroll_top" do
    test "resets scroll_top to 0 on /welcome", %{model: model} do
      # Mock buffer containing "/welcome"
      model_with_buf = %{model | input_buffer: "/welcome", scroll_top: 10, view_mode: :logs}
      updated = Update.update(model_with_buf, {:event, %{key: 0x0D}})
      assert updated.view_mode == :welcome
      assert updated.scroll_top == 0
    end

    test "resets scroll_top to 0 on /exec", %{model: model} do
      model_with_buf = %{model | input_buffer: "/exec", scroll_top: 10}
      updated = Update.update(model_with_buf, {:event, %{key: 0x0D}})
      assert updated.view_mode == :execution
      assert updated.scroll_top == 0
    end
  end

  describe "approve mode task navigation" do
    setup %{model: model} do
      plan = %{
        id: "plan_test",
        user_goal: "test goal",
        approval_status: :awaiting_approval,
        summary: "test plan summary",
        tasks: [
          %{
            id: "task_1",
            title: "Task 1",
            risk: :low,
            depends_on: [],
            read_paths: [],
            write_paths: []
          },
          %{
            id: "task_2",
            title: "Task 2",
            risk: :medium,
            depends_on: ["task_1"],
            read_paths: [],
            write_paths: []
          },
          %{
            id: "task_3",
            title: "Task 3",
            risk: :high,
            depends_on: ["task_2"],
            read_paths: [],
            write_paths: []
          }
        ]
      }

      model_in_approve = %{
        model
        | command_mode: :approve,
          view_mode: :plan_review,
          active_plan: plan,
          selected_task_index: 0
      }

      {:ok, model: model_in_approve}
    end

    test "arrow down moves selected_task_index forward", %{model: model} do
      # Arrow down is 0xFFFF - 19
      updated = Update.update(model, {:event, %{key: 0xFFFF - 19}})
      assert updated.selected_task_index == 1

      updated_further = Update.update(updated, {:event, %{key: 0xFFFF - 19}})
      assert updated_further.selected_task_index == 2

      # Clamped to tasks list length
      updated_clamped = Update.update(updated_further, {:event, %{key: 0xFFFF - 19}})
      assert updated_clamped.selected_task_index == 2
    end

    test "arrow up moves selected_task_index backward", %{model: model} do
      model = %{model | selected_task_index: 2}
      # Arrow up is 0xFFFF - 18
      updated = Update.update(model, {:event, %{key: 0xFFFF - 18}})
      assert updated.selected_task_index == 1

      updated_further = Update.update(updated, {:event, %{key: 0xFFFF - 18}})
      assert updated_further.selected_task_index == 0

      # Bounded at 0
      updated_bounded = Update.update(updated_further, {:event, %{key: 0xFFFF - 18}})
      assert updated_bounded.selected_task_index == 0
    end

    test "Vim 'j' and 'k' move selected_task_index forward and backward", %{model: model} do
      # 'j' moves forward
      updated = Update.update(model, {:event, %{ch: ?j}})
      assert updated.selected_task_index == 1

      # 'k' moves backward
      updated_back = Update.update(updated, {:event, %{ch: ?k}})
      assert updated_back.selected_task_index == 0
    end
  end

  describe "agent_picker navigation and flow" do
    setup %{model: model} do
      model_in_picker = %{
        model
        | command_mode: :agent_picker,
          selected_agent: nil,
          selected_index: 0,
          selected_model_index: 0
      }

      {:ok, model: model_in_picker}
    end

    test "cycles between agents when selected_agent is nil", %{model: model} do
      # Arrow down moves to coding agent (index 1)
      updated = Update.update(model, {:event, %{key: 0xFFFF - 19}})
      assert updated.selected_index == 1

      # Arrow down wraps back to planning agent (index 0) since length is 2
      updated_wrap = Update.update(updated, {:event, %{key: 0xFFFF - 19}})
      assert updated_wrap.selected_index == 0

      # Arrow up wraps to coding agent (index 1)
      updated_up = Update.update(updated_wrap, {:event, %{key: 0xFFFF - 18}})
      assert updated_up.selected_index == 1
    end

    test "Vim keys cycle between agents", %{model: model} do
      # 'j' moves forward
      updated = Update.update(model, {:event, %{ch: ?j}})
      assert updated.selected_index == 1

      # 'k' moves backward
      updated_back = Update.update(updated, {:event, %{ch: ?k}})
      assert updated_back.selected_index == 0
    end

    test "Enter key locks in selected_agent selection", %{model: model} do
      # Select coding agent (index 1) and press enter
      model = %{model | selected_index: 1}
      updated = Update.update(model, {:event, %{key: 0x0D}})

      assert updated.selected_agent == "coding"
      assert updated.selected_model_index == 0
      assert updated.command_mode == :agent_picker
    end

    test "cycles between models when selected_agent is active", %{model: model} do
      # Pre-select planning agent (provider deepseek has 3 models)
      model = %{model | selected_agent: "planning", selected_model_index: 0}

      # Arrow down moves to next model (index 1)
      updated = Update.update(model, {:event, %{key: 0xFFFF - 19}})
      assert updated.selected_model_index == 1

      # Arrow down again (index 2)
      updated_2 = Update.update(updated, {:event, %{key: 0xFFFF - 19}})
      assert updated_2.selected_model_index == 2

      # Arrow down wraps to index 0 (total 3 models)
      updated_wrap = Update.update(updated_2, {:event, %{key: 0xFFFF - 19}})
      assert updated_wrap.selected_model_index == 0
    end

    test "Esc key backs out to agent selection or chat deck", %{model: model} do
      # Case 1: selected_agent is active -> goes back to agent selection (nil)
      model_with_agent = %{model | selected_agent: "planning"}
      # Esc
      updated = Update.update(model_with_agent, {:event, %{key: 0x1B}})
      assert updated.selected_agent == nil
      assert updated.command_mode == :agent_picker

      # Case 2: selected_agent is nil -> exits to chat mode
      # Esc
      updated_chat = Update.update(updated, {:event, %{key: 0x1B}})
      assert updated_chat.command_mode == :chat
    end

    test "Enter key on model selection pins model and dispatches pin_result", %{model: model} do
      # Pre-select coding (provider wafer, GLM 5.1 is index 0)
      model = %{model | selected_agent: "coding", selected_model_index: 0}

      # Press enter
      assert {updated_model, cmd} = Update.update(model, {:event, %{key: 0x0D}})
      assert updated_model.loading?
      assert updated_model.status_message =~ "Pinning"
      assert cmd.message == :pin_result
      assert is_function(cmd.function)
    end
  end

  describe "/plan slash command" do
    test "/plan returns to :planning_session when planning_transcript exists" do
      plan = %{
        id: "plan_1",
        user_goal: "test",
        approval_status: :awaiting_approval,
        summary: "test plan",
        tasks: []
      }

      model = %Model{
        session_id: "test",
        active_plan: plan,
        planning_transcript: "some transcript",
        view_mode: :welcome,
        command_mode: :chat,
        input_buffer: "/plan"
      }

      updated = Update.update(model, {:event, %{key: 0x0D}})
      assert updated.view_mode == :planning_session
      assert updated.command_mode == :approve
    end

    test "/plan returns to :planning_session when active_plan exists" do
      plan = %{
        id: "plan_1",
        user_goal: "test",
        approval_status: :awaiting_approval,
        summary: "test plan",
        tasks: []
      }

      model = %Model{
        session_id: "test",
        active_plan: plan,
        planning_transcript: "",
        view_mode: :welcome,
        command_mode: :chat,
        input_buffer: "/plan"
      }

      updated = Update.update(model, {:event, %{key: 0x0D}})
      assert updated.view_mode == :planning_session
      assert updated.command_mode == :approve
    end

    test "/plan shows error when no active plan" do
      model = %Model{
        session_id: "test",
        active_plan: nil,
        command_mode: :chat,
        input_buffer: "/plan"
      }

      updated = Update.update(model, {:event, %{key: 0x0D}})
      assert updated.error_message =~ "No active plan"
    end
  end
end
