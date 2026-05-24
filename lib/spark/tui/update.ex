defmodule Spark.TUI.Update do
  @moduledoc "TUI message handler / update logic."

  require Logger

  # dialyxir bug: TermUI macro generates unreachable comparison (unknown warning type :exact_compare)
  @dialyzer {:nowarn_function, handle_shell_input: 2}

  alias Spark.TUI.Model

  @esc 0x1B
  @enter 0x0D
  @arrow_up 0xFFFF - 18
  @arrow_down 0xFFFF - 19
  @backspace 0x08
  @backspace2 0x7F

  @doc """
  Handles a single message and returns the updated model.
  """
  def update(%Model{} = model, msg), do: handle(model, msg)

  # ── 2. Async result handlers (view_mode transitions) ──

  defp handle(model, {:plan_result, {:ok, plan}}) do
    # Preserve planning_transcript; copy streaming_content into transcript if transcript is empty
    transcript =
      case {model.planning_transcript || "", model.streaming_content || ""} do
        {t, _sc} when t != "" -> t
        {"", sc} when sc != "" -> sc
        _ -> model.planning_transcript || ""
      end

    %{
      model
      | loading?: false,
        active_plan: plan,
        view_mode: :planning_session,
        command_mode: :approve,
        selected_task_index: 0,
        status_message: "Plan ready — review below",
        error_message: nil,
        streaming_content: "",
        streaming_active?: false,
        planning_transcript: transcript
    }
  end

  defp handle(model, {:plan_result, {:error, reason}}) do
    # Preserve planning_transcript for debugging
    transcript =
      case {model.planning_transcript || "", model.streaming_content || ""} do
        {t, _sc} when t != "" -> t
        {"", sc} when sc != "" -> sc
        _ -> model.planning_transcript || ""
      end

    %{
      model
      | loading?: false,
        view_mode: :planning_session,
        error_message: "Planning failed: #{format_reason(reason)}",
        status_message: nil,
        streaming_content: "",
        streaming_active?: false,
        planning_transcript: transcript
    }
  end

  defp handle(model, {:approve_result, {:ok, _plan}}) do
    model = refresh_runtime(model)

    %{
      model
      | view_mode: :execution,
        command_mode: :chat,
        scroll_top: 0,
        status_message: "Handing off to Coding Agent...",
        error_message: nil
    }
  end

  defp handle(model, {:approve_result, {:error, reason}}) do
    %{
      model
      | error_message: "Approval failed: #{format_reason(reason)}",
        status_message: nil,
        loading?: false
    }
  end

  defp handle(model, {:reject_result, {:ok, _plan}}) do
    %{
      model
      | view_mode: :welcome,
        command_mode: :chat,
        scroll_top: 0,
        active_plan: nil,
        status_message: "Plan rejected",
        error_message: nil,
        loading?: false
    }
  end

  defp handle(model, {:reject_result, {:error, reason}}) do
    %{
      model
      | error_message: "Rejection failed: #{format_reason(reason)}",
        status_message: nil,
        loading?: false
    }
  end

  defp handle(model, {:pin_result, {:ok, agent}}) do
    model = refresh_runtime(model)

    %{
      model
      | loading?: false,
        selected_agent: nil,
        selected_index: 0,
        selected_model_index: 0,
        status_message: "✅ Pinned #{agent["actor_type"]} agent to #{agent["model"]}",
        error_message: nil
    }
  end

  defp handle(model, {:pin_result, {:error, reason}}) do
    %{
      model
      | loading?: false,
        error_message: "Pinning failed: #{format_reason(reason)}",
        status_message: nil
    }
  end

  # ── Esc — context-aware back (approve & agent_picker only) ──

  defp handle(
         %{command_mode: :agent_picker, selected_agent: agent_key} = model,
         {:event, %{key: @esc}}
       )
       when not is_nil(agent_key) do
    %{
      model
      | selected_agent: nil,
        selected_index: 0,
        selected_model_index: 0,
        status_message: nil,
        error_message: nil
    }
  end

  defp handle(%{command_mode: :agent_picker} = model, {:event, %{key: @esc}}),
    do: %{model | command_mode: :chat, status_message: nil, error_message: nil}

  defp handle(%{command_mode: :approve} = model, {:event, %{key: @esc}}),
    do: %{
      model
      | command_mode: :chat,
        view_mode: :welcome,
        status_message: nil,
        error_message: nil
    }

  # ── q/Q quit (non-chat only; chat mode swallows to avoid accidental quit) ──

  defp handle(%{command_mode: :chat} = model, {:event, %{ch: ?q}}), do: model
  defp handle(%{command_mode: :chat} = model, {:event, %{ch: ?Q}}), do: model
  defp handle(_model, {:event, %{ch: ?q}}), do: {:quit, nil}
  defp handle(_model, {:event, %{ch: ?Q}}), do: {:quit, nil}

  # ── CHAT mode handlers ──

  # Typing in chat mode
  defp handle(%{command_mode: :chat, loading?: false} = model, {:event, %{ch: ch}})
       when is_integer(ch) and ch >= 32,
       do: %{model | input_buffer: model.input_buffer <> <<ch::utf8>>}

  # Backspace
  defp handle(%{command_mode: :chat, loading?: false} = model, {:event, %{key: @backspace}}),
    do: %{model | input_buffer: trim_last(model.input_buffer)}

  defp handle(%{command_mode: :chat, loading?: false} = model, {:event, %{key: @backspace2}}),
    do: %{model | input_buffer: trim_last(model.input_buffer)}

  # Enter in chat → submit plan, shell command, or handle slash command
  defp handle(%{command_mode: :chat, loading?: false} = model, {:event, %{key: @enter}}) do
    input = String.trim(model.input_buffer)

    if input == "" do
      %{model | error_message: "Enter a goal or slash command (/help)", status_message: nil}
    else
      cond do
        String.starts_with?(input, "/") ->
          handle_slash_command(input, model)

        String.starts_with?(input, "!") ->
          handle_shell_input(input, model)

        true ->
          cmd = %{
            function: fn tui_pid -> Spark.TUI.Actions.start_plan_streaming(input, tui_pid) end,
            message: :plan_result
          }

          model = %{
            model
            | loading?: true,
              status_message: "Planning...",
              error_message: nil,
              input_buffer: "",
              streaming_content: "",
              streaming_active?: true,
              planning_transcript: "",
              view_mode: :planning_session,
              scroll_top: 0
          }

          {model, cmd}
      end
    end
  end

  # Esc in chat while loading → cancel
  defp handle(%{command_mode: :chat, loading?: true} = model, {:event, %{key: @esc}}),
    do: %{
      model
      | command_mode: :chat,
        loading?: false,
        input_buffer: "",
        status_message: "Plan cancelled",
        error_message: nil,
        streaming_content: "",
        streaming_active?: false,
        planning_transcript: ""
    }

  # Ignore keyboard events while loading in chat (stream/tick/scroll still pass through)
  defp handle(%{command_mode: :chat, loading?: true} = model, {:event, _msg}), do: model

  # ── APPROVE mode handlers ──

  defp handle(%{command_mode: :approve} = model, {:event, %{ch: ?a}}), do: do_approve(model)
  defp handle(%{command_mode: :approve} = model, {:event, %{ch: ?A}}), do: do_approve(model)
  defp handle(%{command_mode: :approve} = model, {:event, %{ch: ?r}}), do: do_reject(model)
  defp handle(%{command_mode: :approve} = model, {:event, %{ch: ?R}}), do: do_reject(model)
  defp handle(%{command_mode: :approve} = model, {:event, %{key: @enter}}), do: do_approve(model)

  # Task navigation in approve mode
  defp handle(%{command_mode: :approve} = model, {:event, %{key: key}})
       when key in [@arrow_up, @arrow_down] do
    diff = if key == @arrow_up, do: -1, else: 1
    tasks = if model.active_plan, do: model.active_plan.tasks || [], else: []
    tasks_count = length(tasks)

    if tasks_count > 0 do
      new_idx = max(0, min((model.selected_task_index || 0) + diff, tasks_count - 1))
      %{model | selected_task_index: new_idx}
    else
      model
    end
  end

  defp handle(%{command_mode: :approve} = model, {:event, %{ch: ch}}) when ch in [?k, ?j] do
    diff = if ch == ?k, do: -1, else: 1
    tasks = if model.active_plan, do: model.active_plan.tasks || [], else: []
    tasks_count = length(tasks)

    if tasks_count > 0 do
      new_idx = max(0, min((model.selected_task_index || 0) + diff, tasks_count - 1))
      %{model | selected_task_index: new_idx}
    else
      model
    end
  end

  # ── AGENT PICKER mode handlers ──

  # 1. Navigation when selected_agent is nil (choosing agent planning/coding)
  defp handle(%{command_mode: :agent_picker, selected_agent: nil} = model, {:event, %{key: key}})
       when key in [@arrow_up, @arrow_down] do
    diff = if key == @arrow_up, do: -1, else: 1
    agents_count = length(ordered_agents(model))

    if agents_count > 0 do
      new_idx = Integer.mod((model.selected_index || 0) + diff, agents_count)
      %{model | selected_index: new_idx}
    else
      model
    end
  end

  defp handle(%{command_mode: :agent_picker, selected_agent: nil} = model, {:event, %{ch: ch}})
       when ch in [?k, ?j] do
    diff = if ch == ?k, do: -1, else: 1
    agents_count = length(ordered_agents(model))

    if agents_count > 0 do
      new_idx = Integer.mod((model.selected_index || 0) + diff, agents_count)
      %{model | selected_index: new_idx}
    else
      model
    end
  end

  # 2. Enter key when selected_agent is nil (locks in agent choice, transitions to model picker)
  defp handle(
         %{command_mode: :agent_picker, selected_agent: nil} = model,
         {:event, %{key: @enter}}
       ) do
    agents = ordered_agents(model)

    case Enum.at(agents, model.selected_index || 0) do
      {agent_key, _config} ->
        %{
          model
          | selected_agent: agent_key,
            selected_model_index: 0,
            status_message: nil,
            error_message: nil
        }

      nil ->
        model
    end
  end

  # 3. Navigation when selected_agent is NOT nil (choosing model)
  defp handle(
         %{command_mode: :agent_picker, selected_agent: agent_key} = model,
         {:event, %{key: key}}
       )
       when key in [@arrow_up, @arrow_down] and not is_nil(agent_key) do
    diff = if key == @arrow_up, do: -1, else: 1
    agent = Map.get(model.agents || %{}, agent_key)
    provider = if agent, do: agent["provider"], else: "unknown"
    models = Spark.ModelCatalog.models_for_provider(provider)
    models_count = length(models)

    if models_count > 0 do
      new_idx = Integer.mod((model.selected_model_index || 0) + diff, models_count)
      %{model | selected_model_index: new_idx}
    else
      model
    end
  end

  defp handle(
         %{command_mode: :agent_picker, selected_agent: agent_key} = model,
         {:event, %{ch: ch}}
       )
       when ch in [?k, ?j] and not is_nil(agent_key) do
    diff = if ch == ?k, do: -1, else: 1
    agent = Map.get(model.agents || %{}, agent_key)
    provider = if agent, do: agent["provider"], else: "unknown"
    models = Spark.ModelCatalog.models_for_provider(provider)
    models_count = length(models)

    if models_count > 0 do
      new_idx = Integer.mod((model.selected_model_index || 0) + diff, models_count)
      %{model | selected_model_index: new_idx}
    else
      model
    end
  end

  # 4. Enter key when selected_agent is NOT nil (pins the model)
  defp handle(
         %{command_mode: :agent_picker, selected_agent: agent_key} = model,
         {:event, %{key: @enter}}
       )
       when not is_nil(agent_key) do
    agent = Map.get(model.agents || %{}, agent_key)
    provider = if agent, do: agent["provider"], else: "unknown"
    models = Spark.ModelCatalog.models_for_provider(provider)

    case Enum.at(models, model.selected_model_index || 0) do
      %{id: model_id} ->
        cmd = %{
          function: fn _tui_pid -> Spark.AgentManager.pin_model(agent_key, model_id) end,
          message: :pin_result
        }

        model = %{
          model
          | loading?: true,
            status_message: "Pinning #{agent_key} model...",
            error_message: nil
        }

        {model, cmd}

      nil ->
        model
    end
  end

  # ── :tick handler ──

  defp handle(model, :tick) do
    dashboard = Spark.TUI.Actions.dashboard_snapshot()
    phase = Map.get(dashboard, :orchestrator_phase)
    active = Map.get(dashboard, :active_count, 0)
    completed = Map.get(dashboard, :completed_count, 0)
    failed = Map.get(dashboard, :failed_count, 0)
    queued = Map.get(dashboard, :queue_length, 0)

    total = active + completed + failed + queued
    done = completed + failed
    progress_pct = if total > 0, do: Float.floor(done / total * 100) |> trunc(), else: 0

    status =
      cond do
        phase == :executing and active > 0 ->
          "⚡ Executing: #{active} worker(s) running — #{done}/#{total} tasks done (#{progress_pct}%)"

        phase == :executing and active == 0 and done > 0 ->
          "✅ Execution complete: #{completed} succeeded, #{failed} failed"

        phase == :reviewing ->
          "🔍 Reviewing results..."

        phase == :completed ->
          "✅ Plan completed: #{completed} succeeded, #{failed} failed"

        true ->
          model.status_message
      end

    %{
      model
      | dashboard: dashboard,
        task_statuses: Map.get(dashboard, :task_statuses, []),
        logs: Spark.TUI.Actions.load_logs(),
        spinner_frame: ((model.spinner_frame || 0) + 1) |> rem(8),
        status_message: status
    }
  end

  # ── Resize handler ──

  defp handle(model, {:resized, width, height}) do
    %{model | width: width, height: height}
  end

  # Global scroll handler
  defp handle(model, {:scroll, diff}) do
    new_scroll = max(0, (model.scroll_top || 0) + diff)
    %{model | scroll_top: new_scroll}
  end

  # ── Stream lifecycle handlers ──

  defp handle(model, {:stream_started, _metadata}) do
    %{model | streaming_active?: true}
  end

  defp handle(model, {:stream_chunk, text}) do
    chunk = extract_chunk_text(text)
    current_len = byte_size(model.streaming_content || "")
    new_model = %{
      model
      | streaming_content: (model.streaming_content || "") <> chunk,
        planning_transcript: (model.planning_transcript || "") <> chunk
    }

    Logger.debug(
      "[SPARK] TUI streaming: #{current_len} -> #{byte_size(new_model.streaming_content)} bytes"
    )

    new_model
  end

  defp handle(model, {:stream_done, _metadata}) do
    # Stream finished; plan_result will handle final state transition.
    # We keep streaming_active? true so the content stays visible until plan_result.
    model
  end

  defp handle(model, {:stream_error, reason}) do
    %{
      model
      | streaming_active?: false,
        loading?: false,
        error_message: "Stream error: #{format_reason(reason)}",
        streaming_content: ""
      # Preserve planning_transcript for debugging
    }
  end

  # ── Catch-all ──

  defp handle(model, _msg), do: model

  # ── Helpers ──

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)

  defp trim_last(str) when is_binary(str),
    do: String.slice(str, 0, max(String.length(str) - 1, 0))

  defp trim_last(_), do: ""

  # Extract text from stream chunks — supports both plain binary and typed/map chunks
  defp extract_chunk_text(text) when is_binary(text), do: text

  defp extract_chunk_text(%{type: :reasoning, text: text}) when is_binary(text), do: text

  defp extract_chunk_text(%{text: text}) when is_binary(text), do: text

  defp extract_chunk_text(other), do: to_string(other)

  defp do_approve(%{active_plan: nil} = model) do
    %{model | error_message: "No active plan to approve", status_message: nil}
  end

  defp do_approve(%{active_plan: plan} = model) do
    cmd = %{
      function: fn _tui_pid -> Spark.TUI.Actions.approve_plan(plan.id) end,
      message: :approve_result
    }

    model = %{model | loading?: true, status_message: "Approving plan...", error_message: nil}
    {model, cmd}
  end

  defp do_reject(%{active_plan: nil} = model) do
    %{model | error_message: "No active plan to reject", status_message: nil}
  end

  defp do_reject(%{active_plan: plan} = model) do
    cmd = %{
      function: fn _tui_pid -> Spark.TUI.Actions.reject_plan(plan.id) end,
      message: :reject_result
    }

    model = %{model | loading?: true, status_message: "Rejecting plan...", error_message: nil}
    {model, cmd}
  end

  defp refresh_runtime(model) do
    %{
      model
      | agents: Spark.TUI.Actions.load_agents(),
        dashboard: Spark.TUI.Actions.dashboard_snapshot(),
        logs: Spark.TUI.Actions.load_logs()
    }
  end

  # ── Slash commands ──

  defp handle_slash_command("/welcome", model),
    do: %{model | view_mode: :welcome, input_buffer: "", command_mode: :chat, scroll_top: 0}

  defp handle_slash_command("/home", model),
    do: %{model | view_mode: :welcome, input_buffer: "", command_mode: :chat, scroll_top: 0}

  defp handle_slash_command("/plan", %{active_plan: nil} = model),
    do: %{model | error_message: "No active plan", input_buffer: ""}

  defp handle_slash_command("/plan", model) do
    # Use planning_session when transcript or plan exists for combined view
    if (model.planning_transcript && model.planning_transcript != "") || model.active_plan do
      %{model | view_mode: :planning_session, command_mode: :approve, input_buffer: ""}
    else
      %{model | view_mode: :plan_review, command_mode: :approve, input_buffer: "", scroll_top: 0}
    end
  end

  defp handle_slash_command("/exec", model),
    do: %{model | view_mode: :execution, input_buffer: "", command_mode: :chat, scroll_top: 0}

  defp handle_slash_command("/dash", model),
    do: %{model | view_mode: :execution, input_buffer: "", command_mode: :chat, scroll_top: 0}

  defp handle_slash_command("/dashboard", model),
    do: %{model | view_mode: :execution, input_buffer: "", command_mode: :chat, scroll_top: 0}

  defp handle_slash_command("/logs", model),
    do: %{model | view_mode: :logs, input_buffer: "", command_mode: :chat, scroll_top: 0}

  defp handle_slash_command("/agents", model),
    do: %{
      model
      | command_mode: :agent_picker,
        input_buffer: "",
        selected_agent: nil,
        selected_index: 0,
        selected_model_index: 0
    }

  defp handle_slash_command("/help", model),
    do: %{model | view_mode: :help, input_buffer: "", scroll_top: 0}

  defp handle_slash_command("/quit", _model), do: {:quit, nil}
  defp handle_slash_command("/exit", _model), do: {:quit, nil}

  defp handle_slash_command("/clear", model),
    do: %{model | input_buffer: "", error_message: nil, status_message: nil}

  defp handle_slash_command("/approve", %{active_plan: nil} = model),
    do: %{model | error_message: "No active plan", input_buffer: ""}

  defp handle_slash_command("/approve", model), do: do_approve(%{model | input_buffer: ""})

  defp handle_slash_command("/reject", %{active_plan: nil} = model),
    do: %{model | error_message: "No active plan", input_buffer: ""}

  defp handle_slash_command("/reject", model), do: do_reject(%{model | input_buffer: ""})

  # /tasks — show task list view
  defp handle_slash_command("/tasks", %{active_plan: nil} = model),
    do: %{model | error_message: "No active plan. Start one with a goal.", input_buffer: ""}

  defp handle_slash_command("/tasks", model),
    do: %{model | view_mode: :tasks, input_buffer: "", command_mode: :chat, scroll_top: 0}

  # /reload variants — hot reload (ported from CLI)
  defp handle_slash_command("/reload", model), do: do_reload_all(model)
  defp handle_slash_command("/reload all", model), do: do_reload_all(model)
  defp handle_slash_command("/reload prompts", model), do: do_reload(:prompts, model)
  defp handle_slash_command("/reload tools", model), do: do_reload(:tools, model)
  defp handle_slash_command("/reload config", model), do: do_reload(:config, model)
  defp handle_slash_command("/reload policy", model), do: do_reload(:policy, model)
  defp handle_slash_command("/reload guidance", model), do: do_reload(:guidance, model)
  defp handle_slash_command("/reload status", model), do: do_reload_status(model)

  defp handle_slash_command(cmd, model),
    do: %{model | error_message: "Unknown command: #{cmd}. Try /help", input_buffer: ""}

  # ── Shell command handling (ported from CLI) ───────────────────────

  defp handle_shell_input(input, model) do
    cmd = String.slice(input, 1..-1//1)

    if String.trim(cmd) == "" do
      %{model | error_message: "Usage: !<shell command>", input_buffer: ""}
    else
      {output, exit_code} = Spark.TUI.Actions.run_shell_command(cmd)

      lines =
        output
        |> String.split("\n", trim: true)
        # cap to avoid overwhelming the canvas
        |> Enum.take(50)

      header =
        if exit_code == 0, do: "  💻 Shell: #{cmd}", else: "  ❌ Shell (exit #{exit_code}): #{cmd}"

      canvas = [header, ""] ++ lines ++ ["", "  Press /welcome to return"]

      %{
        model
        | view_mode: :shell_output,
          canvas_lines: canvas,
          input_buffer: "",
          command_mode: :chat
      }
    end
  end

  # ── Reload helpers (ported from CLI) ─────────────────────────────

  @reload_targets [:prompts, :tools, :config, :policy, :guidance]

  defp do_reload(type, model) do
    case Spark.TUI.Actions.reload_component(type) do
      {:ok, %{status: :success}} ->
        %{model | status_message: "✅ Reloaded #{type}", error_message: nil, input_buffer: ""}

      {:ok, %{status: :failed, error: err}} ->
        %{
          model
          | error_message: "❌ Reload #{type} failed: #{inspect(err)}",
            status_message: nil,
            input_buffer: ""
        }

      {:error, reason} ->
        %{
          model
          | error_message: "❌ Reload #{type} error: #{format_reason(reason)}",
            status_message: nil,
            input_buffer: ""
        }
    end
  end

  defp do_reload_all(model) do
    results = for type <- @reload_targets, do: {type, Spark.TUI.Actions.reload_component(type)}

    lines =
      Enum.map(results, fn
        {t, {:ok, %{status: :success}}} -> "  ✅ #{t}: OK"
        {t, {:ok, %{status: :failed, error: err}}} -> "  ❌ #{t}: FAILED — #{inspect(err)}"
        {t, {:error, reason}} -> "  ❌ #{t}: #{format_reason(reason)}"
      end)

    canvas = ["", "  🔄 Reload All Results", ""] ++ lines ++ ["", "  Press /welcome to return"]

    %{
      model
      | view_mode: :shell_output,
        canvas_lines: canvas,
        input_buffer: "",
        command_mode: :chat
    }
  end

  defp do_reload_status(model) do
    status = Spark.TUI.Actions.reload_status()
    entries = Spark.TUI.Actions.reload_manifest_entries()

    lines =
      if status == nil do
        ["  Coordinator not available"]
      else
        base = ["  Status: #{status.status} | Reload count: #{status.reload_count}"]

        last =
          if lr = status.last_reload do
            ["  Last: #{lr.type} — #{lr.status}"] ++
              if lr.error, do: ["  Error: #{inspect(lr.error)}"], else: []
          else
            ["  Last: —"]
          end

        entry_lines =
          Enum.map(entries, fn e -> "  #{e.component}:#{e.name} — v#{e.version} (#{e.status})" end)

        base ++ last ++ entry_lines
      end

    canvas = ["", "  🔄 Reload Status", ""] ++ lines ++ ["", "  Press /welcome to return"]

    %{
      model
      | view_mode: :shell_output,
        canvas_lines: canvas,
        input_buffer: "",
        command_mode: :chat
    }
  end

  defp ordered_agents(model) do
    configured = model.agents || %{}
    preferred = model.agent_order || ["planning", "coding"]

    pref =
      Enum.filter(preferred, &Map.has_key?(configured, &1))
      |> Enum.map(fn k -> {k, Map.fetch!(configured, k)} end)

    extra = Map.drop(configured, preferred) |> Enum.sort_by(fn {k, _} -> k end)
    pref ++ extra
  end
end
