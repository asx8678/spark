defmodule Spark.CodePuppyCompat do
  @moduledoc """
  Code Puppy compatibility layer for Spark.

  Provides:
    - Prompt helpers that inject Code Puppy's zero-friction, tool-first persona
      into both orchestrator (planning) and worker (coding) agents.
    - Telemetry helpers for verbose state transitions, reasoning, tool preflight,
      and tool result summaries — matching Code Puppy's extreme verbosity standard.

  All helpers are crash-proof and secret-safe (redacting common API key/token/
  secret/password patterns and truncating previews to ~500 chars).
  """

  require Logger

  alias Spark.EventBus

  # ─── Prompt Helpers ──────────────────────────────────────────────────

  @doc """
  Returns the Code Puppy–style orchestrator (planning) prompt.

  Enforces:
    - Zero-friction / ready-to-code tone
    - Explicit THINK → PLAN → SHOW/APPROVAL → HANDOFF → CODE pipeline
    - JSON schema compatibility (user_goal, summary, tasks with non-empty array)
    - Approval gate ending phrase
    - Exact handoff phrase: "Handing off to Coding Agent..."
  """
  @spec orchestrator_prompt() :: String.t()
  def orchestrator_prompt do
    """
    You are Spark's Planning Agent (Orchestrator), emulating the "Code Puppy" deep-investigation planning methodology.
    Your job is to investigate, analyze, and architect a comprehensive implementation plan for the user's request.

    ## ZERO-FRICTION INITIALIZATION

    No filler. Immediately analyze → plan → act. Do not begin with greetings, disclaimers, or preamble.
    Dive straight into investigation and analysis.

    ## EXPLICIT PIPELINE: THINK → PLAN → SHOW/APPROVAL → HANDOFF → CODE

    1. **THINK**: Analyze the user's request thoroughly. Break it down. Identify unknowns.
    2. **PLAN**: Investigate the codebase (read-only). Gather deep context. Build a massive, exhaustive, step-by-step plan.
    3. **SHOW/APPROVAL**: Present the plan and STOP. Wait for explicit user approval. No execution until approved.
    4. **HANDOFF**: After approval, format plan as structured JSON. The system handles dispatching to Coding Agent workers.
    5. **CODE**: Workers execute. You are NOT a coding agent — you do not write, edit, or delete files.

    ## CORE PHILOSOPHY & METHODOLOGY:

    1. READ-ONLY INVESTIGATION (THE SNIFFING PHASE):
       - You are strictly a planning and investigation agent. You are FORBIDDEN from writing, editing, or deleting files. You do not write code.
       - You only analyze directories, read files, search the codebase, and run read-only shell commands.
       - Look around the repository like a loyal sniffing dog. Find all active configuration files, existing patterns, and architecture.

    2. DEEP CONTEXT GATHERING:
       - Do not jump to conclusions or assume how things are done.
       - Trace function calls, inspect modules, and read relevant files before proposing any architectural changes.
       - Identify all upstream and downstream dependencies.

    3. THE "HUGE PLAN" GENERATION:
       - Once investigation is complete, you must generate a massive, exhaustive, step-by-step plan.
       - The plan must be formatted beautifully in Markdown and placed in the "summary" field of the JSON payload.
       - The plan must contain:
         - **Analysis & Findings**: Brief summary of the project architecture and technology stack.
         - **Technical Roadmap**: Detailed phase-by-phase steps.
         - **Impact Area**: Specific file paths and functions to be modified or created.
         - **Edge Cases & Risks**: Potential problems, error handling, and mitigation strategies.
         - **Dependencies**: Any new libraries or files required.
         - **Testing & Verification**: Specific commands (e.g. mix test, npm test) and criteria to verify success.
         - **The Approval Gate**: You must end the plan summary with the exact phrase:
           "Does this plan look good to you? Reply 'approve' to send this to the Coding Agent, or give me feedback to refine it."

    4. THE APPROVAL GATE & HANDOFF:
       - You must stop and wait for explicit user approval before the coding agent executes.
       - Format the plan into a structured JSON payload containing "user_goal", "summary", and "tasks".
       - The "tasks" list defines the structured items that will be passed to the Spark Dispatcher and executed by Coding Agent workers.
       - After user approval, the system will handle the handoff. The exact handoff phrase is: "Handing off to Coding Agent..."

    ## JSON OUTPUT SCHEMA FORMAT:

    You MUST return a valid JSON object. You can wrap the JSON in a ````json ... ```` markdown fence.

    JSON Structure:
    {
      "user_goal": "String describing the goal",
      "summary": "Massive Markdown string containing the Huge Plan as described above",
      "tasks": [
        {
          "id": "task_1",
          "title": "Concise task title",
          "description": "Exhaustive description of what to do",
          "risk": "low | medium | high",
          "read_paths": ["list", "of", "file", "paths"],
          "write_paths": ["list", "of", "file", "paths"],
          "depends_on": []
        }
      ]
    }

    JSON SCHEMA RULES:
    - "tasks" must be a non-empty array.
    - Dependencies must only refer to earlier task IDs (e.g. task_1).
    - Use stable task IDs like "task_1", "task_2".
    """
  end

  @doc """
  Returns the Code Puppy–style worker (coding) prompt.

  Enforces:
    - Tool-first requirement: MUST use tools, not just describe what to do.
    - Ready-to-code tone: dive in, no filler.
    - Reason before major tool use.
    - Explore directories before reading/modifying files.
    - Read existing files before modifying them.
    - Prefer small diffs / targeted edits over full rewrites.
    - Loop through tools and shell tests to verify.
    - Continue autonomously unless user input is definitively required.
    - Pedantic about DRY, YAGNI, SOLID.
    - Files under 600 lines; split if needed but not just for line count.
  """
  @spec worker_prompt() :: String.t()
  def worker_prompt do
    """
    # Spark Worker — Code Puppy Coding Persona

    You are a Spark worker agent running the Code Puppy coding methodology.

    ## CORE DIRECTIVES

    - **TOOL-FIRST**: You MUST use the provided tools to write, modify, and execute code rather than just describing what to do. Do not output code blocks as text — use the file tools to write them.
    - **READY-TO-CODE TONE**: No filler. Dive straight into implementation. No greetings, no disclaimers, no preamble.
    - **REASON BEFORE TOOL USE**: Before major tool use, think through your approach and planned next steps.
    - **EXPLORE BEFORE MODIFYING**: Explore directories before reading/modifying files. Use list_files and glob to understand structure before touching anything.
    - **READ BEFORE MODIFYING**: Always read existing files before modifying them. Never overwrite without understanding current content.
    - **PREFER TARGETED EDITS**: Use replace_in_file over create_file when modifying existing files. Keep diffs small. Avoid full file rewrites when possible.
    - **LOOP TO VERIFY**: Loop between reasoning, file tools, and shell command testing to write and verify programs.
    - **CONTINUE AUTONOMOUSLY**: Keep going unless user input is definitively required. Don't stop to ask permission for each step within your assigned task.

    ## CODE PRINCIPLES

    - Be pedantic about DRY (Don't Repeat Yourself), YAGNI (You Ain't Gonna Need It), and SOLID.
    - Keep files under 600 lines. If a file grows beyond that, consider splitting into smaller subcomponents — but don't split purely to hit a line count if it hurts cohesion.
    - Always obey the Zen of Python, even if you are not writing Python code.

    ## TASK EXECUTION FLOW

    1. Analyze the task requirements carefully
    2. Explore the relevant directories and read existing files
    3. Execute the plan by using appropriate tools
    4. Verify with shell commands (mix test, mix compile, etc.)
    5. Continue autonomously unless blocked

    ## IMPORTANT RULES

    - You MUST use tools — DO NOT just output code or descriptions
    - Think before major tool use
    - Explore directories before reading/modifying files
    - Read existing files before modifying them
    - Prefer replace_in_file over create_file. Keep diffs small.
    - Loop among reasoning, file tools, and shell testing
    - Continue autonomously unless user input is definitively required

    Always report tool outcomes honestly.
    """
  end

  @doc """
  The exact handoff phrase used when transitioning from planning to coding.
  """
  @spec handoff_phrase() :: String.t()
  def handoff_phrase, do: "Handing off to Coding Agent..."

  # ─── Telemetry Helpers ───────────────────────────────────────────────

  @max_preview 500

  # Patterns to redact from logs/telemetry to avoid leaking secrets
  @secret_patterns [
    {~r/(api[_-]?key|token|secret|password|credential)\s*[:=]\s*["']?[^\s"']{4,}/i,
     "\\1=***REDACTED***"},
    {~r/(Bearer\s+)\S+/i, "\\1***REDACTED***"},
    {~r/(Authorization["']?\s*[:=]\s*["']?)\S+/i, "\\1***REDACTED***"}
  ]

  @doc """
  Publishes a state transition event for the TUI/event log.

  Logs with Logger and publishes `:state_transition` via EventBus
  with text like `[STATE: PLANNING] -> [STATE: EXECUTING] (reason)`.
  """
  @spec publish_state_transition(atom(), atom(), map(), String.t()) :: :ok
  def publish_state_transition(from_phase, to_phase, context, reason \\ "") do
    from_label = phase_label(from_phase)
    to_label = phase_label(to_phase)

    message =
      if reason != "" do
        "[STATE: #{from_label}] -> [STATE: #{to_label}] (#{reason})"
      else
        "[STATE: #{from_label}] -> [STATE: #{to_label}]"
      end

    Logger.info("CodePuppyCompat: #{message}")

    session_id = Map.get(context, :session_id, "")
    plan_id = Map.get(context, :plan_id)

    EventBus.publish_event(:state_transition, %{message: message, from: from_phase, to: to_phase, reason: reason},
      session_id: session_id,
      plan_id: plan_id,
      source: :orchestrator
    )

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  @doc """
  Publishes an agent reasoning event for the TUI/event log.

  Publishes `:agent_reasoning` via EventBus and logs the message.
  """
  @spec publish_reasoning(atom(), String.t(), map()) :: :ok
  def publish_reasoning(stage, message, context) do
    Logger.info("CodePuppyCompat [#{stage}]: #{truncate_string(message, @max_preview)}")

    session_id = Map.get(context, :session_id, "")
    plan_id = Map.get(context, :plan_id)
    task_id = Map.get(context, :task_id)

    EventBus.publish_event(:agent_reasoning, %{stage: stage, message: message},
      session_id: session_id,
      plan_id: plan_id,
      task_id: task_id,
      source: Map.get(context, :source, :orchestrator)
    )

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  @doc """
  Publishes a tool preflight explanation before execution.

  Publishes `:tool_preflight` and `:agent_reasoning` with text like:
  "I am now using [Tool] to [Action] because [Reason]."
  """
  @spec publish_tool_preflight(String.t(), map(), map(), String.t()) :: :ok
  def publish_tool_preflight(tool_name, args, context, description \\ "") do
    action = if description != "", do: description, else: "execute #{tool_name}"
    reason = infer_tool_reason(tool_name, args)
    message = "I am now using #{tool_name} to #{action} because #{reason}."

    safe_args = redact_secrets(truncate_map(args, @max_preview))

    Logger.info("CodePuppyCompat preflight: #{message}")

    session_id = Map.get(context, :session_id, "")
    task_id = Map.get(context, :task_id)

    EventBus.publish_event(:tool_preflight, %{
      tool: tool_name,
      args_preview: safe_args,
      message: message
    },
      session_id: session_id,
      task_id: task_id,
      source: :tool_runner
    )

    # Also publish as reasoning so the TUI can surface it
    EventBus.publish_event(:agent_reasoning, %{stage: :tool_preflight, message: message},
      session_id: session_id,
      task_id: task_id,
      source: :tool_runner
    )

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  @doc """
  Publishes a tool result summary after execution.

  Publishes `:tool_result_summary` and `:agent_reasoning` summarizing
  success/error/timeout with safe truncated previews of args and results.
  """
  @spec publish_tool_summary(String.t(), {:ok, map()} | {:error, map()}, map()) :: :ok
  def publish_tool_summary(tool_name, result, context) do
    {status, summary_text} =
      case result do
        {:ok, %{status: :ok} = res} ->
          preview = truncate_map(res, @max_preview) |> redact_secrets() |> inspect()
          {"success", "Tool #{tool_name} completed successfully. Result preview: #{preview}"}

        {:ok, res} when is_map(res) ->
          preview = truncate_map(res, @max_preview) |> redact_secrets() |> inspect()
          {"ok", "Tool #{tool_name} completed. Result preview: #{preview}"}

        {:error, %{status: :timeout}} ->
          {"timeout", "Tool #{tool_name} timed out."}

        {:error, %{status: :crashed} = res} ->
          {"crashed", "Tool #{tool_name} crashed: #{inspect(truncate_map(res, @max_preview))}"}

        {:error, res} when is_map(res) ->
          preview = truncate_map(res, @max_preview) |> redact_secrets() |> inspect()
          {"error", "Tool #{tool_name} failed. Error preview: #{preview}"}

        other ->
          {"unknown", "Tool #{tool_name} returned: #{truncate_string(inspect(other), @max_preview)}"}
      end

    Logger.info("CodePuppyCompat summary: #{summary_text}")

    session_id = Map.get(context, :session_id, "")
    task_id = Map.get(context, :task_id)

    EventBus.publish_event(:tool_result_summary, %{
      tool: tool_name,
      status: status,
      message: summary_text
    },
      session_id: session_id,
      task_id: task_id,
      source: :tool_runner
    )

    # Also publish as reasoning for TUI visibility
    EventBus.publish_event(:agent_reasoning, %{stage: :tool_result, message: summary_text},
      session_id: session_id,
      task_id: task_id,
      source: :tool_runner
    )

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  # ─── Private Helpers ─────────────────────────────────────────────────

  defp phase_label(phase) do
    phase
    |> Atom.to_string()
    |> String.upcase()
  end

  defp truncate_string(str, max) when is_binary(str) and byte_size(str) > max do
    binary_part(str, 0, max) <> "...[truncated]"
  end

  defp truncate_string(str, _max) when is_binary(str), do: str
  defp truncate_string(other, max), do: truncate_string(inspect(other), max)

  defp truncate_map(map, max) when is_map(map) do
    map
    |> Enum.map(fn {k, v} -> {k, truncate_value(v, max)} end)
    |> Map.new()
  end

  defp truncate_map(other, max), do: truncate_string(inspect(other), max)

  defp truncate_value(binary, max) when is_binary(binary) and byte_size(binary) > max do
    binary_part(binary, 0, max) <> "...[truncated]"
  end

  defp truncate_value(v, _max), do: v

  defp redact_secrets(data) when is_binary(data) do
    Enum.reduce(@secret_patterns, data, fn {pattern, replacement}, acc ->
      Regex.replace(pattern, acc, replacement)
    end)
  end

  defp redact_secrets(data) when is_map(data) do
    data
    |> Enum.map(fn {k, v} ->
      v_safe = if is_binary(v), do: redact_secrets(v), else: v
      {k, v_safe}
    end)
    |> Map.new()
  end

  defp redact_secrets(data), do: data

  # Infer a human-readable reason for why a tool is being used
  defp infer_tool_reason("read_file", _args), do: "I need to understand the current content before making changes"
  defp infer_tool_reason("write_file", _args), do: "I need to create or write file content"
  defp infer_tool_reason("edit_file", _args), do: "I need to make a targeted edit to an existing file"
  defp infer_tool_reason("list_dir", _args), do: "I need to explore the directory structure first"
  defp infer_tool_reason("list_files", _args), do: "I need to explore the directory structure first"
  defp infer_tool_reason("glob", _args), do: "I need to find files matching a pattern"
  defp infer_tool_reason("grep", _args), do: "I need to search the codebase for a pattern"
  defp infer_tool_reason("bash", _args), do: "I need to run a shell command to verify or execute"
  defp infer_tool_reason("agent_run_shell_command", _args), do: "I need to run a shell command to verify or execute"
  defp infer_tool_reason("create_file", _args), do: "I need to create a new file with the provided content"
  defp infer_tool_reason("replace_in_file", _args), do: "I prefer targeted edits over full rewrites to keep diffs small"
  defp infer_tool_reason("delete_snippet", _args), do: "I need to remove a specific text snippet from a file"
  defp infer_tool_reason("delete_file", _args), do: "I need to safely delete a file"
  defp infer_tool_reason("web_fetch", _args), do: "I need to fetch content from a URL for research"
  defp infer_tool_reason("web_search", _args), do: "I need to search the web for information"
  defp infer_tool_reason(tool_name, _args), do: "I need to use #{tool_name}"
end
