defmodule Spark.TUI.Update do
  @moduledoc "TUI message handler / update logic."

  alias Spark.TUI.{Actions, Model}

  @esc 0x1B
  @enter 0x0D
  @arrow_up 0xFFFF - 18
  @arrow_down 0xFFFF - 19
  @backspace 0x08
  @backspace2 0x7F

  @doc """
  Handles a single message and returns the updated model.

  Ratatouille's runtime intercepts q/Q/ctrl-c as quit events *before*
  calling update/2, so those never reach us. They're listed in help
  text but don't need explicit handling here.
  """

  def update(%Model{} = model, msg), do: handle(model, msg)

  # --- Command result handlers ---

  defp handle(model, {:plan_result, {:ok, plan}}) do
    %{model | loading?: false, active_plan: plan, screen: :plan_review,
      selected_task_index: 0, status_message: "Plan ready", error_message: nil}
  end

  defp handle(model, {:plan_result, {:error, reason}}) do
    %{model | loading?: false, error_message: "Planning failed: #{format_reason(reason)}",
      status_message: nil}
  end

  defp handle(model, {:approve_result, {:ok, _plan}}) do
    model = refresh_runtime(model)
    %{model | screen: :dashboard, previous_screen: :plan_review,
      status_message: "Plan approved. Execution starting...", error_message: nil}
  end

  defp handle(model, {:approve_result, {:error, reason}}) do
    %{model | error_message: "Approval failed: #{format_reason(reason)}", status_message: nil}
  end

  defp handle(model, {:reject_result, {:ok, _plan}}) do
    %{model | screen: :home, previous_screen: :plan_review,
      active_plan: nil, status_message: "Plan rejected", error_message: nil}
  end

  defp handle(model, {:reject_result, {:error, reason}}) do
    %{model | error_message: "Rejection failed: #{format_reason(reason)}", status_message: nil}
  end

  # --- Plan Input screen handlers ---

  defp handle(%{screen: :plan_input} = model, {:event, %{key: @esc}}) do
    %{model | screen: :home, previous_screen: :plan_input,
      loading?: false, input_buffer: "", status_message: nil, error_message: nil}
  end

  # Printable characters in plan_input
  defp handle(%{screen: :plan_input, loading?: false} = model, {:event, %{ch: ch}})
       when is_integer(ch) and ch >= 32 do
    %{model | input_buffer: model.input_buffer <> <<ch::utf8>>}
  end

  # Backspace in plan_input
  defp handle(%{screen: :plan_input, loading?: false} = model, {:event, %{key: @backspace}}) do
    %{model | input_buffer: trim_last(model.input_buffer)}
  end

  defp handle(%{screen: :plan_input, loading?: false} = model, {:event, %{key: @backspace2}}) do
    %{model | input_buffer: trim_last(model.input_buffer)}
  end

  # Enter in plan_input — submit goal
  defp handle(%{screen: :plan_input, loading?: false} = model, {:event, %{key: @enter}}) do
    goal = String.trim(model.input_buffer)

    if goal == "" do
      %{model | error_message: "Please enter a goal", status_message: nil}
    else
      cmd = %{function: fn -> Actions.start_plan(goal) end, message: :plan_result}
      model = %{model | loading?: true, status_message: "Planning with DeepSeek...", error_message: nil}
      {model, cmd}
    end
  end

  # Allow Escape to cancel while loading, ignore other keys
  defp handle(%{screen: :plan_input, loading?: true} = model, {:event, %{key: @esc}}) do
    %{model | screen: :home, loading?: false, input_buffer: "", status_message: "Plan cancelled", error_message: nil}
  end
  defp handle(%{screen: :plan_input, loading?: true} = model, _msg), do: model

  # --- Plan Review screen handlers (before global navigation) ---

  defp handle(%{screen: :plan_review} = model, {:event, %{key: @esc}}) do
    %{model | screen: :home, previous_screen: :plan_review, status_message: nil, error_message: nil}
  end

  defp handle(%{screen: :plan_review} = model, {:event, %{ch: ?j}}) do
    %{model | selected_task_index: min(model.selected_task_index + 1, max(task_count(model) - 1, 0))}
  end

  defp handle(%{screen: :plan_review} = model, {:event, %{ch: ?k}}) do
    %{model | selected_task_index: max(model.selected_task_index - 1, 0)}
  end

  defp handle(%{screen: :plan_review} = model, {:event, %{ch: ?J}}) do
    %{model | selected_task_index: min(model.selected_task_index + 1, max(task_count(model) - 1, 0))}
  end

  defp handle(%{screen: :plan_review} = model, {:event, %{ch: ?K}}) do
    %{model | selected_task_index: max(model.selected_task_index - 1, 0)}
  end

  defp handle(%{screen: :plan_review} = model, {:event, %{key: @arrow_up}}) do
    %{model | selected_task_index: max(model.selected_task_index - 1, 0)}
  end

  defp handle(%{screen: :plan_review} = model, {:event, %{key: @arrow_down}}) do
    %{model | selected_task_index: min(model.selected_task_index + 1, max(task_count(model) - 1, 0))}
  end

  # Approve plan
  defp handle(%{screen: :plan_review} = model, {:event, %{ch: ?a}}), do: do_approve(model)
  defp handle(%{screen: :plan_review} = model, {:event, %{ch: ?A}}), do: do_approve(model)

  # Enter to approve plan
  defp handle(%{screen: :plan_review} = model, {:event, %{key: @enter}}), do: do_approve(model)

  # Reject plan
  defp handle(%{screen: :plan_review} = model, {:event, %{ch: ?r}}), do: do_reject(model)
  defp handle(%{screen: :plan_review} = model, {:event, %{ch: ?R}}), do: do_reject(model)

  # --- Global/Home navigation (printable chars use `ch`, not `key`) ---
  # These must come AFTER screen-specific handlers to avoid overriding
  # p/P in agent_manager or plan_input/plan_review screens.

  defp handle(model, {:event, %{ch: ?a}}), do: open_agent_manager(model)
  defp handle(model, {:event, %{ch: ?A}}), do: open_agent_manager(model)

  defp handle(model, {:event, %{ch: ?d}}), do: open_dashboard(model)
  defp handle(model, {:event, %{ch: ?D}}), do: open_dashboard(model)

  defp handle(model, {:event, %{ch: ?l}}), do: open_logs(model)
  defp handle(model, {:event, %{ch: ?L}}), do: open_logs(model)

  defp handle(model, {:event, %{ch: ?r}}), do: refresh_current(model)
  defp handle(model, {:event, %{ch: ?R}}), do: refresh_current(model)

  defp handle(model, {:event, %{ch: ?h}}), do: %{model | screen: :home, previous_screen: model.screen}
  defp handle(model, {:event, %{ch: ?H}}), do: %{model | screen: :home, previous_screen: model.screen}

  # P/p: open plan_input from home/dashboard/logs (not agent_manager)
  defp handle(%{screen: screen} = model, {:event, %{ch: ?p}})
       when screen in [:home, :dashboard, :logs] do
    %{model | screen: :plan_input, previous_screen: model.screen,
      input_buffer: "", loading?: false, status_message: nil, error_message: nil}
  end

  defp handle(%{screen: screen} = model, {:event, %{ch: ?P}})
       when screen in [:home, :dashboard, :logs] do
    %{model | screen: :plan_input, previous_screen: model.screen,
      input_buffer: "", loading?: false, status_message: nil, error_message: nil}
  end

  # ?/? opens help screen
  defp handle(model, {:event, %{ch: ??}}), do: %{model | screen: :help, previous_screen: model.screen}

  # Escape — context-aware back navigation
  defp handle(%{screen: :help} = model, {:event, %{key: @esc}}), do: %{model | screen: model.previous_screen || :home, previous_screen: :help}

  defp handle(%{screen: :model_picker} = model, {:event, %{key: @esc}}) do
    %{model | screen: :agent_manager, previous_screen: :model_picker,
      status_message: nil, error_message: nil}
  end

  defp handle(model, {:event, %{key: @esc}}), do: %{model | screen: :home, previous_screen: model.screen}

  # --- Agent Manager screen handlers ---

  defp handle(%{screen: :agent_manager} = model, {:event, %{ch: ?p}}) do
    open_model_picker(model, "planning")
  end

  defp handle(%{screen: :agent_manager} = model, {:event, %{ch: ?P}}) do
    open_model_picker(model, "planning")
  end

  defp handle(%{screen: :agent_manager} = model, {:event, %{ch: ?c}}) do
    open_model_picker(model, "coding")
  end

  defp handle(%{screen: :agent_manager} = model, {:event, %{ch: ?C}}) do
    open_model_picker(model, "coding")
  end

  defp handle(%{screen: :agent_manager} = model, {:event, %{key: @enter}}) do
    agent_key = selected_agent_key(model)
    open_model_picker(model, agent_key)
  end

  defp handle(%{screen: :agent_manager} = model, {:event, %{ch: ?k}}) do
    %{model | selected_index: max(model.selected_index - 1, 0)}
  end

  defp handle(%{screen: :agent_manager} = model, {:event, %{ch: ?j}}) do
    agent_count = map_size(model.agents)
    %{model | selected_index: min(model.selected_index + 1, max(agent_count - 1, 0))}
  end

  defp handle(%{screen: :agent_manager} = model, {:event, %{key: @arrow_up}}) do
    %{model | selected_index: max(model.selected_index - 1, 0)}
  end

  defp handle(%{screen: :agent_manager} = model, {:event, %{key: @arrow_down}}) do
    agent_count = map_size(model.agents)
    %{model | selected_index: min(model.selected_index + 1, max(agent_count - 1, 0))}
  end

  # --- Model Picker screen handlers ---

  defp handle(%{screen: :model_picker} = model, {:event, %{ch: ?k}}) do
    %{model | selected_model_index: max(model.selected_model_index - 1, 0)}
  end

  defp handle(%{screen: :model_picker} = model, {:event, %{ch: ?j}}) do
    agent_cfg = Map.get(model.agents, model.selected_agent, %{})
    provider = agent_cfg["provider"] || ""
    models = Spark.ModelCatalog.models_for_provider(provider)
    max_idx = max(length(models) - 1, 0)
    %{model | selected_model_index: min(model.selected_model_index + 1, max_idx)}
  end

  defp handle(%{screen: :model_picker} = model, {:event, %{key: @arrow_up}}) do
    %{model | selected_model_index: max(model.selected_model_index - 1, 0)}
  end

  defp handle(%{screen: :model_picker} = model, {:event, %{key: @arrow_down}}) do
    agent_cfg = Map.get(model.agents, model.selected_agent, %{})
    provider = agent_cfg["provider"] || ""
    models = Spark.ModelCatalog.models_for_provider(provider)
    max_idx = max(length(models) - 1, 0)
    %{model | selected_model_index: min(model.selected_model_index + 1, max_idx)}
  end

  defp handle(%{screen: :model_picker} = model, {:event, %{key: @enter}}) do
    pin_selected_model(model)
  end

  # --- Tick: periodic refresh from EventLog ---

  defp handle(model, :tick) do
    %{model | dashboard: Actions.dashboard_snapshot(), logs: Actions.load_logs()}
  end

  # --- Logs screen: clear (c/C) ---

  defp handle(%{screen: :logs} = model, {:event, %{ch: ?c}}) do
    Actions.clear_logs()
    %{model | logs: [], status_message: "Logs cleared", error_message: nil}
  end

  defp handle(%{screen: :logs} = model, {:event, %{ch: ?C}}) do
    Actions.clear_logs()
    %{model | logs: [], status_message: "Logs cleared", error_message: nil}
  end

  # --- Catch-all: ignore unrecognized events ---

  defp handle(model, _msg), do: model

  # --- Helpers: Plan approval/rejection ---

  defp do_approve(%{active_plan: nil} = model) do
    %{model | error_message: "No active plan to approve", status_message: nil}
  end

  defp do_approve(%{active_plan: plan} = model) do
    cmd = %{function: fn -> Actions.approve_plan(plan.id) end, message: :approve_result}
    model = %{model | loading?: true, status_message: "Approving plan...", error_message: nil}
    {model, cmd}
  end

  defp do_reject(%{active_plan: nil} = model) do
    %{model | error_message: "No active plan to reject", status_message: nil}
  end

  defp do_reject(%{active_plan: plan} = model) do
    cmd = %{function: fn -> Actions.reject_plan(plan.id) end, message: :reject_result}
    model = %{model | loading?: true, status_message: "Rejecting plan...", error_message: nil}
    {model, cmd}
  end

  # --- Helpers: General ---

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)

  defp task_count(%{active_plan: %{tasks: tasks}}) when is_list(tasks), do: length(tasks)
  defp task_count(_), do: 0

  defp trim_last(str) when is_binary(str), do: String.slice(str, 0, max(String.length(str) - 1, 0))
  defp trim_last(_), do: ""

  defp open_agent_manager(model) do
    model = refresh_runtime(model)
    %{model | screen: :agent_manager, previous_screen: model.screen,
      selected_index: 0, status_message: nil, error_message: nil}
  end

  defp open_dashboard(model) do
    model = refresh_runtime(model)
    %{model | screen: :dashboard, previous_screen: model.screen,
      status_message: nil, error_message: nil}
  end

  defp open_logs(model) do
    model = refresh_runtime(model)
    %{model | screen: :logs, previous_screen: model.screen,
      status_message: nil, error_message: nil}
  end

  defp refresh_current(model) do
    model = refresh_runtime(model)
    %{model | status_message: "Refreshed", error_message: nil}
  end

  defp open_model_picker(model, agent_key) do
    configured = model.agents || %{}

    if Map.has_key?(configured, agent_key) do
      agent = Map.fetch!(configured, agent_key)
      %{model |
        screen: :model_picker,
        previous_screen: :agent_manager,
        selected_agent: agent_key,
        selected_model_index: current_model_index(agent),
        status_message: nil,
        error_message: nil
      }
    else
      %{model | status_message: "Agent '#{agent_key}' not found", error_message: nil}
    end
  end

  defp pin_selected_model(model) do
    agent_key = model.selected_agent
    agent_cfg = Map.get(model.agents, agent_key, %{})
    provider = agent_cfg["provider"] || ""
    models = Spark.ModelCatalog.models_for_provider(provider)
    selected = Enum.at(models, model.selected_model_index)

    if selected == nil do
      %{model | error_message: "No model selected", status_message: nil}
    else
      case Actions.safe(fn -> Spark.AgentManager.pin_model(agent_key, selected.id) end, {:error, "pin_model failed"}) do
        {:ok, _agent} ->
          model = refresh_runtime(model)
          %{model |
            screen: :agent_manager,
            previous_screen: :model_picker,
            status_message: "Pinned #{agent_key} to #{selected.id}",
            error_message: nil
          }

        {:error, reason} ->
          %{model | error_message: "Pin failed: #{reason}", status_message: nil}
      end
    end
  end

  defp ordered_agent_keys(model) do
    configured = model.agents || %{}
    preferred = model.agent_order || []
    preferred_keys = Enum.filter(preferred, &Map.has_key?(configured, &1))
    extra_keys = configured |> Map.keys() |> Kernel.--(preferred_keys) |> Enum.sort()
    preferred_keys ++ extra_keys
  end

  defp selected_agent_key(model) do
    ordered_agent_keys(model) |> Enum.at(model.selected_index)
  end

  defp current_model_index(agent) do
    provider = agent["provider"] || ""
    current = agent["model"] || ""
    models = Spark.ModelCatalog.models_for_provider(provider)
    idx = Enum.find_index(models, &(&1.id == current))
    idx || 0
  end

  defp refresh_runtime(model) do
    %{model | agents: Actions.load_agents(), dashboard: Actions.dashboard_snapshot(), logs: Actions.load_logs()}
  end
end
