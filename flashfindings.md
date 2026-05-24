# Flash Findings - Spark TUI & Planning Prompt Upgrade

This document summarizes the upgrades made to the Spark CLI coding tool, including the redesigned Terminal UI dashboard and the emulated "Code Puppy" Planning Agent system prompt.

---

## PART 1: TUI / UX REDESIGN SUMMARY

### 1. Unified Grid Layout & Strict Zoning
The Spark CLI interface is now a full-screen dashboard taking advantage of `TermUI`'s character-cell rendering capabilities with zero flickering.
- **Top 85% (The Canvas):** Houses the main chat window, visual banners, ASCII art puppy, agent lists, and detailed plan displays. Built with generous padding for high readability.
- **Bottom 15% (The Command Deck):** Houses the focused text input field (`> type here...`), real-time status/progress indicators (e.g. `[████████░░░] 72%`), and contextual shortcut keys.
- **Unicode Borders:** Structured with standard box-drawing characters (`┌─┐`, `├─┤`, `└─┘`, `│`, `─`) dynamically sized according to terminal dimensions.

### 2. Global Input Field & Slash Commands
The Command Deck input box is focused on startup.
- Typing normal characters globally appends to this input buffer. If typed on any status or log screen, the UI automatically transitions back to the Home canvas.
- Pressing `Enter` parses inputs. If starting with `/` (e.g. `/home`, `/agents`, `/dash`, `/logs`, `/help`, `/quit`), navigation occurs immediately. Otherwise, it triggers the plan generation or feedback refinement loops.
- Shortcut keys (like `A`, `D`, `L`, `?`) act as quick navigation triggers *only when* the input buffer is empty, avoiding conflicts while typing.

### 3. Smooth Independent Scrolling
- A `scroll_top` index has been added to the state.
- The Canvas lines are sliced and scrolled independently from the Command Deck.
- Users can scroll using:
  - `Ctrl-K` / `Ctrl-P` (Scroll Up 1 line)
  - `Ctrl-J` / `Ctrl-N` (Scroll Down 1 line)
  - `PageUp` / `PageDown` (Scroll Up/Down 5 lines)
  - Mouse Wheel scrolling in raw mode (Scroll Up/Down 3 lines)

---

## PART 2: PLANNING AGENT WORKFLOW COMPARISON

| Feature / Philosophy | Python Reference (`fast_puppy`) | Elixir Implement (`spark`) |
| :--- | :--- | :--- |
| **Agent Supervision** | Client-side agent class looping in Python runtime, directly invoking MCP tools and reviewers. | OTP GenServer (`Spark.Orchestrator`) coordinating phases: `:planning -> :awaiting_approval -> :executing`. |
| **Tool Execution** | Planning Agent calls read-only tools like `list_files`, `read_file`, `grep` directly. | GenServer uses LLM to build a structured JSON plan, which gets executed asynchronously by worker actors. |
| **The Approval Gate** | Prompt asks user to reply "execute plan" in chat; agent holds state. | State machine locks in `:awaiting_approval`; TUI renders review screen; Enter/A approves, R rejects. |
| **Handoff Mechanism** | Handled within the Python chat session by switching agent profiles. | Orchestrator decodes LLM-generated JSON tasks and passes them to `Spark.Dispatcher` GenServer via message passing. |

---

## PART 3: THE "CODE PUPPY" PLANNING AGENT SYSTEM PROMPT

The following exact text has been injected as the system prompt (`@orchestrator_prompt` in `lib/spark/orchestrator.ex` and `lib/spark/prompt/store.ex`):

```text
You are Spark's Planning Agent, emulating the "Code Puppy" deep-investigation planning methodology.
Your job is to investigate, analyze, and architect a comprehensive implementation plan for the user's request.

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
```
