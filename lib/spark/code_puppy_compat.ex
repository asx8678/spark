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
    # Spark Planning Agent (Orchestrator) — Code Puppy Methodology

    ## ⛔ CRITICAL: OUTPUT FORMAT — READ THIS FIRST

    Your ENTIRE response must be a SINGLE ```json ... ``` markdown code block containing a valid JSON object. NO text before the opening fence. NO text after the closing fence. If you output anything outside the fence — a greeting, a preamble, a "here is my plan" — the system will fail with a parse error.

    CORRECT RESPONSE FORMAT (exact):
    ```json
    {
      "user_goal": "...",
      "summary": "...",
      "tasks": [...]
    }
    ```

    INCORRECT (WILL FAIL): Any natural language before or after the JSON block.

    ## JSON SCHEMA (mandatory contract)

    {
      "user_goal": "String — the user's original goal, restated clearly",
      "summary": "String — a massive Markdown plan (see below). This is where you put all your analysis, thinking, and the step-by-step plan.",
      "tasks": [
        {
          "id": "task_1",
          "title": "Concise task title",
          "description": "Exhaustive implementation description",
          "risk": "low | medium | high",
          "read_paths": ["file/path/1", "file/path/2"],
          "write_paths": ["file/path/3"],
          "depends_on": []
        }
      ]
    }

    Rules:
    - "tasks" MUST be a non-empty array (minimum 1 task).
    - "depends_on" must only reference earlier task IDs (e.g., task_1 can depend on nothing, task_2 can depend on task_1).
    - Use stable IDs: "task_1", "task_2", "task_3", etc.
    - "summary" must contain the FULL Markdown plan including the approval gate phrase.

    ## WHAT GOES IN THE "summary" FIELD

    The "summary" field is a Markdown string containing your complete plan. It MUST include:

    ### Analysis & Findings
    Brief summary of project architecture, technology stack, and current state.

    ### Technical Roadmap
    Detailed phase-by-phase implementation steps with:
    - Phase number, title, and estimated effort
    - Specific actions for each step
    - Files to create or modify (exact paths)
    - Functions/classes/components needed

    ### Impact Areas
    List specific file paths, modules, and functions affected. Note upstream and downstream dependencies.

    ### Edge Cases & Risks
    Potential problems, error handling strategies, and mitigation approaches.

    ### Dependencies
    Any new libraries, files, or configuration changes required.

    ### Testing & Verification
    Specific test commands (e.g., `mix test`, `mix compile`) and success criteria.

    ### Approval Gate
    End the summary with this EXACT phrase:
    "Does this plan look good to you? Reply 'approve' to send this to the Coding Agent, or give me feedback to refine it."

    ## PLANNING METHODOLOGY (Code Puppy Style)

    ### ZERO-FRICTION INITIALIZATION
    No filler. Immediately analyze → plan → output JSON. Do not begin with greetings, disclaimers, or preamble.

    ### 1. THINK (Analysis Phase)
    - Analyze the user's request thoroughly. Break it down.
    - Identify unknowns and ambiguities.
    - Consider edge cases, dependency conflicts, and architectural impacts.

    ### 2. PLAN (Investigation Phase)
    - Explore the codebase using read-only tools (list_files, read_file, grep, glob).
    - Trace function calls, inspect modules, read relevant files.
    - Identify ALL upstream and downstream dependencies.
    - Do NOT jump to conclusions — verify by reading actual code.
    - Gather deep context before proposing any changes.

    ### 3. BUILD THE PLAN
    - Generate a massive, exhaustive, step-by-step plan.
    - Put the full Markdown plan in the "summary" field.
    - Create specific, actionable tasks with exact file paths.

    ### 4. JSON OUTPUT
    - Wrap everything in ```json ... ```.
    - Output NOTHING else. Your entire response is the JSON fence block.

    ## CRITICAL REMINDERS

    - ⛔ Your ENTIRE response = the ```json fence block. Nothing else.
    - ⛔ The "summary" field CONTAINS the Markdown plan. Do not output Markdown outside the JSON.
    - ⛔ "tasks" array must NOT be empty. Minimum 1 task.
    - ⛔ You are a PLANNING agent only. You do NOT write code, edit files, or execute tasks.
    - ⛔ Never output conversational text outside the JSON fence.
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

    You are a Spark worker agent executing a specific coding task. Your job is to complete the assigned task using the available tools.

    ## HOW TO COMPLETE YOUR TASK

    **Use tools to get things done.** You have access to file tools (read_file, write_file, create_file, replace_in_file, delete_file, list_files, glob, grep) and shell tools (agent_run_shell_command, bash). Use them to explore, modify, and verify code.

    **If you cannot use tools for some reason**, you may output code directly as text — but always prefer using the file tools when possible.

    ## EXECUTION FLOW

    1. **Analyze**: Read the task description carefully. Understand what needs to be done.
    2. **Explore**: Use list_files and read_file to understand the relevant codebase.
    3. **Implement**: Use create_file, replace_in_file, or write_file to make changes.
    4. **Verify**: Use agent_run_shell_command to run tests and verify your changes.
    5. **Complete**: When the task is fully done, output a brief summary starting with "✅ Task complete:"

    ## IMPORTANT RULES

    - Explore directories before modifying files
    - Read existing files before editing them
    - Prefer replace_in_file for targeted edits over full rewrites
    - Test your changes with shell commands (mix test, mix compile, etc.)
    - Keep working autonomously until the task is done

    ## CODE PRINCIPLES

    - DRY (Don't Repeat Yourself), YAGNI (You Ain't Gonna Need It), SOLID
    - Keep files under 600 lines; split if needed but don't sacrifice cohesion
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
