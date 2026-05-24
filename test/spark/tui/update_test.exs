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
end
