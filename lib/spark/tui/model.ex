defmodule Spark.TUI.Model do
  @moduledoc """
  TUI state model for the Spark dashboard.

  Holds all runtime state for the terminal UI including navigation,
  agent configuration, plan data, and the v4.1 dashboard fields
  for view modes, canvas content, command modes, and spinner animation.

  Navigation is governed by two complementary concepts:

    view_mode:   what the user SEES (canvas content)
    command_mode: how the user INTERACTS (deck behavior)

  Overlays: some view_modes imply a command_mode (plan_review → approve).
  """

  @type view_mode :: :welcome | :plan_review | :execution | :logs | :help | :tasks | :shell_output
  @type command_mode :: :chat | :approve | :agent_picker

  @type t :: %__MODULE__{
          session_id: String.t() | nil,
          # screen and previous_screen are deprecated — use view_mode instead
          screen: atom(),
          previous_screen: atom() | nil,
          selected_index: non_neg_integer(),
          selected_agent: String.t() | nil,
          selected_model_index: non_neg_integer(),
          agents: map(),
          agent_order: [String.t()],
          dashboard: map(),
          active_plan: map() | nil,
          confirm_action: any() | nil,
          status_message: String.t() | nil,
          error_message: String.t() | nil,
          logs: [map()],
          input_buffer: String.t(),
          loading?: boolean(),
          selected_task_index: non_neg_integer(),
          scroll_top: non_neg_integer(),
          width: pos_integer(),
          height: pos_integer(),
          view_mode: view_mode(),
          canvas_content: atom(),
          scroll_offset: integer(),
          canvas_lines: [String.t()],
          command_mode: command_mode(),
          command_hint: String.t(),
          spinner_frame: non_neg_integer(),
          streaming_content: String.t(),
          task_statuses: [map()]
        }

  defstruct [
    # ── Original fields (backward compatible) ──
    :session_id,
    # DEPRECATED: screen / previous_screen — superseded by view_mode.
    # Kept for backward compatibility; all navigation uses view_mode now.
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
    selected_task_index: 0,
    scroll_top: 0,
    width: 80,
    height: 24,
    # ── v4.1 dashboard fields ──
    view_mode: :welcome,
    canvas_content: :welcome,
    scroll_offset: 0,
    canvas_lines: [],
    command_mode: :chat,
    command_hint: "",
    spinner_frame: 0,
    streaming_content: "",
    task_statuses: []
  ]
end
