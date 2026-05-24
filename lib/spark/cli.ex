defmodule Spark.CLI do
  @moduledoc """
  ⚠️ DEPRECATED: This module is deprecated in favor of Spark.TermUI.
  It will be removed in v5.0.

  Interactive REPL for Spark — command parsing, approval UI,
  parallel dashboard, hot reload, and streaming event display.

  spark-98t.1: CLI command parser
  spark-98t.2: REPL loop
  spark-98t.3: Approval UI
  spark-98t.4: Parallel dashboard
  spark-98t.5: Reload commands + streaming
  """

  alias Spark.Types.Event
  alias Spark.EventBus

  # ── Command struct (spark-98t.1) ────────────────────────────────────

  defmodule Command do
    @moduledoc "Parsed REPL command."
    @type t :: %__MODULE__{type: atom(), args: map()}
    defstruct [:type, args: %{}]
  end

  @slash_cmds %{
    "/plan" => :plan,
    "/code" => :code,
    "/approve" => :approve,
    "/reject" => :reject,
    "/modify" => :modify,
    "/status" => :status,
    "/workers" => :workers,
    "/tasks" => :tasks,
    "/clear" => :clear,
    "/prompt_lab" => :prompt_lab,
    "/refine_prompt" => :refine_prompt,
    "/exit" => :exit,
    "/agent" => :agent
  }

  @reload_targets %{
    "prompts" => :reload_prompts,
    "tools" => :reload_tools,
    "config" => :reload_config,
    "policy" => :reload_policy,
    "guidance" => :reload_guidance,
    "status" => :reload_status
  }

  @doc "Parses a REPL input line into a Command struct or {:error, reason}."
  @spec parse(String.t()) :: {:ok, Command.t()} | {:error, String.t()}
  def parse(""), do: {:ok, %Command{type: :empty}}
  def parse(nil), do: {:ok, %Command{type: :empty}}

  def parse(input) when is_binary(input) do
    input = String.trim(input)

    cond do
      input == "" ->
        {:ok, %Command{type: :empty}}

      String.starts_with?(input, "!") ->
        {:ok, %Command{type: :shell, args: %{command: String.slice(input, 1..-1//1)}}}

      String.starts_with?(input, "/") ->
        parse_slash(input)

      true ->
        case suggest_slash_command(input) do
          {:ok, suggestion} ->
            {:error, "Unknown command. Did you mean #{suggestion}? " <> help_text()}

          :none ->
            {:ok, %Command{type: :plan, args: %{goal: input}}}
        end
    end
  end

  defp parse_slash(input) do
    parts = String.split(input, ~r/\s+/, parts: 2)
    cmd = hd(parts)
    arg = Enum.at(parts, 1, "")

    case Map.get(@slash_cmds, cmd) do
      nil when cmd == "/reload" ->
        parse_reload(arg)

      nil ->
        {:error, "Unknown command: #{cmd}. " <> help_text()}

      type when type in [:plan, :code] ->
        {:ok, %Command{type: type, args: %{goal: arg}}}

      :modify ->
        {:ok, %Command{type: :modify, args: %{instruction: arg}}}

      :prompt_lab ->
        {:ok, %Command{type: :prompt_lab, args: %{log_file: arg}}}

      type ->
        {:ok, %Command{type: type, args: %{}}}
    end
  end

  defp parse_reload(""), do: {:ok, %Command{type: :reload_all, args: %{}}}

  defp parse_reload(arg) do
    case Map.get(@reload_targets, arg) do
      nil ->
        {:error,
         "Unknown reload target: #{arg}. Use: prompts, tools, config, policy, guidance, status"}

      type ->
        {:ok, %Command{type: type, args: %{}}}
    end
  end

  defp suggest_slash_command(input) do
    first_word = input |> String.split(~r/\s+/, parts: 2) |> hd()

    case Map.get(@slash_cmds, "/" <> first_word) do
      nil -> :none
      _type -> {:ok, "/" <> first_word}
    end
  end

  defp help_text,
    do:
      "Available: /plan, /code, /approve, /reject, /modify, /status, /workers, /tasks, /reload [prompts|tools|config|policy|guidance|status], /prompt_lab, /refine_prompt, /agent, /clear, /exit, !<shell cmd>"

  # ── REPL state & start (spark-98t.2) ────────────────────────────────

  defstruct active_plan: nil, session_id: nil, approval_mode: false
  @type state :: %__MODULE__{}

  @doc "Starts the REPL as a linked process."
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts \\ []) do
    pid =
      spawn_link(fn ->
        init_subscriptions()
        state = %__MODULE__{session_id: Keyword.get(opts, :session_id, gen_id())}
        banner()
        repl_loop(state)
      end)

    {:ok, pid}
  end

  # keep existing

  defp init_subscriptions do
    try do
      EventBus.subscribe("spark:events")
      EventBus.subscribe("spark:hot_reload")
    rescue
      _ -> :ok
    end
  end

  defp banner do
    IO.puts(
      IO.ANSI.yellow() <>
        "⚠️  Spark.CLI is deprecated. Use Spark.TermUI instead." <> IO.ANSI.reset()
    )

    IO.puts(IO.ANSI.cyan() <> "🔮 Spark v4.0 — Parallel Actor-Model Code Agent" <> IO.ANSI.reset())

    IO.puts(
      "Type your goal to start planning, /agent for model manager, /status for dashboard, /exit to quit.\n"
    )
  end

  defp repl_loop(%__MODULE__{} = state) do
    state = flush_events(state)
    prompt = if state.approval_mode, do: "spark [A/R/M/D]> ", else: "spark> "

    case IO.gets(prompt) do
      :eof ->
        IO.puts("\nBye! 🐶")

      {:error, _} ->
        :ok

      nil ->
        :ok

      line ->
        case handle_input(String.trim(line), state) do
          :exit -> :ok
          new_state -> repl_loop(new_state)
        end
    end
  end

  defp repl_loop(_), do: :ok

  defp handle_input("", state), do: state

  defp handle_input(input, %{approval_mode: true} = state) do
    case String.upcase(input) do
      "A" ->
        dispatch(%Command{type: :approve}, %{state | approval_mode: false})

      "R" ->
        dispatch(%Command{type: :reject}, %{state | approval_mode: false})

      "D" ->
        if state.active_plan, do: render_plan_details(state.active_plan)
        render_approval_prompt()
        state

      "M" ->
        IO.write("Modification instruction: ")
        instr = String.trim(IO.gets("") || "")

        dispatch(%Command{type: :modify, args: %{instruction: instr}}, %{
          state
          | approval_mode: false
        })

      _ ->
        case parse(input) do
          {:ok, %Command{type: :empty}} ->
            state

          {:ok, %Command{type: :exit} = cmd} ->
            dispatch(cmd, state)

          {:ok, cmd} ->
            dispatch(cmd, %{state | approval_mode: false})

          {:error, reason} ->
            IO.puts(IO.ANSI.red() <> "❌ #{reason}" <> IO.ANSI.reset())
            state
        end
    end
  end

  defp handle_input(input, state) do
    case parse(input) do
      {:ok, %Command{type: :empty}} ->
        state

      {:ok, cmd} ->
        dispatch(cmd, state)

      {:error, reason} ->
        IO.puts(IO.ANSI.red() <> "❌ #{reason}" <> IO.ANSI.reset())
        state
    end
  end

  # ── Command dispatch (spark-98t.2 + 98t.3 + 98t.5) ──────────────────

  defp dispatch(%Command{type: :exit}, _state) do
    IO.puts("Goodbye! 🐶")
    :exit
  end

  defp dispatch(%Command{type: type, args: %{goal: ""}}, state) when type in [:plan, :code] do
    IO.puts(IO.ANSI.yellow() <> "⚠ Usage: /#{type} <goal>" <> IO.ANSI.reset())
    state
  end

  defp dispatch(%Command{type: type, args: %{goal: goal}}, state) when type in [:plan, :code] do
    IO.puts(IO.ANSI.cyan() <> "📋 Sending to Orchestrator..." <> IO.ANSI.reset())

    case safe_call(fn -> Spark.Orchestrator.run(goal) end) do
      {:ok, plan} ->
        state = %{state | active_plan: plan, approval_mode: true}
        render_plan_summary(plan)
        render_approval_prompt()
        state

      {:error, {:invalid_phase, phase}} ->
        IO.puts(IO.ANSI.yellow() <> "⚠ Orchestrator busy (phase: #{phase})" <> IO.ANSI.reset())
        state

      {:error, reason} ->
        IO.puts(IO.ANSI.red() <> "❌ Planning failed: #{sanitize(reason)}" <> IO.ANSI.reset())
        state
    end
  end

  defp dispatch(%Command{type: :approve}, %{active_plan: nil} = state) do
    IO.puts(IO.ANSI.yellow() <> "⚠ No plan awaiting approval" <> IO.ANSI.reset())
    state
  end

  defp dispatch(%Command{type: :approve}, %{active_plan: plan} = state) do
    case safe_call(fn -> Spark.Orchestrator.approve_plan(plan.id) end) do
      {:ok, approved} ->
        IO.puts(IO.ANSI.green() <> "✅ Plan approved! Handing off to Coding Agent..." <> IO.ANSI.reset())
        streaming_loop(%{state | active_plan: approved, approval_mode: false})

      {:error, reason} ->
        IO.puts(IO.ANSI.red() <> "❌ Approve failed: #{sanitize(reason)}" <> IO.ANSI.reset())
        state
    end
  end

  defp dispatch(%Command{type: :reject}, %{active_plan: nil} = state) do
    IO.puts(IO.ANSI.yellow() <> "⚠ No plan awaiting approval" <> IO.ANSI.reset())
    state
  end

  defp dispatch(%Command{type: :reject}, %{active_plan: plan} = state) do
    case safe_call(fn -> Spark.Orchestrator.reject_plan(plan.id) end) do
      {:ok, _} ->
        IO.puts(IO.ANSI.red() <> "🚫 Plan rejected" <> IO.ANSI.reset())
        %{state | active_plan: nil, approval_mode: false}

      {:error, reason} ->
        IO.puts(IO.ANSI.red() <> "❌ Reject failed: #{sanitize(reason)}" <> IO.ANSI.reset())
        state
    end
  end

  defp dispatch(%Command{type: :modify, args: %{instruction: ""}}, state) do
    IO.puts(IO.ANSI.yellow() <> "⚠ Usage: /modify <instruction>" <> IO.ANSI.reset())
    state
  end

  defp dispatch(
         %Command{type: :modify, args: %{instruction: instr}},
         %{active_plan: plan} = state
       ) do
    case safe_call(fn -> Spark.Orchestrator.modify_plan(plan.id, instr) end) do
      {:ok, new_plan} ->
        IO.puts(IO.ANSI.cyan() <> "📝 Plan modified" <> IO.ANSI.reset())
        state = %{state | active_plan: new_plan, approval_mode: true}
        render_plan_summary(new_plan)
        render_approval_prompt()
        state

      {:error, reason} ->
        IO.puts(IO.ANSI.red() <> "❌ Modify failed: #{sanitize(reason)}" <> IO.ANSI.reset())
        state
    end
  end

  defp dispatch(%Command{type: :status}, state) do
    render_dashboard(state)
    state
  end

  defp dispatch(%Command{type: :workers}, state) do
    render_workers()
    state
  end

  defp dispatch(%Command{type: :tasks}, state) do
    render_tasks(state)
    state
  end

  defp dispatch(%Command{type: :shell, args: %{command: cmd}}, state) do
    {out, exit_code} =
      try do
        System.cmd("sh", ["-c", cmd], stderr_to_stdout: true, timeout: 15_000)
      rescue
        ErlangError ->
          IO.puts(IO.ANSI.red() <> "Command timed out after 15s" <> IO.ANSI.reset())
          {"", 1}
      end

    case exit_code do
      0 -> IO.puts(out)
      _ -> unless out == "", do: IO.puts(IO.ANSI.red() <> out <> IO.ANSI.reset())
    end

    state
  rescue
    e ->
      IO.puts(IO.ANSI.red() <> "Shell error: #{Exception.message(e)}" <> IO.ANSI.reset())
      state
  end

  defp dispatch(%Command{type: :clear}, state) do
    IO.write("\e[2J\e[H")
    state
  end

  defp dispatch(%Command{type: rt, args: _}, state)
       when rt in [
              :reload_all,
              :reload_prompts,
              :reload_tools,
              :reload_config,
              :reload_policy,
              :reload_guidance,
              :reload_status
            ] do
    handle_reload(rt, state)
  end

  defp dispatch(%Command{type: :prompt_lab, args: %{log_file: ""}}, state) do
    IO.puts(IO.ANSI.yellow() <> "⚠ Usage: /prompt_lab <log_file>" <> IO.ANSI.reset())
    state
  end

  defp dispatch(%Command{type: :prompt_lab, args: %{log_file: lf}}, state) do
    IO.puts(IO.ANSI.cyan() <> "🧪 Running PromptLab on #{lf}..." <> IO.ANSI.reset())

    case find_prompt_file() do
      nil ->
        IO.puts(IO.ANSI.red() <> "❌ No prompt file found in ~/.spark/prompts/" <> IO.ANSI.reset())

      pf ->
        case safe_call(fn -> Spark.PromptLab.run(lf, pf) end) do
          {:ok, report} ->
            render_lab_report(report)

          {:error, r} ->
            IO.puts(IO.ANSI.red() <> "❌ PromptLab failed: #{sanitize(r)}" <> IO.ANSI.reset())
        end
    end

    state
  end

  defp dispatch(%Command{type: :refine_prompt}, state) do
    IO.puts(IO.ANSI.cyan() <> "🔬 Refining prompt..." <> IO.ANSI.reset())
    sid = state.session_id || "unknown"

    case safe_call(fn -> Spark.PromptRefiner.refine(sid, :orchestrator, mock_llm: true) end) do
      {:ok, ref} ->
        render_refinement(ref)

      {:error, r} ->
        IO.puts(IO.ANSI.red() <> "❌ Refinement failed: #{sanitize(r)}" <> IO.ANSI.reset())
    end

    state
  end

  defp dispatch(%Command{type: :agent}, state) do
    render_agent_menu()
    state
  end

  # ── Agent Manager Menu ──────────────────────────────────────────────

  defp render_agent_menu do
    agents = safe_fetch(fn -> Spark.AgentManager.list_agents() end, %{})

    IO.puts(
      "\n" <> IO.ANSI.bright() <> IO.ANSI.cyan() <> "═══ Agent Manager ═══" <> IO.ANSI.reset()
    )

    planning = Map.get(agents, "planning", %{})
    coding = Map.get(agents, "coding", %{})

    IO.puts("  [P]lanning Agent → #{agent_display(planning)}")
    IO.puts("  [C]oding Agent    → #{agent_display(coding)}")
    IO.puts("  [Q]uit\n")

    IO.write("Select agent [P/C/Q]: ")

    case String.upcase(String.trim(IO.gets("") || "")) do
      "P" -> render_model_picker("planning", planning)
      "C" -> render_model_picker("coding", coding)
      "Q" -> :ok
      _ -> IO.puts(IO.ANSI.yellow() <> "  Cancelled" <> IO.ANSI.reset())
    end
  end

  defp render_model_picker(agent_key, agent) do
    provider = agent["provider"] || "unknown"
    current_model = agent["model"] || "unknown"
    models = Spark.ModelCatalog.models_for_provider(provider)

    if models == [] do
      IO.puts(
        IO.ANSI.yellow() <> "  No models available for provider: #{provider}" <> IO.ANSI.reset()
      )

      return()
    end

    label = if agent_key == "planning", do: "Planning Agent", else: "Coding Agent"

    IO.puts(
      "\n" <>
        IO.ANSI.bright() <>
        IO.ANSI.cyan() <> "═══ Select Model for #{label} ═══" <> IO.ANSI.reset()
    )

    models
    |> Enum.with_index(1)
    |> Enum.each(fn {%{id: id, name: name}, idx} ->
      marker = if id == current_model, do: "← current", else: ""
      IO.puts("  #{idx}. #{name} (#{id}) #{IO.ANSI.green()}#{marker}#{IO.ANSI.reset()}")
    end)

    IO.write("\nEnter number (or Enter to keep current): ")
    input = String.trim(IO.gets("") || "")

    if input == "" do
      IO.puts("  Keeping current model: #{current_model}")
      return()
    end

    case Integer.parse(input) do
      {num, ""} when num >= 1 and num <= length(models) ->
        chosen = Enum.at(models, num - 1)

        case Spark.AgentManager.pin_model(agent_key, chosen.id) do
          {:ok, _agent} ->
            IO.puts(
              IO.ANSI.green() <>
                "\n✅ #{label} pinned to #{chosen.name} (#{chosen.id})" <> IO.ANSI.reset()
            )

          {:error, reason} ->
            IO.puts(IO.ANSI.red() <> "\n❌ Failed: #{sanitize(reason)}" <> IO.ANSI.reset())
        end

      _ ->
        IO.puts(
          IO.ANSI.yellow() <> "  Invalid selection, keeping current model" <> IO.ANSI.reset()
        )
    end
  end

  defp agent_display(agent) do
    model = agent["model"] || "unknown"
    provider = agent["provider"] || "unknown"
    "#{model} (#{provider_label(provider)}, #{api_key_status(provider)})"
  end

  defp provider_label("deepseek"), do: "DeepSeek"
  defp provider_label("wafer"), do: "Wafer AI"
  defp provider_label(provider) when is_binary(provider), do: String.capitalize(provider)
  defp provider_label(_), do: "Unknown"

  defp api_key_status(provider) when is_binary(provider) do
    key = :"#{provider}_api_key"

    case Spark.Config.Secrets.get_secret(key) || fallback_api_key(provider) do
      secret when is_binary(secret) and secret != "" -> "key ✅"
      _ -> "key missing ❌"
    end
  end

  defp api_key_status(_), do: "key missing ❌"

  defp fallback_api_key("wafer"), do: Spark.Config.Secrets.get_secret(:wafer_api_key)
  defp fallback_api_key(_), do: nil

  defp return, do: :ok

  # ── Approval UI (spark-98t.3) ────────────────────────────────────────

  defp render_plan_summary(plan) do
    IO.puts(
      "\n" <> IO.ANSI.bright() <> IO.ANSI.cyan() <> "═══ Plan Summary ═══" <> IO.ANSI.reset()
    )

    IO.puts("  Goal:     #{plan.user_goal}")
    IO.puts("  Summary:  #{plan.summary}")
    IO.puts("  Status:   #{plan.approval_status}\n")
    IO.puts(IO.ANSI.bright() <> "  Tasks:" <> IO.ANSI.reset())

    Enum.each(plan.tasks, fn t ->
      IO.puts("    #{t.id}: #{t.title}")

      IO.puts(
        "      Risk: #{risk_ansi(t.risk)}#{t.risk}#{IO.ANSI.reset()} | " <>
          "Deps: #{inspect(t.depends_on)} | " <>
          "Read: #{inspect(t.read_paths)} | Write: #{inspect(t.write_paths)}"
      )
    end)

    indep = Enum.count(plan.tasks, &(&1.depends_on == []))
    IO.puts("\n  Parallelism: #{indep} independent task(s)\n")
  end

  defp render_approval_prompt do
    IO.puts(IO.ANSI.bright() <> "[A]pprove / [R]eject / [M]odify / [D]etails" <> IO.ANSI.reset())
  end

  defp render_plan_details(plan) do
    IO.puts(
      "\n" <>
        IO.ANSI.bright() <> IO.ANSI.cyan() <> "═══ Full Task Contracts ═══" <> IO.ANSI.reset()
    )

    Enum.each(plan.tasks, fn t ->
      IO.puts("\n  " <> IO.ANSI.bright() <> "Task: #{t.id} — #{t.title}" <> IO.ANSI.reset())
      IO.puts("    Description:  #{t.description}")
      IO.puts("    Risk: #{t.risk} | Deps: #{inspect(t.depends_on)}")
      IO.puts("    Read: #{inspect(t.read_paths)} | Write: #{inspect(t.write_paths)}")
      IO.puts("    Status: #{t.status} | Retries: #{t.max_retries} | Timeout: #{t.timeout_ms}ms")
    end)

    IO.puts("")
  end

  # ── Parallel Dashboard (spark-98t.4) ─────────────────────────────────

  defp render_dashboard(state) do
    IO.puts(
      "\n" <> IO.ANSI.bright() <> IO.ANSI.cyan() <> "═══ Spark Dashboard ═══" <> IO.ANSI.reset()
    )

    phase = safe_orchestrator_phase()
    ds = safe_dispatcher_status()
    reload = safe_last_reload()
    pver = safe_prompt_version()
    IO.puts("  Session:        #{state.session_id || "—"}")
    IO.puts("  Orchestrator:   #{phase_ansi(phase)}#{phase || "—"}#{IO.ANSI.reset()}")
    IO.puts("  Queue depth:    #{Map.get(ds, :queue_length, "—")}")
    IO.puts("  Active workers: #{Map.get(ds, :active_count, "—")}")
    for name <- safe_worker_task_names(), do: IO.puts("    • #{name}")
    IO.puts("  Completed:      #{Map.get(ds, :completed_count, "—")}")
    IO.puts("  Failed:         #{Map.get(ds, :failed_count, "—")}")
    IO.puts("  Last reload:    #{fmt_reload(reload)}")
    IO.puts("  Prompt ver:     #{pver}\n")
  end

  defp render_workers do
    ds = safe_dispatcher_status()
    IO.puts("\n" <> IO.ANSI.bright() <> IO.ANSI.cyan() <> "═══ Workers ═══" <> IO.ANSI.reset())

    IO.puts(
      "  Active: #{Map.get(ds, :active_count, 0)} / Max: #{Map.get(ds, :max_concurrency, "—")}"
    )

    case safe_worker_task_names() do
      [] -> IO.puts("  No active workers")
      names -> Enum.each(names, &IO.puts("    🔧 #{&1}"))
    end

    IO.puts("")
  end

  defp render_tasks(state) do
    ds = safe_dispatcher_status()
    IO.puts("\n" <> IO.ANSI.bright() <> IO.ANSI.cyan() <> "═══ Tasks ═══" <> IO.ANSI.reset())

    IO.puts(
      "  Queued: #{Map.get(ds, :queue_length, 0)} | Completed: #{Map.get(ds, :completed_count, 0)} | Failed: #{Map.get(ds, :failed_count, 0)}"
    )

    if state.active_plan do
      Enum.each(state.active_plan.tasks, &IO.puts("    #{&1.id}: #{&1.title} [#{&1.status}]"))
    else
      IO.puts("  No active plan")
    end

    IO.puts("")
  end

  # ── Reload commands (spark-98t.5) ────────────────────────────────────

  @reload_types [:prompts, :tools, :config, :policy, :guidance]

  defp handle_reload(:reload_all, state) do
    IO.puts(IO.ANSI.cyan() <> "🔄 Reloading all..." <> IO.ANSI.reset())
    render_reload_results(for t <- @reload_types, do: {t, do_reload(t)})
    state
  end

  defp handle_reload(type, state)
       when type in [
              :reload_prompts,
              :reload_tools,
              :reload_config,
              :reload_policy,
              :reload_guidance
            ] do
    target = type |> Atom.to_string() |> String.replace_prefix("reload_", "") |> String.to_atom()
    IO.puts(IO.ANSI.cyan() <> "🔄 Reloading #{target}..." <> IO.ANSI.reset())
    render_reload_results([{target, do_reload(target)}])
    state
  end

  defp handle_reload(:reload_status, state) do
    IO.puts(
      "\n" <> IO.ANSI.bright() <> IO.ANSI.cyan() <> "═══ Reload Status ═══" <> IO.ANSI.reset()
    )

    case safe_coordinator_status() do
      nil ->
        IO.puts("  Coordinator not available")

      s ->
        IO.puts("  Status: #{s.status} | Reload count: #{s.reload_count}")

        if lr = s.last_reload do
          IO.puts("  Last: #{lr.type} — #{lr.status} (#{fmt_ts(lr.timestamp)})")
          if lr.error, do: IO.puts("  Error: #{inspect(lr.error)}")
        end
    end

    for e <- safe_manifest_entries(),
        do: IO.puts("    #{e.component}:#{e.name} — v#{e.version} (#{e.status})")

    IO.puts("")
    state
  end

  defp do_reload(type), do: safe_call(fn -> Spark.HotReload.Coordinator.reload(type) end)

  defp render_reload_results(results) do
    Enum.each(results, fn
      {t, {:ok, %{status: :success}}} -> IO.puts("  ✅ #{t}: OK")
      {t, {:ok, %{status: :failed, error: err}}} -> IO.puts("  ❌ #{t}: FAILED — #{inspect(err)}")
      {t, {:error, reason}} -> IO.puts("  ❌ #{t}: #{sanitize(reason)}")
    end)
  end

  # ── Streaming (spark-98t.5) ──────────────────────────────────────────

  @stream_types [:task_started, :task_completed, :task_failed, :task_queued, :task_retried]
  @reload_events [
    :prompt_reloaded,
    :tool_reloaded,
    :config_reloaded,
    :policy_reloaded,
    :guidance_reloaded
  ]

  defp streaming_loop(state) do
    receive do
      %Event{type: type, payload: p} when type in @stream_types ->
        display_stream_event(type, p)
        streaming_loop(state)

      %Event{type: :orchestrator_review_completed, payload: p} ->
        review = p[:review] || p["review"] || ""
        IO.puts("  📝 Review: #{String.slice(to_string(review), 0, 200)}")
        IO.puts(IO.ANSI.green() <> "\n✅ Execution complete!" <> IO.ANSI.reset())
        %{state | active_plan: nil, approval_mode: false}

      %Event{type: :plan_approved} ->
        IO.puts(IO.ANSI.green() <> "📋 Plan approved — execution starting" <> IO.ANSI.reset())
        streaming_loop(state)

      %Event{type: type} when type in @reload_events ->
        IO.puts(IO.ANSI.cyan() <> "🔄 Hot reload: #{type}" <> IO.ANSI.reset())
        streaming_loop(state)

      %Event{} ->
        streaming_loop(state)
    after
      30_000 ->
        case safe_orchestrator_phase() do
          p when p in [:completed, :awaiting_input] ->
            IO.puts(IO.ANSI.green() <> "\n✅ Execution complete!" <> IO.ANSI.reset())
            %{state | active_plan: nil, approval_mode: false}

          _ ->
            streaming_loop(state)
        end
    end
  end

  @stream_icons [
    task_started: "🚀",
    task_completed: "✅",
    task_failed: "❌",
    task_queued: "📋",
    task_retried: "🔁"
  ]
  @stream_labels [
    task_started: "Started",
    task_completed: "Completed",
    task_failed: "Failed",
    task_queued: "Queued",
    task_retried: "Retried"
  ]

  defp display_stream_event(type, p) do
    tid = p[:task_id] || p["task_id"] || "?"
    icon = Map.get(@stream_icons, type, "ℹ️")
    label = Map.get(@stream_labels, type, Atom.to_string(type))
    extra = if type == :task_failed, do: " (#{p[:reason] || p["reason"] || "?"})", else: ""
    IO.puts("  #{icon} #{label}: #{tid}#{extra}")
  end

  # ── Event flushing between prompts ───────────────────────────────────

  defp flush_events(state) do
    receive do
      %Event{type: :plan_awaiting_approval} ->
        case safe_orchestrator_state() do
          %{active_plan: %{} = plan} ->
            render_plan_summary(plan)
            render_approval_prompt()
            flush_events(%{state | active_plan: plan, approval_mode: true})

          _ ->
            flush_events(state)
        end

      %Event{type: type, payload: p} when type in @stream_types ->
        display_stream_event(type, p)
        flush_events(state)

      %Event{} ->
        flush_events(state)
    after
      0 -> state
    end
  end

  # ── Safe wrappers (never crash the REPL) ─────────────────────────────

  defp safe_call(fun) do
    fun.()
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, reason -> {:error, "Process exit: #{inspect(reason)}"}
  end

  defp safe_orchestrator_phase, do: safe_fetch(fn -> Spark.Orchestrator.get_state().phase end)
  defp safe_orchestrator_state, do: safe_fetch(fn -> Spark.Orchestrator.get_state() end)
  defp safe_dispatcher_status, do: safe_fetch(fn -> Spark.Dispatcher.status() end, %{})

  defp safe_prompt_version,
    do: safe_fetch(fn -> Spark.Orchestrator.get_state().prompt_version end, "unknown")

  defp safe_last_reload,
    do: safe_fetch(fn -> Spark.HotReload.Coordinator.status().last_reload end)

  defp safe_coordinator_status, do: safe_fetch(fn -> Spark.HotReload.Coordinator.status() end)

  defp safe_worker_task_names do
    safe_fetch(
      fn ->
        :sys.get_state(Spark.Dispatcher).active_workers
        |> Map.values()
        |> Enum.map(& &1.task.title)
      end,
      []
    )
  end

  defp safe_manifest_entries, do: safe_fetch(fn -> Spark.HotReload.Manifest.list() end, [])

  defp safe_fetch(fun, default \\ nil) do
    case safe_call(fun) do
      {:ok, val} -> val
      {:ok, val, _} -> val
      {:error, _} -> default
      val -> val
    end
  end

  # ── Renderers ────────────────────────────────────────────────────────

  defp render_lab_report(r) do
    IO.puts(IO.ANSI.bright() <> IO.ANSI.cyan() <> "═══ PromptLab Report ═══" <> IO.ANSI.reset())
    IO.puts("  Log: #{r.log_file} | Prompt: #{r.prompt_file}")

    IO.puts(
      "  Tool calls: #{r.tool_call_count} | Failures: #{r.failure_count} | Retries: #{r.retry_count}"
    )

    IO.puts("  Token est: #{r.token_estimate} | Policy violations: #{r.policy_violations}")
    if r.notes != [], do: Enum.each(r.notes, &IO.puts("    • #{&1}"))
    IO.puts("")
  end

  defp render_refinement(r) do
    IO.puts(IO.ANSI.bright() <> IO.ANSI.cyan() <> "═══ Prompt Refinement ═══" <> IO.ANSI.reset())
    IO.puts("  Current: #{r.current_version} → Candidate: #{r.candidate_version}")
    IO.puts("  Recommendation: #{r.recommendation}")
    IO.puts("  Analysis: #{String.slice(r.analysis, 0, 300)}")
    Enum.each(r.suggestions, &IO.puts("    • #{&1}"))
    IO.puts("")
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  defp find_prompt_file do
    dir = Path.join(Spark.Config.home_dir(), "prompts")
    if File.dir?(dir), do: Path.wildcard(Path.join(dir, "*.md")) |> List.first()
  end

  defp sanitize(r) when is_binary(r), do: redact_secrets(r)
  defp sanitize(r) when is_atom(r), do: Atom.to_string(r)
  defp sanitize({:plan_validation, e}), do: "Plan validation: #{inspect(e)}"
  defp sanitize({:plan_parse, r}), do: "Plan parse: #{inspect(r)}"
  defp sanitize({:llm_error, r}), do: "LLM error: #{sanitize(r)}"
  defp sanitize({:invalid_phase, p}), do: "Invalid phase: #{p}"
  defp sanitize(other), do: inspect(other)

  @secret_patterns [
    ~r/(api[_-]?key["\s:=]+)["']?[\w\-]{8,}["']?/i,
    ~r/(token["\s:=]+)["']?[\w\-]{8,}["']?/i,
    ~r/(secret["\s:=]+)["']?[\w\-]{8,}["']?/i,
    ~r/(password["\s:=]+)["']?[\w\-]{8,}["']?/i
  ]
  defp redact_secrets(text) when is_binary(text) do
    Enum.reduce(@secret_patterns, text, &Regex.replace(&1, &2, "\\1[REDACTED]"))
  end

  defp risk_ansi(:low), do: IO.ANSI.green()
  defp risk_ansi(:medium), do: IO.ANSI.yellow()
  defp risk_ansi(:high), do: IO.ANSI.red()
  defp risk_ansi(_), do: IO.ANSI.reset()

  defp phase_ansi(:awaiting_input), do: IO.ANSI.green()
  defp phase_ansi(:planning), do: IO.ANSI.cyan()
  defp phase_ansi(:awaiting_approval), do: IO.ANSI.yellow()
  defp phase_ansi(:executing), do: IO.ANSI.blue()
  defp phase_ansi(:reviewing), do: IO.ANSI.magenta()
  defp phase_ansi(:completed), do: IO.ANSI.green()
  defp phase_ansi(_), do: IO.ANSI.reset()

  defp fmt_ts(nil), do: "—"
  defp fmt_ts(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp fmt_ts(other), do: inspect(other)

  defp fmt_reload(nil), do: "—"
  defp fmt_reload(r), do: "#{r.type} — #{r.status} (#{fmt_ts(r.timestamp)})"

  defp gen_id, do: "cli_" <> Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)
end
