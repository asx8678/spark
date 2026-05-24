defmodule Spark.TermUI do
  @moduledoc """
  TermUI-based terminal UI for Spark — Component Protocol.
  Uses the simple init/view/update protocol that TermUI.App.run expects.
  """

  require Logger

  # ── Init ──

  def init(_opts) do
    Spark.TUI.Actions.install_event_log_hook()

    # Disable mouse tracking after a brief delay to enable text selection/copy
    Process.send_after(self(), :disable_mouse_tracking, 500)

    {rows, cols} =
      case TermUI.Terminal.get_terminal_size() do
        {:ok, {r, c}} -> {r, c}
        _ -> {24, 80}
      end

    %{
      model: %Spark.TUI.Model{
        session_id: gen_id(),
        agents: Spark.TUI.Actions.load_agents(),
        agent_order: ["planning", "coding"],
        dashboard: Spark.TUI.Actions.dashboard_snapshot(),
        logs: Spark.TUI.Actions.load_logs(),
        status_message: nil,
        width: cols,
        height: rows,
        scroll_top: 0
      },
      tick_count: 0,
      shutting_down: false
    }
  end

  # ── Event to message conversion (called by TermUI Runtime) ──

  def event_to_msg(event, _state) do
    cond do
      # Quit keys
      is_map(event) && Map.get(event, :key) == :ctrl_c ->
        {:msg, :quit}

      # PageUp / PageDown keys
      is_map(event) && Map.get(event, :key) == :page_up ->
        {:msg, {:scroll, -5}}

      is_map(event) && Map.get(event, :key) == :page_down ->
        {:msg, {:scroll, 5}}

      # Mouse scroll actions
      is_map(event) && Map.get(event, :action) == :scroll_up ->
        {:msg, {:scroll, -3}}

      is_map(event) && Map.get(event, :action) == :scroll_down ->
        {:msg, {:scroll, 3}}

      # Ctrl-key scroll shortcuts
      is_map(event) && :ctrl in Map.get(event, :modifiers, []) ->
        case Map.get(event, :char) do
          "p" -> {:msg, {:scroll, -1}}
          "n" -> {:msg, {:scroll, 1}}
          "k" -> {:msg, {:scroll, -1}}
          "j" -> {:msg, {:scroll, 1}}
          "u" -> {:msg, {:scroll, -5}}
          "d" -> {:msg, {:scroll, 5}}
          "c" -> {:msg, :quit}
          _ -> :ignore
        end

      # Printable characters (use char for correct case)
      is_map(event) && is_binary(Map.get(event, :char, "")) &&
          byte_size(Map.get(event, :char, "")) == 1 ->
        ch = Map.get(event, :char)
        <<codepoint::utf8>> = ch
        {:msg, {:event, %{ch: codepoint}}}

      # Special keys
      is_map(event) && is_atom(Map.get(event, :key)) ->
        key = Map.get(event, :key)

        case key do
          :enter -> {:msg, {:event, %{key: 0x0D}}}
          :escape -> {:msg, {:event, %{key: 0x1B}}}
          :up -> {:msg, {:event, %{key: 0xFFFF - 18}}}
          :down -> {:msg, {:event, %{key: 0xFFFF - 19}}}
          :left -> {:msg, {:event, %{key: 0xFFFF - 20}}}
          :right -> {:msg, {:event, %{key: 0xFFFF - 21}}}
          :backspace -> {:msg, {:event, %{key: 0x08}}}
          _ -> :ignore
        end

      # Tick events
      is_map(event) && is_integer(Map.get(event, :interval, nil)) &&
          Map.get(event, :interval, 0) > 0 ->
        {:msg, :tick}

      # Resize events
      is_map(event) && Map.has_key?(event, :width) && Map.has_key?(event, :height) ->
        {:msg, {:resized, event.width, event.height}}

      true ->
        :ignore
    end
  end

  # ── Handle async results (from Task.start) ──

  def handle_info({:plan_result, result}, state) do
    Logger.debug("[SPARK] plan_result received")
    model = Spark.TUI.Update.update(state.model, {:plan_result, result})
    {%{state | model: model}, []}
  end

  def handle_info({:approve_result, result}, state) do
    Logger.debug("[SPARK] approve_result received")
    model = Spark.TUI.Update.update(state.model, {:approve_result, result})
    {%{state | model: model}, []}
  end

  def handle_info({:reject_result, result}, state) do
    Logger.debug("[SPARK] reject_result received")
    model = Spark.TUI.Update.update(state.model, {:reject_result, result})
    {%{state | model: model}, []}
  end

  def handle_info({:pin_result, result}, state) do
    Logger.debug("[SPARK] pin_result received")
    model = Spark.TUI.Update.update(state.model, {:pin_result, result})
    {%{state | model: model}, []}
  end

  def handle_info(:disable_mouse_tracking, state) do
    TermUI.Terminal.disable_mouse_tracking()
    {state, []}
  end

  def handle_info({:shutdown_complete, _result}, state) do
    Logger.info("[SPARK] Shutdown complete — exiting")
    {state, [:quit]}
  end

  def handle_info({:stream_chunk, text}, state) do
    Logger.debug("[SPARK] stream_chunk: #{chunk_debug_size(text)} bytes")
    model = Spark.TUI.Update.update(state.model, {:stream_chunk, text})
    {%{state | model: model}, []}
  end

  def handle_info({:stream_started, metadata}, state) do
    Logger.debug("[SPARK] stream_started: #{inspect(metadata)}")
    model = Spark.TUI.Update.update(state.model, {:stream_started, metadata})
    {%{state | model: model}, []}
  end

  def handle_info({:stream_done, metadata}, state) do
    Logger.debug("[SPARK] stream_done: #{inspect(metadata)}")
    model = Spark.TUI.Update.update(state.model, {:stream_done, metadata})
    {%{state | model: model}, []}
  end

  def handle_info({:stream_error, reason}, state) do
    Logger.warning("[SPARK] stream_error: #{inspect(reason)}")
    model = Spark.TUI.Update.update(state.model, {:stream_error, reason})
    {%{state | model: model}, []}
  end

  def handle_info(msg, state) do
    case msg do
      :tick ->
        update(:tick, state)

      _ ->
        result = Spark.TUI.Update.update(state.model, msg)

        case result do
          {model, _cmd} -> {%{state | model: model}, []}
          model -> {%{state | model: model}, []}
        end
    end
  end

  # ── Update ──

  def update(:tick, %{tick_count: count} = state) do
    if rem(count, 60) == 0 do
      model = Spark.TUI.Update.update(state.model, :tick)
      {%{state | model: model, tick_count: count + 1}, []}
    else
      {%{state | tick_count: count + 1}, []}
    end
  end

  def update({:resized, width, height}, state) do
    model = Spark.TUI.Update.update(state.model, {:resized, width, height})
    {%{state | model: model}, []}
  end

  def update(:resized, state) do
    {rows, cols} =
      case TermUI.Terminal.get_terminal_size() do
        {:ok, {r, c}} -> {r, c}
        _ -> {24, 80}
      end

    model = Spark.TUI.Update.update(state.model, {:resized, cols, rows})
    {%{state | model: model}, []}
  end

  def update(:quit, %{shutting_down: true} = state), do: {state, [:quit]}

  def update(:quit, state) do
    # Begin graceful shutdown — second Ctrl+C will force-quit
    runtime_self = self()
    session_id = state.model.session_id

    Task.start(fn ->
      Logger.info("[SPARK] Graceful shutdown initiated")

      # 1. Drain workers (up to 5s)
      drain_result =
        try do
          Spark.Dispatcher.drain(5000)
        rescue
          _ -> {:timeout, -1}
        catch
          :exit, _ -> {:timeout, -1}
        end

      Logger.info("[SPARK] Drain result: #{inspect(drain_result)}")

      # 2. Flush Bronze log — write a shutdown event
      if session_id do
        try do
          Spark.Memory.Bronze.append(session_id, %{
            type: :shutdown,
            source: "term_ui",
            payload: %{drain_result: drain_result}
          })
        rescue
          _ -> :ok
        catch
          :exit, _ -> :ok
        end
      end

      send(runtime_self, {:shutdown_complete, drain_result})
    end)

    model = %{state.model | status_message: "🛑 Shutting down..."}
    {%{state | model: model, shutting_down: true}, []}
  end

  def update(msg, state) do
    result = Spark.TUI.Update.update(state.model, msg)

    case result do
      {:quit, _} ->
        {state, [:quit]}

      {model, cmd} ->
        execute_async(cmd, model, state)

      model ->
        {%{state | model: model}, []}
    end
  end

  # ── Async execution ──

  defp execute_async(cmd, model, state) do
    runtime_self = self()

    Task.start(fn ->
      try do
        result = cmd.function.(runtime_self)
        Logger.debug("[SPARK] async #{cmd.message} completed")
        send(runtime_self, {cmd.message, result})
      rescue
        e ->
          Logger.debug("[SPARK] async #{cmd.message} error: #{Exception.message(e)}")
          send(runtime_self, {cmd.message, {:error, Exception.message(e)}})
      catch
        :exit, reason ->
          Logger.debug("[SPARK] async #{cmd.message} exit: #{inspect(reason)}")
          send(runtime_self, {cmd.message, {:error, {:exit, reason}}})
      end
    end)

    {%{state | model: model}, []}
  end

  # ── View ──

  def view(state) do
    model = state.model
    dims = {model.width || 80, model.height || 24}

    status_opts = [
      status_line: status_info_for_state(state),
      scroll_top: model.scroll_top || 0
    ]

    Spark.TUI.Layout.render_dashboard(
      dims,
      fn -> render_canvas_content(model) end,
      fn -> render_deck_content(model) end,
      status_opts
    )
  end

  defp status_info(%{error_message: err}) when is_binary(err) and err != "",
    do: {"  ❌ " <> err, :red}

  defp status_info(%{status_message: msg}) when is_binary(msg) and msg != "",
    do: {"  ℹ️ " <> msg, :green}

  defp status_info(_), do: nil

  # Override status when shutting down
  defp status_info_for_state(%{shutting_down: true}), do: {"  🛑 Shutting down...", :yellow}
  defp status_info_for_state(%{model: model}), do: status_info(model)

  # ── Canvas Content ──

  defp render_canvas_content(model) do
    # Planning session takes priority — combined view for both streaming and plan
    cond do
      model.view_mode == :planning_session ->
        planning_session_lines(model)

      model.streaming_active? ->
        streaming_lines(model)

      true ->
        case model.view_mode || :welcome do
          :welcome -> welcome_lines(model)
          :plan_review -> plan_review_lines(model)
          :execution -> execution_lines(model)
          :logs -> logs_lines(model)
          :help -> help_lines(model)
          :tasks -> tasks_lines(model)
          :shell_output -> shell_output_lines(model)
          _ -> welcome_lines(model)
        end
    end
  end

  # ── Deck Content ──

  defp render_deck_content(model) do
    case model.command_mode || :chat do
      :chat -> chat_deck_lines(model)
      :approve -> approve_deck_lines(model)
      :agent_picker -> agent_picker_deck_lines(model)
      _ -> chat_deck_lines(model)
    end
  end

  # ── Streaming Lines (canvas display during planning) ──

  defp streaming_lines(model) do
    content = model.streaming_content || ""

    if content == "" do
      # Pre-token placeholder: immediate feedback before first chunk
      spinner_frame = model.spinner_frame || 0
      spinner_chars = ~w[⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇]
      spinner = Enum.at(spinner_chars, rem(spinner_frame, length(spinner_chars)), "⠋")

      [
        "",
        "  #{spinner}  📡 Connecting to planning model...",
        "  Waiting for first token...",
        ""
      ]
    else
      lines = content |> String.split("\n") |> Enum.map(fn line -> "  #{line}" end)
      status = if model.status_message, do: ["", "  #{model.status_message}...", ""], else: [""]
      ["" | status] ++ [""] ++ lines
    end
  end

  # ── Combined Planning Session Lines ──

  defp planning_session_lines(model) do
    # Determine status label
    status_label =
      cond do
        model.streaming_active? -> "📡 Streaming..."
        model.active_plan != nil -> "✅ Plan ready"
        model.error_message != nil and model.error_message != "" -> "❌ Error"
        model.loading? -> "⏳ Loading..."
        true -> "—"
      end

    # Header
    header = [
      "",
      "  📋 Planning Session",
      "  Status: #{status_label}",
      ""
    ]

    # Transcript section — use planning_transcript (persistent), fallback to streaming_content (live)
    transcript =
      case {model.planning_transcript || "", model.streaming_content || ""} do
        {t, _sc} when t != "" -> t
        {"", sc} when sc != "" -> sc
        _ -> ""
      end

    transcript_lines =
      if transcript == "" and model.streaming_active? do
        # Show connecting/waiting placeholder
        spinner_frame = model.spinner_frame || 0
        spinner_chars = ~w[⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇]
        spinner = Enum.at(spinner_chars, rem(spinner_frame, length(spinner_chars)), "⠋")

        [
          "  ─── Model Output / Visible Reasoning ───",
          "",
          "  #{spinner}  📡 Connecting to planning model...",
          "  Waiting for first token...",
          ""
        ]
      else
        if transcript == "" do
          [
            "  ─── Model Output / Visible Reasoning ───",
            "",
            "  (no transcript)",
            ""
          ]
        else
          t_lines = transcript |> String.split("\n") |> Enum.map(fn line -> "  #{line}" end)
          ["  ─── Model Output / Visible Reasoning ───", "" | t_lines] ++ [""]
        end
      end

    # Plan section
    plan_lines =
      if model.active_plan do
        planning_session_plan_lines(model)
      else
        if model.streaming_active? do
          ["  ─── Structured Plan ───", "", "  Structured plan will appear below when parsing completes...", ""]
        else
          []
        end
      end

    # Error section (if any)
    error_lines = error_prefix(model)

    error_lines ++ header ++ transcript_lines ++ plan_lines
  end

  # Renders the structured plan portion of the planning session
  defp planning_session_plan_lines(model) do
    plan = model.active_plan

    status_str =
      case plan.approval_status do
        :approved -> "[APPROVED]"
        :awaiting_approval -> "[AWAITING APPROVAL]"
        :rejected -> "[REJECTED]"
        s -> "[#{String.upcase(to_string(s))}]"
      end

    task_lines =
      if plan.tasks do
        sel = model.selected_task_index || 0

        Enum.with_index(plan.tasks)
        |> Enum.flat_map(fn {task, idx} ->
          marker = if idx == sel, do: "▸", else: " "

          risk_sym =
            case task.risk do
              :low -> "🟢"
              :medium -> "🟡"
              :high -> "🔴"
              _ -> "⚪"
            end

          [
            "  #{marker} #{task.id}: #{task.title}",
            "     #{risk_sym} Risk: #{task.risk} | Deps: #{join_or_none(task.depends_on)} | R/W: #{join_or_none(task.read_paths)}/#{join_or_none(task.write_paths)}"
          ]
        end)
      else
        ["  No tasks defined."]
      end

    plan_header =
      [
        "  ─── Structured Plan ───",
        "",
        "  PLAN: #{plan.id}",
        "  Goal: #{plan.user_goal}",
        "  Status: #{status_str}",
        "  Summary: #{plan.summary || "--"}",
        "",
        "  ─── Tasks ───"
      ]

    detail =
      if sel_task = Enum.at(plan.tasks || [], model.selected_task_index || 0) do
        [
          "",
          "  ─── Detail: #{sel_task.id} ───",
          "  #{sel_task.title}",
          "  #{sel_task.description || "--"}",
          "  Timeout: #{sel_task.timeout_ms}ms  Retries: #{sel_task.max_retries}"
        ]
      else
        []
      end

    plan_header ++ task_lines ++ detail
  end

  # ── Welcome Lines ──

  defp welcome_lines(model) do
    dash = model.dashboard || %{}
    phase = dash[:orchestrator_phase] || :idle
    queue = dash[:queue_length] || 0
    active = dash[:active_count] || 0
    agents = model.agents || %{}
    planning = Map.get(agents, "planning", %{})
    coding = Map.get(agents, "coding", %{})

    planning_model = planning["model"] || "--"
    planning_prov = planning["provider"] || "--"
    coding_model = coding["model"] || "--"
    coding_prov = coding["provider"] || "--"
    planning_key = if secret?(:deepseek_api_key), do: "OK", else: "MISSING"
    coding_key = if secret?(:wafer_api_key), do: "OK", else: "MISSING"

    error_prefix = error_prefix(model)

    error_prefix ++
      [
        "",
        "  🔮  S P A R K   v 4 . 1   🐶",
        "  Parallel Actor-Model Code Agent",
        "",
        "  ─── Agent Status ───",
        "  📋 Planning  |  #{planning_model} (#{planning_prov})  key: #{planning_key}",
        "  🔧 Coding    |  #{coding_model} (#{coding_prov})  key: #{coding_key}",
        "",
        "  ─── Runtime ───",
        "  Phase: #{String.capitalize(to_string(phase))}  |  Queue: #{queue}  |  Active: #{active}",
        "",
        "  ─── Shortcuts ───",
        "  Type a goal + Enter to plan",
        "  /welcome /plan /exec /logs /dash /agents /help /quit /clear",
        "  /tasks /reload [prompts|tools|config|policy|guidance|all|status]",
        "  /approve /reject  (when plan is active)  |  !<cmd> shell",
        "",
        "  Ready. Type your goal or a slash command."
      ]
  end

  # ── Plan Review Lines ──

  defp plan_review_lines(model) do
    plan = model.active_plan

    if plan == nil do
      error_prefix(model) ++ ["", "  No active plan.", ""]
    else
      status_str =
        case plan.approval_status do
          :approved -> "[APPROVED]"
          :awaiting_approval -> "[AWAITING APPROVAL]"
          :rejected -> "[REJECTED]"
          s -> "[#{String.upcase(to_string(s))}]"
        end

      task_lines =
        if plan.tasks do
          sel = model.selected_task_index || 0

          Enum.with_index(plan.tasks)
          |> Enum.flat_map(fn {task, idx} ->
            marker = if idx == sel, do: "▸", else: " "

            risk_sym =
              case task.risk do
                :low -> "🟢"
                :medium -> "🟡"
                :high -> "🔴"
                _ -> "⚪"
              end

            [
              "  #{marker} #{task.id}: #{task.title}",
              "     #{risk_sym} Risk: #{task.risk} | Deps: #{join_or_none(task.depends_on)} | R/W: #{join_or_none(task.read_paths)}/#{join_or_none(task.write_paths)}"
            ]
          end)
        else
          ["  No tasks defined."]
        end

      error_prefix = error_prefix(model)

      header =
        error_prefix ++
          [
            "",
            "  PLAN: #{plan.id}",
            "  Goal: #{plan.user_goal}",
            "  Status: #{status_str}",
            "  Summary: #{plan.summary || "--"}",
            "",
            "  ─── Tasks ───"
          ]

      detail =
        if sel_task = Enum.at(plan.tasks || [], model.selected_task_index || 0) do
          [
            "",
            "  ─── Detail: #{sel_task.id} ───",
            "  #{sel_task.title}",
            "  #{sel_task.description || "--"}",
            "  Timeout: #{sel_task.timeout_ms}ms  Retries: #{sel_task.max_retries}"
          ]
        else
          []
        end

      header ++ task_lines ++ detail
    end
  end

  # ── Execution Lines ──

  defp execution_lines(model) do
    d = model.dashboard || %{}
    phase = d[:orchestrator_phase] || :idle
    queue = d[:queue_length] || 0
    active = d[:active_count] || 0
    completed = d[:completed_count] || 0
    failed = d[:failed_count] || 0
    max_conc = d[:max_concurrency] || "--"
    workers = d[:active_worker_tasks] || []
    total = completed + failed + active + queue
    pct = if total > 0, do: round(completed / total * 100), else: 0
    bar_filled = round(pct / 100 * 20)

    bar =
      "[" <> String.duplicate("█", bar_filled) <> String.duplicate("░", 20 - bar_filled) <> "]"

    worker_lines =
      if workers == [] do
        ["  Workers: none active"]
      else
        ["  Active Workers:"] ++ Enum.map(workers, fn name -> "    ⚡ #{name}" end)
      end

    task_statuses = d[:task_statuses] || []

    task_status_lines =
      if task_statuses == [] do
        ["  No tasks in current plan"]
      else
        Enum.map(task_statuses, fn entry ->
          icon =
            case entry.status do
              :running -> "⚡"
              :completed -> "✅"
              :failed -> "❌"
              :queued -> "📋"
              _ -> "⏳"
            end

          status_label = entry.status |> to_string()
          title = entry[:title] || entry.task_id
          "  #{icon} #{entry.task_id}: #{title} [#{status_label}]"
        end)
      end

    log_lines =
      (model.logs || [])
      |> Enum.take(5)
      |> Enum.map(fn entry ->
        time =
          if entry.at,
            do: entry.at |> DateTime.to_time() |> Time.to_string() |> String.slice(0, 8),
            else: "--:--:--"

        type = entry.type |> to_string() |> String.slice(0, 20)

        # Show payload message for Code Puppy compat events
        payload = entry.payload || %{}
        msg = if m = payload[:message], do: " #{String.slice(m, 0, 40)}", else: ""

        "  #{time}  #{type}#{msg}"
      end)

    error_prefix = error_prefix(model)

    error_prefix ++
      [
        "",
        "  ⚡ EXECUTION DASHBOARD",
        "",
        "  Phase: #{String.capitalize(to_string(phase))}  |  #{bar} #{pct}%",
        "  Queue: #{queue}  Active: #{active}/#{max_conc}  Done: #{completed}  Failed: #{failed}",
        ""
      ] ++
      worker_lines ++
      [
        "",
        "  ─── Task Status ───"
      ] ++
      task_status_lines ++
      [
        "",
        "  ─── Recent Events ───"
      ] ++ log_lines
  end

  # ── Logs Lines ──

  defp logs_lines(model) do
    log_entries =
      (model.logs || [])
      |> Enum.take(30)
      |> Enum.map(fn entry ->
        time =
          if entry.at,
            do: entry.at |> DateTime.to_time() |> Time.to_string() |> String.slice(0, 8),
            else: "--:--:--"

        type = entry.type |> to_string() |> String.pad_trailing(22)
        source = entry.source |> to_string()

        id =
          cond do
            entry.task_id -> " task=#{String.slice(entry.task_id, 0, 8)}"
            entry.plan_id -> " plan=#{String.slice(entry.plan_id, 0, 8)}"
            true -> ""
          end

        # Show payload message/reason when available (Code Puppy compat events)
        payload_msg = extract_payload_message(entry)

        "  #{time}  #{type} #{source}#{id}#{payload_msg}"
      end)

    ["" | log_entries]
  end

  defp extract_payload_message(entry) do
    payload = entry.payload || %{}

    cond do
      msg = payload[:message] -> " #{String.slice(msg, 0, 60)}"
      reason = payload[:reason] -> " reason=#{String.slice(inspect(reason), 0, 40)}"
      true -> ""
    end
  end

  # ── Chat Deck ──

  defp chat_deck_lines(model) do
    spinner_frame = model.spinner_frame || 0
    spinner_chars = ~w[⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇]
    spinner = Enum.at(spinner_chars, rem(spinner_frame, length(spinner_chars)), "⠋")

    cond do
      model.loading? ->
        base = ["  #{spinner}  #{model.status_message || "Planning..."}"]
        streaming = model.streaming_content || ""

        if streaming != "" do
          lines =
            streaming
            |> String.split("\n")
            |> Enum.take(-5)
            |> Enum.map(fn line -> "  │ #{String.slice(line, 0, 70)}" end)

          base ++ lines ++ [""]
        else
          base ++ [""]
        end

      true ->
        [
          "  > #{model.input_buffer}▌",
          "  /welcome /plan /exec /logs /dash /agents /help /quit /clear",
          "  /tasks /reload [type|all|status]  |  !<cmd> shell"
        ]
    end
  end

  # ── Approve Deck ──

  defp approve_deck_lines(_model) do
    ["  [A]pprove  [R]eject  [↑/↓] Scroll  [Esc] Back  |  /approve /reject"]
  end

  # ── Agent Picker Deck ──

  defp agent_picker_deck_lines(model) do
    if model.selected_agent == nil do
      agents = ordered_agents(model)

      agent_str =
        agents
        |> Enum.with_index()
        |> Enum.map(fn {{key, _cfg}, idx} ->
          marker = if idx == (model.selected_index || 0), do: "▸", else: " "
          "#{marker}#{key}"
        end)
        |> Enum.join("  ")

      ["  Agents: #{agent_str}", "  [↑/↓] Select  [Enter] Pick Model  [Esc] Back"]
    else
      agent = Map.get(model.agents || %{}, model.selected_agent)
      provider = if agent, do: agent["provider"], else: "unknown"
      models = Spark.ModelCatalog.models_for_provider(provider)
      current_model = if agent, do: agent["model"], else: "unknown"

      model_str =
        models
        |> Enum.with_index()
        |> Enum.map(fn {m, idx} ->
          marker = if idx == (model.selected_model_index || 0), do: "▸", else: " "
          current_marker = if m.id == current_model, do: "*", else: ""
          "#{marker}#{m.name}#{current_marker}"
        end)
        |> Enum.join("  ")

      [
        "  Select model for #{model.selected_agent}: #{model_str}",
        "  [↑/↓] Select  [Enter] Pin Model  [Esc] Back to Agents"
      ]
    end
  end

  # ── Helpers ──

  defp ordered_agents(model) do
    configured = model.agents || %{}
    preferred = model.agent_order || ["planning", "coding"]

    pref =
      Enum.filter(preferred, &Map.has_key?(configured, &1))
      |> Enum.map(fn k -> {k, Map.fetch!(configured, k)} end)

    extra = Map.drop(configured, preferred) |> Enum.sort_by(fn {k, _} -> k end)
    pref ++ extra
  end

  defp secret?(key) do
    case Spark.Config.Secrets.get_secret(key) do
      s when is_binary(s) and s != "" -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp join_or_none(list) when is_list(list) and length(list) > 0, do: Enum.join(list, ", ")
  defp join_or_none(_), do: "none"

  defp error_prefix(%{error_message: err}) when is_binary(err) and err != "",
    do: ["", "  ❌ #{err}"]

  defp error_prefix(_), do: []

  # ── Help Lines ──

  # ── Tasks Lines ──

  defp tasks_lines(%{active_plan: nil} = model) do
    error_prefix(model) ++ ["", "  No active plan. Start one with a goal.", ""]
  end

  defp tasks_lines(model) do
    plan = model.active_plan
    dash = model.dashboard || %{}
    queue = dash[:queue_length] || 0
    completed = dash[:completed_count] || 0
    failed = dash[:failed_count] || 0

    task_lines =
      Enum.map(plan.tasks, fn t ->
        status_sym =
          case t.status do
            :completed -> "✅"
            :failed -> "❌"
            :running -> "⚡"
            :queued -> "📋"
            _ -> "⏳"
          end

        "  #{status_sym} #{t.id}: #{t.title} [#{t.status}]"
      end)

    error_prefix(model) ++
      [
        "",
        "  📋 TASKS — #{plan.id}",
        "  Queued: #{queue} | Completed: #{completed} | Failed: #{failed}",
        ""
      ] ++ task_lines ++ [""]
  end

  # ── Shell Output Lines ──

  defp shell_output_lines(model) do
    model.canvas_lines || ["", "  No output.", ""]
  end

  defp help_lines(_model) do
    [
      "",
      "  📖  S P A R K   H E L P",
      "",
      "  ─── Slash Commands ───",
      "  /welcome      Return to the welcome screen",
      "  /plan         View the active plan (if any)",
      "  /exec         Switch to execution dashboard",
      "  /logs         Show recent event logs",
      "  /dash         Alias for /exec (dashboard)",
      "  /agents       Pick or configure an agent",
      "  /tasks        Show task list for active plan",
      "  /approve      Approve the active plan",
      "  /reject       Reject the active plan",
      "  /clear        Clear error/status messages",
      "  /help         Show this help screen",
      "  /quit         Exit Spark",
      "",
      "  ─── Reload Commands ───",
      "  /reload              Reload all components",
      "  /reload prompts      Reload prompts",
      "  /reload tools        Reload tools",
      "  /reload config       Reload config",
      "  /reload policy       Reload policy",
      "  /reload guidance     Reload guidance",
      "  /reload all          Reload all components",
      "  /reload status       Show reload status",
      "",
      "  ─── Shell Commands ───",
      "  !<command>           Run a shell command",
      "",
      "  ─── Navigation ───",
      "  ↑/↓           Scroll / navigate tasks",
      "  PageUp/PageDown  Scroll by page",
      "  Esc           Go back / cancel",
      "  Enter         Submit goal or confirm",
      "",
      "  Type a goal + Enter to start planning."
    ]
  end

  defp gen_id, do: "tui_" <> Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)

  defp chunk_debug_size(text) when is_binary(text), do: byte_size(text)
  defp chunk_debug_size(%{text: text}) when is_binary(text), do: byte_size(text)
  defp chunk_debug_size(_), do: 0
end
