defmodule Spark.TUI.Model do
  @moduledoc "TUI state model."

  defstruct [
    :session_id,
    screen: :home,
    previous_screen: nil,
    selected_index: 0,
    selected_agent: nil,
    selected_model_index: 0,
    agents: %{},
    agent_order: ["planning", "coding"],
    dashboard: %{},
    active_plan: nil,
    confirm_action: nil,
    status_message: nil,
    error_message: nil,
    logs: [],
    input_buffer: "",
    loading?: false,
    selected_task_index: 0
  ]
end
