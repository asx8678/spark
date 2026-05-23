defmodule Spark.TermUI do
  @moduledoc """
  TermUI-based terminal UI for Spark — Component Protocol.
  Uses the simple init/view/update protocol that TermUI.App.run expects.
  """

  require Logger
  import TermUI.Component.Helpers
  alias TermUI.Renderer.Style

  # ── Init ──

  def init(_opts) do
    Spark.TUI.Actions.install_event_log_hook()

    # Disable mouse tracking after a brief delay to enable text selection/copy
    Process.send_after(self(), :disable_mouse_tracking, 500)

    %{
      model: %Spark.TUI.Model{
        session_id: gen_id(),
        screen: :home,
        agents: Spark.TUI.Actions.load_agents(),
        agent_order: ["planning", "coding"],
        dashboard: Spark.TUI.Actions.dashboard_snapshot(),
        logs: Spark.TUI.Actions.load_logs(),
        status_message: nil
      },
      tick_count: 0
    }
  end

  # ── Event to message conversion (called by TermUI Runtime) ──

  def event_to_msg(event, _state) do
    cond do
      # Quit keys
      is_map(event) && Map.get(event, :char) in ["q", "Q"] ->
        {:msg, :quit}

      is_map(event) && Map.get(event, :key) == :ctrl_c ->
        {:msg, :quit}

      # Printable characters (use char for correct case)
      is_map(event) && is_binary(Map.get(event, :char, "")) && byte_size(Map.get(event, :char, "")) == 1 ->
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
      is_map(event) && is_integer(Map.get(event, :interval, nil)) && Map.get(event, :interval, 0) > 0 ->
        {:msg, :tick}

      # Resize events
      is_map(event) && Map.has_key?(event, :width) && Map.has_key?(event, :height) ->
        {:msg, :resized}

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

  def handle_info(:disable_mouse_tracking, state) do
    TermUI.Terminal.disable_mouse_tracking()
    {state, []}
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

  # ── View ──

  def view(state) do
    model = state.model

    stack(:vertical, [
      styled(text(top_bar_text(model)), top_bar_style()),
      view_content(model),
      styled(text(bottom_bar_text(model)), bottom_bar_style()),
    ])
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

  def update(:resized, state) do
    {state, []}
  end

  def update(:quit, state), do: {state, [:quit]}

  def update(msg, state) do
    result = Spark.TUI.Update.update(state.model, msg)

    case result do
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
        result = cmd.function.()
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

  # ── Top bar ──

  defp top_bar_text(model) do
    phase = model.dashboard[:orchestrator_phase] || "—"
    phase_str = to_string(phase)
    queue = model.dashboard[:queue_length] || 0
    active = model.dashboard[:active_count] || 0
    sid = if model.session_id, do: String.slice(model.session_id, 0, 8), else: "—"

    content = "  Spark v4.0  ▸ #{phase_str}  ⚡ #{active}/#{queue}  Session: #{sid}  "
    String.pad_trailing(content, 240)
  end
  defp top_bar_style do
    Style.new()
    |> Style.fg(:white)
    |> Style.bg(:blue)
    |> Style.bold()
  end

  # ── Bottom bar ──

  defp bottom_bar_text(model) do
    String.pad_trailing("  #{nav_hints(model.screen)}  ", 240)
  end

  defp nav_hints(:home), do: "[A]gents  [P]lan  [D]ashboard  [L]ogs  [?] Help  [Q]uit"
  defp nav_hints(:help), do: "[?] Toggle  [H]ome  [Q]uit"
  defp nav_hints(:agent_manager), do: "↑/↓ Select  [P/C] Quick  [Enter] Models  [H]ome  [Q]uit"
  defp nav_hints(:model_picker), do: "↑/↓ Select  [Enter] Pin  [Esc] Back  [Q]uit"
  defp nav_hints(:dashboard), do: "[R]efresh  [A]gents  [L]ogs  [H]ome  [Q]uit"
  defp nav_hints(:logs), do: "[C]lear  [R]efresh  [D]ashboard  [H]ome  [Q]uit"
  defp nav_hints(:plan_input), do: "[Enter] Submit  [Esc] Cancel  [Q]uit"
  defp nav_hints(:plan_review), do: "[Enter/A]pprove  [R]eject  ↑/↓ Task  [Esc] Home  [Q]uit"
  defp nav_hints(_), do: "[H]ome  [Q]uit"

  defp bottom_bar_style do
    Style.new()
    |> Style.fg(:white)
    |> Style.bg(:blue)
  end

  # ── Content dispatcher ──

  defp view_content(model) do
    case model.screen do
      :home -> render_home(model)
      :help -> render_help()
      :agent_manager -> render_agent_manager(model)
      :model_picker -> render_model_picker(model)
      :dashboard -> render_dashboard(model)
      :logs -> render_logs(model)
      :plan_input -> render_plan_input(model)
      :plan_review -> render_plan_review(model)
      _ -> render_home(model)
    end
  end

  # ── Home screen ──

  defp render_home(model) do
    dash = model.dashboard || %{}
    phase = Map.get(dash, :orchestrator_phase, nil)
    phase_str = if phase, do: to_string(phase), else: "—"
    queue = Map.get(dash, :queue_length, 0)
    active = Map.get(dash, :active_count, 0)
    completed = Map.get(dash, :completed_count, 0)
    failed = Map.get(dash, :failed_count, 0)
    agents = Map.get(dash, :agents, model.agents || %{})
    planning = Map.get(agents, "planning", %{})
    coding = Map.get(agents, "coding", %{})

    stack(:vertical, [
      text(""),
      text("    Spark v4.0 — Parallel Actor-Model Code Agent", Style.new() |> Style.fg(:cyan) |> Style.bold()),
      text(""),
      text("    Status", section_style()),
      text("      Orchestrator: #{phase_str}", Style.new() |> Style.fg(:green)),
      text("      Queue: #{queue} queued, #{active} active  (#{completed} done, #{failed} failed)"),
      text(""),
      text("    Agents", section_style()),
      text("      Planning:  #{Map.get(planning, "model", "—")}  (#{Map.get(planning, "provider", "—")})"),
      text("      Coding:    #{Map.get(coding, "model", "—")}  (#{Map.get(coding, "provider", "—")})"),
      text(""),
      text("    Shortcuts", section_style()),
      text("      A  Agent Manager           P  New Plan"),
      text("      D  Dashboard               L  Event Logs"),
      text("      ?  Help                    Q  Quit"),
      text(""),
      status_or_error(model),
      text(""),
      text("    Ready — press A for agents, P for new plan, Q to quit"),
    ])
  end

  # ── Help screen ──

  defp render_help do
    stack(:vertical, [
      text(""),
      text("    Help — Keyboard Shortcuts", section_style()),
      text(""),
      text("    Navigation", section_style()),
      text("      ?        Toggle help"),
      text("      H / Esc  Home / Back"),
      text("      Q        Quit"),
      text(""),
      text("    Screens", section_style()),
      text("      A  Agent Manager"),
      text("      P  New Plan"),
      text("      D  Dashboard"),
      text("      L  Event Logs"),
      text(""),
      text("    Actions", section_style()),
      text("      ↑/k  Up        ↓/j  Down"),
      text("      Enter  Select / Submit / Pin"),
      text("      A  Approve plan     R  Reject plan"),
      text(""),
      text("    Logs", section_style()),
      text("      C  Clear     R  Refresh"),
    ])
  end

  # ── Agent Manager ──

  defp render_agent_manager(model) do
    agents = ordered_agents(model)
    rows = Enum.with_index(agents) |> Enum.flat_map(fn {{key, cfg}, idx} ->
      selected = idx == model.selected_index
      marker = if selected, do: "▸", else: " "
      fg = if selected, do: :cyan, else: :white
      ks = key_status(cfg)
      [text("  #{marker}  #{pad(key, 10)} #{pad(cfg["actor_type"] || "?", 16)} #{pad(cfg["model"] || "?", 18)} #{pad(cfg["provider"] || "?", 12)} #{ks}",
        Style.new() |> Style.fg(fg) |> maybe_bold(selected))]
    end)

    stack(:vertical, [
      text(""),
      text("    Agent Manager", section_style()),
      text(""),
      text("       Agent         Type               Model                Provider     Key", section_style()),
    ] ++ rows ++ [
      text(""),
      status_or_error(model),
    ])
  end

  # ── Model Picker ──

  defp render_model_picker(model) do
    agent_key = model.selected_agent
    cfg = Map.get(model.agents, agent_key, %{})
    provider = cfg["provider"] || ""
    current = cfg["model"] || ""
    models = Spark.ModelCatalog.models_for_provider(provider)

    model_rows = if models == [] do
      [text("    No models available.", Style.new() |> Style.fg(:yellow))]
    else
      Enum.with_index(models) |> Enum.map(fn {m, idx} ->
        selected = idx == model.selected_model_index
        is_current = m.id == current
        marker = if selected, do: " ▸ ", else: "   "
        tag = if is_current, do: "  [current]", else: ""
        fg = if selected, do: :cyan, else: :white
        name = pad(m.name, 22)
        text("  #{marker}#{name} (#{m.id})#{tag}", Style.new() |> Style.fg(fg) |> maybe_bold(selected))
      end)
    end

    stack(:vertical, [
      text(""),
      text("    Model Picker — #{agent_key}", section_style()),
      text(""),
      text("    Provider: #{provider}    Current: #{current}", Style.new() |> Style.fg(:green) |> Style.bold()),
      text(""),
    ] ++ model_rows ++ [
      text(""),
      error_only(model),
    ])
  end

  # ── Dashboard ──

  defp render_dashboard(model) do
    d = model.dashboard || %{}
    agents = Map.get(d, :agents, %{})
    tasks = Map.get(d, :active_worker_tasks, [])

    worker_rows = if tasks != [] do
      [text(""), text("    Active Workers", section_style())] ++
      Enum.map(tasks, fn name -> text("      ⚡  #{name}", Style.new() |> Style.fg(:cyan)) end)
    else
      []
    end

    agent_rows = if agents == %{} do
      [text("      none configured", Style.new() |> Style.fg(:yellow))]
    else
      agents |> Enum.sort_by(fn {k, _} -> k end) |> Enum.map(fn {key, cfg} ->
        text("      #{key}:  #{cfg["model"] || "—"}  (#{cfg["provider"] || "—"})")
      end)
    end

    stack(:vertical, [
      text(""),
      text("    Dashboard", section_style()),
      text(""),
      text("    Orchestrator", section_style()),
      text("      Phase:          #{d[:orchestrator_phase]}", phase_color_style(d[:orchestrator_phase])),
      text("      Active Plan:    #{fmt(d[:active_plan_id])}  [#{fmt(d[:active_plan_status])}]"),
      text(""),
      text("    Dispatcher", section_style()),
      text("      Queue:    #{d[:queue_length] || 0} queued"),
      text("      Workers:  #{d[:active_count] || 0} / #{d[:max_concurrency] || "—"} active"),
      text("      Done:     #{d[:completed_count] || 0} completed  #{d[:failed_count] || 0} failed"),
    ] ++ worker_rows ++ [
      text(""),
      text("    Agents", section_style()),
    ] ++ agent_rows ++ [
      text(""),
      status_or_error(model),
    ])
  end

  # ── Logs ──

  defp render_logs(model) do
    logs = model.logs || []

    log_rows = if logs == [] do
      [text("    No events captured yet.", Style.new() |> Style.fg(:yellow))]
    else
      Enum.take(logs, 30) |> Enum.map(fn entry ->
        time = if entry.at, do: entry.at |> DateTime.to_time() |> Time.to_string() |> String.slice(0, 8), else: "--:--:--"
        type = Atom.to_string(entry.type) |> String.pad_trailing(24)
        source = Atom.to_string(entry.source)
        id_part = cond do
          entry.task_id -> " task=#{String.slice(entry.task_id, 0, 8)}"
          entry.plan_id -> " plan=#{String.slice(entry.plan_id, 0, 8)}"
          true -> ""
        end
        text("    #{time}  #{type}  #{source}#{id_part}", Style.new() |> Style.fg(log_color(entry.type)))
      end)
    end

    stack(:vertical, [
      text(""),
      text("    Event Logs", section_style()),
      text(""),
    ] ++ log_rows ++ [
      text(""),
      status_or_error(model),
    ])
  end

  # ── Plan Input ──

  defp render_plan_input(model) do
    input_line = if model.loading? do
      [text("    ⏳  Planning with DeepSeek...", Style.new() |> Style.fg(:yellow))]
    else
      [text("    > #{model.input_buffer} ▌", Style.new() |> Style.fg(:green) |> Style.bold())]
    end

    stack(:vertical, [
      text(""),
      text("    New Plan", section_style()),
      text(""),
      text("    What do you want Spark to build?", Style.new() |> Style.fg(:cyan) |> Style.bold()),
      text(""),
    ] ++ input_line ++ [
      text(""),
      error_only(model),
    ])
  end

  # ── Plan Review ──

  defp render_plan_review(model) do
    plan = model.active_plan
    if plan do
      tasks = plan.tasks || []
      sel = model.selected_task_index
      sel_task = Enum.at(tasks, sel)
      task_rows = Enum.with_index(tasks) |> Enum.flat_map(fn {task, idx} ->
        selected = idx == sel
        marker = if selected, do: "  ▸ ", else: "    "
        fg = if selected, do: :cyan, else: :white
        deps_str = join_or_none(task.depends_on)
        reads_str = join_or_none(task.read_paths)
        writes_str = join_or_none(task.write_paths)
        title_line = "#{marker}#{task.id}   #{truncate(task.title, 50)}"
        meta_line = "#{String.slice("                 ", 0, String.length(marker))}Risk: #{task.risk}  |  Deps: #{deps_str}  |  Reads: #{reads_str}  |  Writes: #{writes_str}"
        [text(title_line, Style.new() |> Style.fg(fg) |> maybe_bold(selected)),
         text(meta_line, Style.new() |> Style.fg(fg))]
      end)
      detail_rows = if sel_task do
        [text(""), text("    Details — #{sel_task.id}", section_style()),
         text("      #{truncate(sel_task.title, 50)}", Style.new() |> Style.fg(:cyan) |> Style.bold()),
         text("      #{truncate(sel_task.description, 70)}"),
         text("      Risk: #{sel_task.risk}", risk_style(sel_task.risk)),
         text("      Read:  #{join_or_none(sel_task.read_paths)}"),
         text("      Write: #{join_or_none(sel_task.write_paths)}"),
         text("      Timeout: #{sel_task.timeout_ms}ms  Retries: #{sel_task.max_retries}")]
      else; []
      end
      stack(:vertical, [
        text(""), text("    Plan Review", section_style()), text(""),
        text("    #{plan.user_goal}", Style.new() |> Style.fg(:cyan) |> Style.bold()),
        text("    #{plan.summary}"),
        text("    Status: #{plan.approval_status}", Style.new() |> Style.fg(plan_status_color(plan.approval_status)) |> Style.bold()),
        text(""), text("    Tasks", section_style()),
      ] ++ task_rows ++ [
        text(""),
        text("    ─────────────────────────────────────────", Style.new() |> Style.fg(:black) |> Style.dim()),
      ] ++ detail_rows ++ [text(""), status_or_error(model)])
    else
      stack(:vertical, [
        text(""), text("    No active plan.", Style.new() |> Style.fg(:yellow)), text(""), status_or_error(model)
      ])
    end
  end

  defp truncate(str, max_len) when is_binary(str) and byte_size(str) > max_len do
    String.slice(str, 0, max_len) <> "…"
  end
  defp truncate(str, _max_len) when is_binary(str), do: str
  defp truncate(nil, _max_len), do: ""

  defp join_or_none(list) when is_list(list) and length(list) > 0, do: Enum.join(list, ", ")
  defp join_or_none(_), do: "none"

  # ── Style helpers ──

  defp section_style, do: Style.new() |> Style.fg(:blue) |> Style.bold()
  defp maybe_bold(style, true), do: Style.bold(style)
  defp maybe_bold(style, false), do: style

  defp status_or_error(model) do
    (if model.status_message, do: [text("    #{model.status_message}", Style.new() |> Style.fg(:green))], else: []) ++
    (if model.error_message, do: [text("    #{model.error_message}", Style.new() |> Style.fg(:red))], else: [])
  end

  defp error_only(model) do
    if model.error_message, do: [text("    #{model.error_message}", Style.new() |> Style.fg(:red))], else: []
  end

  defp phase_color_style(:awaiting_input), do: Style.new() |> Style.fg(:white)
  defp phase_color_style(:planning), do: Style.new() |> Style.fg(:cyan)
  defp phase_color_style(:awaiting_approval), do: Style.new() |> Style.fg(:yellow)
  defp phase_color_style(:executing), do: Style.new() |> Style.fg(:green)
  defp phase_color_style(:reviewing), do: Style.new() |> Style.fg(:magenta)
  defp phase_color_style(:completed), do: Style.new() |> Style.fg(:green)
  defp phase_color_style(_), do: Style.new() |> Style.fg(:white)

  defp risk_style(:low), do: Style.new() |> Style.fg(:green)
  defp risk_style(:medium), do: Style.new() |> Style.fg(:yellow)
  defp risk_style(:high), do: Style.new() |> Style.fg(:red)
  defp risk_style(_), do: Style.new() |> Style.fg(:white)

  defp plan_status_color(:awaiting_approval), do: :yellow
  defp plan_status_color(:approved), do: :green
  defp plan_status_color(:rejected), do: :red
  defp plan_status_color(_), do: :white

  defp log_color(type) when type in [:task_completed, :plan_approved, :llm_call_completed], do: :green
  defp log_color(type) when type in [:task_failed, :plan_rejected, :llm_call_failed], do: :red
  defp log_color(type) when type in [:task_started, :plan_awaiting_approval, :task_queued], do: :cyan
  defp log_color(_), do: :white

  # ── Data helpers ──

  defp ordered_agents(model) do
    configured = model.agents || %{}
    preferred = model.agent_order || ["planning", "coding"]
    pref = Enum.filter(preferred, &Map.has_key?(configured, &1)) |> Enum.map(fn k -> {k, Map.fetch!(configured, k)} end)
    extra = Map.drop(configured, preferred) |> Enum.sort_by(fn {k, _} -> k end)
    pref ++ extra
  end

  defp key_status(cfg) do
    case cfg["provider"] do
      "deepseek" -> if secret?(:deepseek_api_key), do: "✅", else: "❌"
      "wafer" -> if secret?(:wafer_api_key), do: "✅", else: "❌"
      _ -> "?"
    end
  end

  defp secret?(key) do
    case Spark.Config.Secrets.get_secret(key) do
      s when is_binary(s) and s != "" -> true
      _ -> false
    end
  rescue _ -> false
  end

  defp pad(str, len) when is_binary(str), do: String.slice(str <> String.duplicate(" ", len), 0, len)
  defp pad(_, len), do: String.duplicate(" ", len)
  defp fmt(nil), do: "—"
  defp fmt(v), do: to_string(v)
  defp gen_id, do: "tui_" <> Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)
end
