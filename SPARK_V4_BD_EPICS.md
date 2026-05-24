# Spark v4.0 — BD Epics & Detailed Task Backlog

> **Auto-generated** from the Spark v4.0 Master Implementation Plan.
> **Coordinator:** `planning-agent-754a5d`
> **v4.1 Coordinators:** planning-agent-754a5d (v4.0), planning-agent-3e8ed8 (v4.1 TUI + Planning Prompt)
> **Total:** 19 epics · 120 tasks · 11 milestones · 145 bd issues
> **Source:** `bd` database at `/Users/adam2/projects/spark/.beads/`

---

## Architecture Overview

Spark v4.0 is a **highly concurrent actor-model** Elixir/OTP application with three core actors:
- **Orchestrator** — persistent GenServer, long-context planning/review (DeepSeek/MiMo)
- **Dispatcher** — persistent GenServer, concurrent task queue, worker lifecycle
- **Workers** — ephemeral GenServers, isolated coding tasks (Wafer AI/GLM-5.1)
- **AgentManager** — persistent GenServer, routes actor types to pinned models/providers (DeepSeek ↔ Wafer AI)

Connected via **EventBus** (Phoenix.PubSub), enforced by **Policy**, steered by **Guidance**, with **first-class hot reload**.

---

## MVP Milestones

| Milestone | Success Condition | Epics |
|-----------|-------------------|-------|
| **MVP-1**: Bootable OTP App | `mix test` boots, core processes registered, `/status` works | Phase 1, 3 |
| **MVP-2**: Dispatcher Vertical Slice | 10 fake tasks, max_concurrency=3, all complete | Phase 5 |
| **MVP-3**: LLM & Prompt Foundation | Orchestrator calls mock LLM, produces a plan | Phase 4 |
| **MVP-4**: Worker + ToolRunner | Worker reads/edits file, returns WorkerResult | Phase 6, 9 |
| **MVP-5**: Orchestrator + HITL | Goal → plan → approval → execution → final review | Phase 7, 8, 14 |
| **MVP-6**: Hot Reload Vertical Slice | Edit prompt → new Worker uses it without restart | Phase 2 |
| **MVP-7**: Production Hardening | Multi-task session, failures, reloads, reliable review | Phase 10–15 |
| **MVP-8**: Agent & Model Manager | `/agent` menu pins models to Planning/Coding agents, multi-provider routing | Phase 16 |
| **MVP-9**: Architecture Hardening & Production Readiness | No blocked GenServer mailboxes under load, bounded memory growth, connection pooling active, graceful Ctrl+C shutdown | Phase 17 |
| **MVP-10**: TUI Dashboard Redesign | Full-screen 85/15 split canvas+command deck, zero flicker, Unicode box-drawing, ASCII art banner, pixel-perfect resize, smooth scrolling | Phase 18 |
| **MVP-11**: Code Puppy Planning Prompt | Planning Agent uses read-only tool restriction, generates huge exhaustive plans in structured Markdown, enforces approval gate, hands off via GenServer message passing | Phase 19 |

---

## Phase → Epic Mapping

| BD Epic ID | Phase | Title | Priority | Children |
|------------|-------|-------|----------|----------|
| `spark-ega` | 1 | Foundation, Config, Security & Supervision | P0 | 8 |
| `spark-1uu` | 2 | Hot Reload Foundation | P0 | 7 |
| `spark-bny` | 3 | EventBus & Runtime Event Contracts | P0 | 3 |
| `spark-ova` | 4 | LLM Client, Streaming, Provider Abstraction & Prefix Cache | P1 | 6 |
| `spark-u4b` | 5 | Dispatcher & Concurrent Task Queue | P1 | 6 |
| `spark-pvp` | 6 | Worker GenServer & Focused Execution Loop | P1 | 4 |
| `spark-anh` | 7 | Orchestrator GenServer | P1 | 6 |
| `spark-04w` | 8 | Policy, Approval Gates & Discipline Enforcement | P1 | 5 |
| `spark-pl3` | 9 | Tool Registry, ToolRunner & Core Tools | P1 | 8 |
| `spark-57y` | 10 | Workspace Safety, Diffs & Parallel Write Control | P2 | 3 |
| `spark-31u` | 11 | Guidance System | P2 | 2 |
| `spark-3jf` | 12 | Memory, Compaction & Session Logs | P2 | 4 |
| `spark-l1b` | 13 | Prompt Store, Prompt Lab & Prompt Refiner | P2 | 4 |
| `spark-98t` | 14 | Interactive CLI & Streaming UI | P2 | 5 |
| `spark-opg` | 15 | End-to-End Execution Flow & Integration Tests | P2 | 5 |
| `spark-a8m` | 16 | Agent & Model Manager with Interactive Model Pinning | P1 | 5 |
| `spark-ard` | 17 | Architecture Hardening & Production Readiness | P0 | 19 |
| `spark-dsh` | 18 | TUI Dashboard Redesign — Full-Screen Canvas + Command Deck | P1 | 10 |
| `spark-pup` | 19 | Planning Agent System Prompt — "Code Puppy" Methodology | P1 | 4 |

---

## Dependency Graph

```
Phase 1 (spark-ega) ──┐
Phase 2 (spark-1uu) ──┤── Phase 4 (spark-ova) ──┐
Phase 3 (spark-bny) ──┘── Phase 5 (spark-u4b) ──┤── Phase 6 (spark-pvp) ──┬── Phase 8 (spark-04w) ──┬── Phase 7 (spark-anh)
                                                   │                        │── Phase 9 (spark-pl3)  │
                                                   │                        ├── Phase 10 (spark-57y) │
                                                   │                        ├── Phase 11 (spark-31u) │
                                                   │                        └───────────────────────┘
                                                   │
                                                   └── Phase 7 (spark-anh) ──┬── Phase 12 (spark-3jf) ── Phase 13 (spark-l1b)
                                                                              ├── Phase 14 (spark-98t)
                                                                              ├── Phase 15 (spark-opg)
                                                                              ├── Phase 16 (spark-a8m)
                                                                              ├── Phase 17 (spark-ard)
                                                                              ├── Phase 18 (spark-dsh) ── depends on Phase 14 (CLI/TUI foundation), Phase 16 (AgentManager)
                                                                              └── Phase 19 (spark-pup) ── depends on Phase 4 (LLM), Phase 7 (Orchestrator), Phase 14 (CLI)
```

---

## Detailed Task Breakdown

### Phase 1: Foundation, Config, Security & Supervision (`spark-ega`, 8 tasks)

| Task ID | Title | Acceptance Criteria | Key Tests |
|---------|-------|---------------------|-----------|
| spark-ega.1 | Define Spark.Types.Task struct | All fields present (id, plan_id, title, description, context, status, priority, depends_on, read/write_paths, risk, retry metadata, timestamps). Invalid task without id rejected. | Valid task creation, invalid task validation |
| spark-ega.2 | Define Spark.Types.Plan struct | All fields + approval state machine (:draft→:awaiting_approval→:approved/:rejected/:modified) | Plan creation, approval flow |
| spark-ega.3 | Define Spark.Types.WorkerResult struct | All fields (task_id, worker_id, status, summary, files_changed, diff, errors, token_usage). Failed results include reason + retry recommendation | Struct creation, failed result fields |
| spark-ega.4 | Define Spark.Types.Event struct | Universal envelope: id, topic, type, source, source_id, session_id, plan_id, task_id, payload, timestamp | Event creation, field validation |
| spark-ega.5 | Create Mix project with dependencies | app: :spark, version 4.0.0, deps: req, jason, floki, phoenix_pubsub | mix compile succeeds |
| spark-ega.6 | Implement Spark.Config | ~/.spark/ dir layout, config.json defaults, reload events | Dir init, default config, invalid JSON |
| spark-ega.7 | Implement AES-256-GCM secrets | PBKDF2, put/get/delete/list_secret_keys, never logs secrets | Encrypt/decrypt round trip, wrong passphrase |
| spark-ega.8 | Implement Spark.Application supervision tree | Full OTP tree: Registry×2, PubSub, HotReload×3, Task.Supervisor, DynamicSupervisor, LockManager, Dispatcher, Orchestrator | App boots, named processes reachable |

### Phase 2: Hot Reload Foundation (`spark-1uu`, 7 tasks)

| Task ID | Title | Acceptance Criteria | Key Tests |
|---------|-------|---------------------|-----------|
| spark-1uu.1 | Implement HotReload.Manifest | ETS-backed, register/update/get/list/previous, rollback target | Manifest CRUD, previous version |
| spark-1uu.2 | Implement HotReload.Coordinator | Reload lifecycle (validate→pause→apply→manifest→notify→resume), rollback on failure, events | Reload success/failure events |
| spark-1uu.3 | Implement HotReload.Watcher | Polling, mtime/hash, debounce, ignore *.tmp/*.swp, configurable interval | Debounce, disabled mode |
| spark-1uu.4 | Implement HotReload.Validator | Prompts readable, config valid JSON, tools compile + implement Spark.Tool, policy/guidance valid | Validation passes/fails |
| spark-1uu.5 | Implement HotReload.Rollback | Keep previous on failure for all component types | Prompt/config/tool reload failure + rollback |
| spark-1uu.6 | Implement HotReload.Compiler | Compile external/forge tools, prevent unsafe modules, validate behaviour, preserve on failure | Tool compile success/failure |
| spark-1uu.7 | Implement HotReload.Reloadable behaviour | reload_key/0, version/0, validate_reload/1, before_reload/1, after_reload/2 | Behaviour implementation |

### Phase 3: EventBus (`spark-bny`, 3 tasks)

| Task ID | Title | Acceptance Criteria | Key Tests |
|---------|-------|---------------------|-----------|
| spark-bny.1 | Implement Spark.EventBus wrapper | Phoenix.PubSub, subscribe/unsubscribe/publish, topic routing, multi-subscriber | Same event to multiple subscribers, no cross-session leak |
| spark-bny.2 | Normalize event emission | All public events use Spark.Types.Event struct, no raw tuples | Event struct enforcement |
| spark-bny.3 | Add EventBus logging hook | Simple consumption API for Memory, invalid payloads rejected | HotReload events publish correctly |

### Phase 4: LLM Client (`spark-ova`, 6 tasks)

| Task ID | Title | Acceptance Criteria | Key Tests |
|---------|-------|---------------------|-----------|
| spark-ova.1 | Define Spark.LLM.Provider behaviour | stream/3, complete/2 callbacks | Provider contract |
| spark-ova.2 | Implement Spark.LLM.WaferProvider | Wafer AI base URL, SSE streaming, rate limits, retries, never logs keys | Streaming response |
| spark-ova.3 | Implement Spark.LLM.SSEParser | data: lines, [DONE], JSON decode, delta accumulation | Chunks + [DONE] |
| spark-ova.4 | Implement Spark.LLM.Client | Actor-type routing, provider resolution, API key injection, timeout, events | Correct provider, key from secrets |
| spark-ova.5 | Implement Spark.LLM.Cache | Static prefix first, cache blocks, prefix rebuild on prompt reload | Prefix order, reload invalidation, compaction safety |
| spark-ova.6 | Implement Spark.LLM.MockProvider | Deterministic output, streaming simulation, failure simulation | Mock for Orchestrator tests |

### Phase 5: Dispatcher (`spark-u4b`, 6 tasks)

| Task ID | Title | Acceptance Criteria | Key Tests |
|---------|-------|---------------------|-----------|
| spark-u4b.1 | Implement Dispatcher.State | queue, active_workers, completed/failed tasks, max_concurrency, paused | State shape |
| spark-u4b.2 | Implement enqueue + spawn logic | Enqueue validates, maybe_spawn respects concurrency/dependencies/path locks/policy | Max concurrency, dependency gating |
| spark-u4b.3 | Implement worker monitoring | PID/monitor tracking, {:DOWN} handling, retry decision | Worker crash → failure event |
| spark-u4b.4 | Implement task completion handling | Remove worker, release locks, forward result, spawn next | Completion spawns next |
| spark-u4b.5 | Implement retry policy | Retryable (timeout, HTTP, crash) vs non-retryable (policy, invalid, conflict) | Retry + max retries |
| spark-u4b.6 | Implement Dispatcher config hot reload | max_concurrency changes, spawn more if increased, don't kill if decreased | Config reload changes concurrency |

### Phase 6: Worker (`spark-pvp`, 4 tasks)

| Task ID | Title | Acceptance Criteria | Key Tests |
|---------|-------|---------------------|-----------|
| spark-pvp.1 | Implement Worker startup/init | Validate task, capture versions, publish :task_started, handle_continue | Valid/invalid task |
| spark-pvp.2 | Implement Worker LLM execution loop | Message assembly, tool execution, guidance injection, never violates constraints | LLM call, tool via ToolRunner |
| spark-pvp.3 | Implement Worker completion/failure | WorkerResult on success, failed result with reason on failure, events published | Completed/failed events |
| spark-pvp.4 | Implement Worker hot reload behavior | Running = old versions, new = new versions, no crash on reload | Prompt reload affects new only |

### Phase 7: Orchestrator (`spark-anh`, 6 tasks)

| Task ID | Title | Acceptance Criteria | Key Tests |
|---------|-------|---------------------|-----------|
| spark-anh.1 | Implement Spark.State | Full phase machine, cached prefix, results, schema_version | State creation |
| spark-anh.2 | Implement planning flow | run/1, cache-aware messages, LLM call, plan parsing, Policy validation | Input → awaiting_approval |
| spark-anh.3 | Implement approval gate | Approve dispatches, reject returns, modify re-plans | Approve/reject/modify flows |
| spark-anh.4 | Implement result reconciliation | Append to history, check completion, review or follow-up | All complete → review, partial → retry |
| spark-anh.5 | Implement final review | Goal check, file changes, tests, failures, iteration, output summary | Review output structure |
| spark-anh.6 | Implement hot reload integration | Prompt → rebuild prefix, policy → revalidate draft, config → new model | Prefix rebuild, plan revalidation |

### Phase 8: Policy (`spark-04w`, 5 tasks)

| Task ID | Title | Acceptance Criteria | Key Tests |
|---------|-------|---------------------|-----------|
| spark-04w.1 | Implement Spark.Policy module | validate_plan/task/tool_call, requires_approval?, allowed? | Approval required, write blocked without ID |
| spark-04w.2 | Enforce approval gate | No unapproved dispatch, matching plan ID, modified = reset | Dispatcher rejects unapproved |
| spark-04w.3 | Enforce Worker isolation | No sub-workers, no state mutation, no bypass | Isolation violations blocked |
| spark-04w.4 | Implement tool risk model | :low/:medium/:high/:critical, shell = high, forge = approval | Shell blocked, forge blocked |
| spark-04w.5 | Hot-reloadable policy config | ~/.spark/policy/policy.json, validate, rollback if invalid | Reload changes behavior, invalid rejected |

### Phase 9: Tools (`spark-pl3`, 8 tasks)

| Task ID | Title | Acceptance Criteria | Key Tests |
|---------|-------|---------------------|-----------|
| spark-pl3.1 | Define Spark.Tool behaviour | name/0, description/0, schema/0, risk/0, execute/2 | Behaviour contract |
| spark-pl3.2 | Implement Spark.ToolRegistry | register/lookup/list/schemas, versioning, hot reload | Registration, lookup |
| spark-pl3.3 | Implement Spark.ToolRunner | Policy → schema → supervised exec → timeout → truncate → events | Success, timeout, policy denial |
| spark-pl3.4 | Implement Tools.File | read/write/edit, project root, task ID required for writes | File operations |
| spark-pl3.5 | Implement Tools.FS | list_dir/glob/grep, skip .git/_build/deps | FS operations |
| spark-pl3.6 | Implement Tools.Shell | bash, timeout, truncation, deny dangerous, task ID | Timeout/truncation |
| spark-pl3.7 | Implement Tools.Web | web_search/fetch, Req+Floki, timeouts | Web fetch parse |
| spark-pl3.8 | Implement Tools.Forge | create_and_load_tool, compile/validate/register, :tool_reloaded | Forge + hot reload |

### Phase 10: Workspace Safety (`spark-57y`, 3 tasks)

| Task ID | Title | Acceptance Criteria | Key Tests |
|---------|-------|---------------------|-----------|
| spark-57y.1 | Implement LockManager | acquire/release/conflicts?/status, release on completion/crash | Conflict detection, lock lifecycle |
| spark-57y.2 | Add write-path planning requirement | Plans include expected write paths, unknown = broad lock | Plan includes paths |
| spark-57y.3 | Implement Workspace.Diff | Git diff or hash tracking, unified diff, attached to WorkerResult | Diff generation |

### Phase 11: Guidance (`spark-31u`, 2 tasks)

| Task ID | Title | Acceptance Criteria | Key Tests |
|---------|-------|---------------------|-----------|
| spark-31u.1 | Implement Spark.Guidance | Load from ~/.spark/guidance/*.md, context-based selection, hot reload | Load, select, reload, invalid rollback |
| spark-31u.2 | Integrate with Worker loop | After tool result → ask Guidance → inject hidden message → next LLM call | Guidance injection in loop |

### Phase 12: Memory (`spark-3jf`, 4 tasks)

| Task ID | Title | Acceptance Criteria | Key Tests |
|---------|-------|---------------------|-----------|
| spark-3jf.1 | Implement Bronze memory | JSONL append, no secrets, truncate large payloads | JSONL append, redaction, truncation |
| spark-3jf.2 | Implement Silver memory | Compaction, preserve decisions/constraints, never compact prefix | Compaction, prefix stability |
| spark-3jf.3 | Implement Gold memory | ~/.spark/memory/gold.md, curated knowledge | Gold append |
| spark-3jf.4 | Integrate with Orchestrator cache | Static prompt + rules + gold = cacheable; silver + history = not | Config reload behavior |

### Phase 13: Prompt System (`spark-l1b`, 4 tasks)

| Task ID | Title | Acceptance Criteria | Key Tests |
|---------|-------|---------------------|-----------|
| spark-l1b.1 | Implement Prompt.Store | Load from ~/.spark/prompts/, version/hash tracking, hot reload | Loading, version changes, reload |
| spark-l1b.2 | Implement PromptLab | Replay Bronze log with candidate prompt, compare metrics | Replay with fixture |
| spark-l1b.3 | Implement PromptRefiner | Analyze failures, create candidate, run replay, require approval | Candidate generation with mock |
| spark-l1b.4 | Hot reload prompt replacement | Write → reload → version → rebuild prefix → log | Approval → file → reload |

### Phase 14: CLI (`spark-98t`, 5 tasks)

| Task ID | Title | Acceptance Criteria | Key Tests |
|---------|-------|---------------------|-----------|
| spark-98t.1 | Implement CLI REPL | All commands (/plan, /code, /approve, /reject, /modify, /status, /workers, /tasks, /reload, /prompt_lab, /refine_prompt, /clear, /exit, !<cmd>) | Command parsing |
| spark-98t.2 | Implement approval flow | Render plan + tasks + deps + paths + risk, [A]/[R]/[M]/[D] prompt | Approve/reject/modify calls |
| spark-98t.3 | Implement parallel dashboard | EventBus subscription, all metrics (IO.ANSI, no Ratatouille) | Dashboard handles events |
| spark-98t.4 | Implement streaming output | Orchestrator/Worker/tool events, structured preferred | Graceful failure handling |
| spark-98t.5 | Implement hot reload commands | /reload triggers Coordinator, /reload status shows manifest, no crash on failure | Reload invokes Coordinator |

### Phase 15: E2E Integration (`spark-opg`, 5 tasks)

| Task ID | Title | Acceptance Criteria | Key Tests |
|---------|-------|---------------------|-----------|
| spark-opg.1 | Full plan execution (mock LLM) | Goal → plan → approval → 3 Workers → results → review → Bronze log | Full E2E with concurrency=3 |
| spark-opg.2 | Worker crash and retry | Crash → retry retryable → propagate non-retryable → partial review | Crash + retry flow |
| spark-opg.3 | Policy denial | High-risk blocked, denial reason, not retried | Policy enforcement |
| spark-opg.4 | Hot reload during execution | Prompt/config/tool reload, running continues, new uses updated | Hot reload E2E |
| spark-opg.5 | Orchestrator final review | All tasks complete → summary with files/tests/issues | Final review output |

### Phase 16: Agent & Model Manager (`spark-a8m`, 5 tasks)

| Task ID | Title | Acceptance Criteria | Key Tests |
|---------|-------|---------------------|-----------|
| spark-a8m.1 | Implement Spark.ModelCatalog | Defines available models per provider (DeepSeek: deepseek-v4-pro, deepseek-v4-flash, deepseek-chat; Wafer: glm-5.1, deepseek-chat). list_providers/0, models_for_provider/1. Pure data module. | Provider list, model list per provider |
| spark-a8m.2 | Implement Spark.AgentManager GenServer | Registry of named agents (planning→orchestrator, coding→worker). Each agent pins: provider, model, base_url. list_agents/0, get_agent/1, pin_model/2, resolve_for_actor/1. Persists to config.json under "agents" key. Reads on boot, writes on pin. | Agent CRUD, persistence, actor resolution |
| spark-a8m.3 | Update Spark.LLM.Client resolve_opts to use AgentManager | Per-actor-type base_url, model, and API key resolution via AgentManager.resolve_for_actor/1. API key convention: `:"#{provider}_api_key"` in secrets. Fallback to `:wafer_api_key`. Backward compatible with existing `llm.*` flat config. | Orchestrator→DeepSeek, Worker→Wafer routing, fallback |
| spark-a8m.4 | Add /agent CLI command with interactive model picker | Add `/agent` to slash_commands and help_text. Menu: [P]lanning Agent shows current model, [C]oding Agent shows current model. Press P/C → numbered model list from ModelCatalog → enter number to pin. Confirms: "✅ Planning agent pinned to deepseek-v4-flash". Persists via AgentManager. | Menu render, P/C selection, model pin, persistence across restart |
| spark-a8m.5 | Register AgentManager in supervision tree + tests | AgentManager started in Application.prod_children (not in test). Unit tests for ModelCatalog, AgentManager state transitions, pin_model persistence round-trip. CLI parse tests for /agent command. Integration test: pin model → verify resolve_opts returns correct config. | AgentManager in tree, unit tests, CLI parse test |

### Phase 17: Architecture Hardening & Production Readiness (`spark-ard`, 19 tasks)

> **Source:** Principal Architect Review by `planning-agent-3e8ed8` — full-system audit of GenServer IPC, streaming backpressure, supervision resilience, CLI shutdown, and code quality.
> **Production Readiness Score:** 3/10 → Target: 8/10 after completion.

#### Sub-Phase 17A: Stop the Bleeding — Critical Mailbox & Memory Fixes (5 tasks, P0)

| Task ID | Title | Acceptance Criteria | Key Tests |
|---------|-------|---------------------|----------|
| spark-ard.1 | Convert Orchestrator LLM `handle_call` to async `Task` + `GenServer.reply/2` | `handle_call({:run,...})` spawns `Task.start` and immediately returns `{:noreply, state}`. LLM response arrives via `handle_info({:llm_response, from, result}, ...)` which calls `GenServer.reply/2`. Same pattern applied to `modify_plan` and `do_final_review`. Timeout: `@llm_call_timeout_ms` unchanged. | `/plan` followed by immediate `/status` returns phase within 100ms. `modify_plan` non-blocking. `do_final_review` non-blocking. |
| spark-ard.2 | Replace unbounded `history ++ [entry]` with ring buffer (max 50 entries) | `Spark.State.add_history/2` prepends entries (O(1) vs O(n) `++` append). When length > 50, oldest entries dropped. Trigger Silver compaction when history crosses threshold before eviction. Worker `history` and `guidance_messages` also capped at 50. | 200 interactions → `state.history` length = 50. No `++` concatenation in hot path. Memory stable under `:erlang.memory(:process)` measurement. |
| spark-ard.3 | Replace `GenServer.call` with `cast` for Worker→Dispatcher completion notification | `Spark.Dispatcher.handle_worker_complete/2` and `handle_worker_failed/2` use `GenServer.cast` instead of `call`. Workers fire-and-forget completion. Dispatcher acknowledges via EventBus `:task_completed`/`:task_failed` events (already published). | 10 concurrent Workers all completing simultaneously — no Worker blocks waiting for Dispatcher reply. EventBus events still fire correctly. |
| spark-ard.4 | Convert CLI REPL from bare `spawn_link` to OTP-compliant GenServer | `Spark.CLI` becomes `use GenServer`. REPL loop driven by `handle_info(:prompt, ...)`. `start_link/1` registers under `Spark.CLI` name. `:sys.get_state/1` works for debugging. Supervision tree adds conditional `{Spark.CLI, []}` in prod children. | `Process.whereis(Spark.CLI)` returns pid. `:sys.get_state(Spark.CLI)` returns state map. Ctrl+C → GenServer terminates cleanly (handle `{:EXIT, ...}` or trap_exit). |
| spark-ard.5 | Implement graceful shutdown: drain workers, flush logs, close connections | `Spark.CLI.handle_info({:EXIT, ...})` calls `Spark.Dispatcher.drain/1` (waits for active Workers up to 5s), `Spark.Memory.Bronze.flush/0`, `Spark.LLM.Client.shutdown/0` (close Finch pool). `System.trap_signal(:SIGINT)` and `:SIGTERM` in REPL init. | Ctrl+C during execution → "🛑 Shutting down..." message → all Worker pids dead within 5s → Bronze log flushed → exit code 0. No orphaned processes in observer. |

#### Sub-Phase 17B: Streaming & I/O Hardening (5 tasks, P0)

| Task ID | Title | Acceptance Criteria | Key Tests |
|---------|-------|---------------------|----------|
| spark-ard.6 | Add Finch HTTP connection pool with keep-alive | Add `{:finch, "~> 0.18"}` to deps. `Spark.FinchPool` started in supervision tree with pool config: default pool size 10, Wafer host pool size 20. `WaferProvider` uses `Req` with `finch: Spark.FinchPool` and `connect_options: [keepalive: true]`. | 100 sequential LLM calls → connection reuse confirmed via `Finch.status/1`. TLS handshake only on first call. ~40-60% latency reduction on repeated calls. |
| spark-ard.7 | Add partial-line buffering to SSE parser | `Spark.LLM.SSEParser.parse_stream/2` accepts optional buffer arg. Returns `{results, remaining_buffer}` tuple. Incomplete final line (no newline) carried over to next call. `WaferProvider.stream/3` `into:` callback tracks buffer in accumulator. | SSE chunk split mid-JSON-line across two TCP packets → correctly reassembled and parsed. No data loss. `{:ok, parsed}` for complete lines. |
| spark-ard.8 | Fix WaferProvider stream accumulator to build correct final response | `_accumulated` in `stream/3` properly accumulates `choices[0].message.content` across all deltas. Final response passed to `callback.({:done, {:ok, full_response}})` has complete content string, correct model, and usage stats. | Stream 3 chunks: "Hello", " World", "!" → final response `choices[0].message.content == "Hello World!"`. |
| spark-ard.9 | Add GenStage demand-driven pipeline for Worker LLM streaming | New `Spark.Streaming.SSEProducer` (GenStage producer) and `Spark.Streaming.ChunkConsumer` (GenStage consumer-consumer). Producer fetches SSE when demand > 0. Consumer sends chunks to Worker via `send/2`. Worker processes at its own pace — no mailbox flooding. | Producer with 10_000 token stream → Worker processes 1 chunk/100ms → producer only fetches what's demanded → Worker mailbox never exceeds 10 pending messages. |
| spark-ard.10 | Add streaming timeout, circuit breaker, and proactive rate limiting to WaferProvider | `stream/3` wraps `Req.post!` with `:timer.exit_after` for timeout. Circuit breaker: 3 consecutive failures within 60s → open circuit for 30s → half-open probe. Rate limiter: token bucket, 50 req/s burst, 10 req/s sustained. 429 responses trigger backoff with jitter. | 3 immediate 500 errors → circuit opens → 4th call returns `{:error, :circuit_open}` immediately. After 30s → probe succeeds → circuit closes. Token bucket prevents burst > 50. |

#### Sub-Phase 17C: Supervision & Resilience (4 tasks, P1)

| Task ID | Title | Acceptance Criteria | Key Tests |
|---------|-------|---------------------|----------|
| spark-ard.11 | Restructure supervision tree with `:rest_for_one` for Orchestrator/Dispatcher | New `Spark.ExecutionSupervisor` wraps `[Guidance, Dispatcher, Orchestrator]` with `strategy: :rest_for_one`. If Dispatcher crashes, Orchestrator restarts too (re-sync state). If Orchestrator crashes, Dispatcher continues (no cascading). Top-level supervisor remains `:one_for_one`. | Kill Dispatcher → Orchestrator restarts within 1s. Kill Orchestrator → Dispatcher unaffected. Both recover to `:awaiting_input` phase. |
| spark-ard.12 | Add periodic Orchestrator state checkpointing to disk | New `Spark.Orchestrator.Checkpoint` module. `schedule/1` sends `Process.send_after(self(), :checkpoint, 30_000)`. `save/1` writes `{phase, active_plan, completed_results, failed_results}` via `:erlang.term_to_binary` to `~/.spark/sessions/<session_id>.checkpoint`. `restore/1` reads on boot. | Orchestrator processes 10 tasks, crashes, restarts → restores checkpoint → resumes from last checkpoint (max 30s data loss). `:no_checkpoint` for fresh sessions. |
| spark-ard.13 | Remove defensive `try/rescue` in Worker — narrow to expected failure modes only | `Worker.handle_info({:execute_step, ...})` only rescues `Jason.DecodeError` and `KeyError` (malformed LLM output). All other exceptions propagate to DynamicSupervisor → proper crash + retry. `collect_guidance_messages` only rescues `FunctionClauseError` from `Guidance.select/2`. `safe_dispatcher_call` only rescues `:noproc` and `{:nodedown, ...}`. | Genuine bug (e.g., `nil` passed to `String.length`) → Worker crashes → Dispatcher gets `{:DOWN, ...}` → retry scheduled. No silent error swallowing. |
| spark-ard.14 | Add Worker heartbeat monitoring to Dispatcher | Workers send `Process.send_after(self(), {:heartbeat, task_id}, 15_000)` on init. Each `handle_info({:heartbeat, ...})` notifies Dispatcher via cast. Dispatcher `handle_cast({:worker_heartbeat, task_id, ...})` updates timestamp in `active_workers`. Periodic `handle_info(:check_heartbeats, ...)` (every 10s) detects workers with > 30s since last heartbeat → demonitor + mark failed + retry. | Worker stuck in infinite loop (no LLM call, no tool call) → 30s heartbeat timeout → Dispatcher kills and retries. Normal Worker processing LLM call (up to 300s) → heartbeats continue during `receive`. |

#### Sub-Phase 17D: CLI Polish & Code Quality (3 tasks, P1)

| Task ID | Title | Acceptance Criteria | Key Tests |
|---------|-------|---------------------|----------|
| spark-ard.15 | Replace deprecated `System.shell/2` with `System.cmd/3` + timeout | `CLI.dispatch(%Command{type: :shell, ...})` uses `System.cmd("sh", ["-c", cmd], stderr_to_stdout: true, timeout: 15_000)`. Non-zero exit shows red output. Timeout rescued with `ErlangError` → "Command timed out" message. | `!ls` → lists files. `!sleep 20` → "Command timed out" after 15s. `!nonexistent_cmd` → red error output. |
| spark-ard.16 | Add `@spec` typespecs to all public functions across all modules | Every `def` function in public API modules gets `@spec`. Dialyzer passes with `--no-return` and `--no-opaque` flags. Typespecs cover: `Spark.Orchestrator`, `Spark.Worker`, `Spark.Dispatcher`, `Spark.CLI`, `Spark.EventBus`, `Spark.Policy`, `Spark.ToolRunner`, `Spark.LLM.Client`, `Spark.LLM.WaferProvider`, `Spark.State`. | `mix dialyzer` exits 0. No "The call will fail" warnings on public API. |
| spark-ard.17 | Add structured logging with `Logger.metadata` across all GenServers | Orchestrator: `Logger.metadata(session_id: ..., plan_id: ..., phase: ...)`. Worker: `Logger.metadata(worker_id: ..., task_id: ..., plan_id: ..., iteration: ...)`. Dispatcher: `Logger.metadata(plan_id: ..., queue_depth: ..., active: ...)`. WaferProvider: `Logger.metadata(provider: :wafer, model: ...)`. All `Logger.info/warn/error` calls capture metadata. | Log line `[info] Orchestrator: calling LLM` includes `session_id=sess_abc plan_id=plan_xyz phase=planning`. JSON log formatter shows all metadata keys. |

#### Sub-Phase 17E: Multi-Agent IPC Formalization (2 tasks, P2)

| Task ID | Title | Acceptance Criteria | Key Tests |
|---------|-------|---------------------|----------|
| spark-ard.18 | Formalize Planning Agent ↔ Coding Agent protocol as typed behaviour | New `Spark.AgentProtocol` behaviour: `@callback handle_task_request(TaskRequest.t()) :: {:ok, Task.t()} | {:error, term()}`, `@callback report_progress(Task.t(), Progress.t()) :: :ok`, `@callback report_completion(Task.t(), WorkerResult.t()) :: :ok`. New structs: `Spark.Types.TaskRequest` (id, plan_id, task_spec, context, timeout_ms) and `Spark.Types.Progress` (task_id, phase, detail, percent, timestamp). `Registry`-based agent discovery replaces `Process.whereis/1`. | Planning Agent sends `TaskRequest` via `Registry` lookup → Coding Agent receives, validates, enqueues. Progress reports (throttled to 1/sec) arrive at Planning Agent. Completion with `WorkerResult`. |
| spark-ard.19 | Replace hardcoded `Process.whereis/1` with Registry-based agent discovery | All cross-agent calls use `Spark.AgentProtocol.find/1` which queries `Spark.SessionRegistry` via `Registry.lookup/2`. Agents register on init with `Registry.register/3` keyed by `{session_id, :orchestrator}` and `{session_id, :dispatcher}`. Workers find Dispatcher via `{:via, Registry, {Spark.SessionRegistry, {session_id, :dispatcher}}}`. | Kill and restart Orchestrator → new PID registered under same key → Workers find new Orchestrator without config change. Multiple sessions isolated by `session_id` prefix. |

### Phase 18: TUI Dashboard Redesign — Full-Screen Canvas + Command Deck (`spark-dsh`, 10 tasks)

> **Source:** Elite TUI/UX Redesign by `planning-agent-3e8ed8` — full-screen harmonious dashboard with zero-flicker rendering.
> **Reference:** Python `fast_puppy/` Code Puppy planning agent methodology at `../fast_puppy/code_puppy/agents/agent_planning.py`.
> **Design Principle:** 85% Canvas (chat/plan/logs) + 15% Command Deck (input/status). Unicode box-drawing borders. ASCII art avatars. Pixel-perfect character-cell rendering.

#### Sub-Phase 18A: Layout Engine & Visual Foundation (3 tasks, P0)

| Task ID | Title | Acceptance Criteria | Key Tests |
|---------|-------|---------------------|----------|
| spark-dsh.1 | Create `Spark.TUI.Layout` — 85/15 Canvas + Command Deck split | Module provides `render_dashboard/2` that takes terminal `{width, height}` and two content functions (canvas_fn, deck_fn). Returns styled `TermUI` component tree. Top 85% wrapped in `┌─┐│└─┘` Unicode box with 2-char horizontal padding and 1-line vertical padding. Bottom 15% similarly bordered. Middle border line uses `├─┤` connector. Resize recalculates on every render via `TermUI.Terminal.width/height()`. Content clips to zone — never bleeds across borders. | 80×24 terminal: canvas = 20 rows, deck = 4 rows. 120×40: canvas = 34 rows, deck = 6 rows. Resize from 80×24 to 120×40 → both zones grow proportionally. No flickering during resize. |
| spark-dsh.2 | Create `Spark.TUI.Art` — ASCII banner, agent avatars, progress bars, spinners | `welcome_banner/0` returns multi-line styled ASCII art (Spark logo + puppy). `agent_avatar(:planning)` returns ASCII puppy face (8×5 char grid). `agent_avatar(:coding)` returns ASCII robot (8×5 char grid). `progress_bar(0..100, width)` returns `[████░░░░░░] 40%` with the bar scaled to width. `spinner(frame)` returns one of 8 spinner frames: `⠋⠙⠹⠸⠼⠴⠦⠧⠇`. `divider(:thick)` returns `━━━`, `divider(:thin)` returns `───`. All return `TermUI` styled components using `Spark.TermUI` style helpers. | Banner renders without line-wrap at 80 cols. Progress bar at 0% shows all `░`, at 100% shows all `█`. Spinner cycles through all 8 frames. Avatar fits within 8×5 grid. |
| spark-dsh.3 | Refactor `Spark.TUI.Model` for unified dashboard state | Replace `screen: :home` field with `view_mode: :welcome | :plan_review | :execution | :logs`. Replace `previous_screen` with `canvas_content` atom. Add `scroll_offset: 0`, `canvas_lines: []` (pre-rendered lines for scrolling), `command_mode: :chat | :approve | :agent_picker`, `command_hint: ""`, `spinner_frame: 0`, `banner_visible: true`. NOTE: `:navigate` mode was replaced with slash-command handling in the `:chat` Enter handler; `:agent_picker` is triggered by `/agents`. Remove `selected_index`, `selected_agent`, `selected_model_index` (fold into command deck state). Keep existing fields: `session_id`, `agents`, `agent_order`, `dashboard`, `active_plan`, `status_message`, `error_message`, `logs`, `input_buffer`, `loading?`, `selected_task_index`. | Model struct compiles. All existing tests that create `%Spark.TUI.Model{}` still pass (backward compat via defaults). New fields accessible. |

#### Sub-Phase 18B: Unified Canvas Rendering (2 tasks, P0)

| Task ID | Title | Acceptance Criteria | Key Tests |
|---------|-------|---------------------|----------|
| spark-dsh.4 | Rewrite `Spark.TermUI.view/1` to render unified canvas dashboard | Replace `view_content/1` screen dispatcher with `render_canvas_content/1`. For `:welcome`: agent status cards, runtime phase, slash command reference. For `:plan_review`: plan details with task list, selected task detail panel, status badge. For `:execution`: live dashboard with progress bar, active workers, recent events. For `:logs`: color-coded event log entries. ALL modes rendered via `stack(:vertical, canvas_lines ++ [separator] ++ deck_lines)` using native term_ui RenderNode tree (no manual border drawing — that caused rendering artifacts). Command deck shows input line with slash command reference bar. | Welcome screen shows ASCII art at top, command deck at bottom with blinking cursor. Plan review shows Markdown-rendered plan in canvas. Execution dashboard shows progress bars updating. Toggle between modes with single keys without flicker. |
| spark-dsh.5 | Rewrite `Spark.TUI.Update` for unified command-mode input handling | Remove screen-based pattern matching. Replace with `command_mode` dispatch: `:chat` → typing appends to `input_buffer`, Enter checks for slash command prefix (`/welcome /plan /exec /logs /dash /agents /help /quit /clear /approve /reject`); non-prefixed text submits as plan goal. `:approve` → A/R keys trigger approve/reject, ↑/↓ scrolls plan canvas. `:agent_picker` → triggered by `/agents` slash command. Esc always returns to `:chat`. q/Q ignored in chat mode to prevent accidental quit. | Typing "build a CLI tool" in chat mode → Enter → loading spinner appears → plan result renders in canvas. Up/down scrolls plan by 1 line. PgUp/PgDn scrolls by canvas height. `/agents` opens agent picker. `/plan` with active plan shows plan review. `/quit` quits. `/welcome` returns to welcome. `q` while typing is safe (ignored in chat mode). Typing a goal + Enter starts planning flow. |

#### Sub-Phase 18C: Scrolling & Dynamic Behavior (1 task, P0)

| Task ID | Title | Acceptance Criteria | Key Tests |
|---------|-------|---------------------|----------|
| spark-dsh.6 | Implement smooth scrolling and content overflow with scroll indicators | `render_canvas/1` pre-renders all plan/execution lines into `model.canvas_lines`. Calculates `visible_lines = canvas_height - 4` (accounting for padding). Only renders `Enum.slice(canvas_lines, scroll_offset, visible_lines)`. When `scroll_offset > 0`: show `  ▲ more above` indicator at top of canvas (dim style). When `scroll_offset + visible_lines < total_lines`: show `  ▼ more below` indicator at bottom. Auto-scroll to bottom on new content (`:execution` mode, `scroll_offset = max(0, total_lines - visible_lines)`). Mouse wheel events (if available via term_ui) adjust scroll. | Plan with 200 lines → canvas shows 20 lines at a time → scroll from line 0 to line 180 with smooth increments. Scroll indicators appear/disappear correctly at boundaries. New Worker event auto-scrolls to bottom. Manual scroll up pauses auto-scroll until user scrolls back to bottom. |

#### Sub-Phase 18D: Integration & Polish (4 tasks, P1)

| Task ID | Title | Acceptance Criteria | Key Tests |
|---------|-------|---------------------|----------|
| spark-dsh.7 | Wire planning agent handoff into orchestrator via GenServer message passing | When user presses `A` (approve) in `:approve` command_mode, `Spark.TUI.Actions.approve_plan/1` sends `GenServer.call(Orchestrator, {:approve_plan, plan_id})`. Orchestrator formats the approved plan as structured JSON (`%{objective: ..., phases: [...], risks: [...]}`) and sends it via `GenServer.cast(Dispatcher, {:enqueue_plan, plan_json})`. Dispatcher decomposes phases into individual Worker tasks. EventBus publishes `:plan_approved` and `:tasks_queued` events. TUI canvas switches to `:execution` mode automatically. | Approve plan → canvas switches to execution → progress bar appears → workers start. Event log shows task_queued events. Dispatcher receives structured plan JSON with correct task breakdown. |
| spark-dsh.8 | Update `mix.exs` and verify `term_ui` capability coverage | Audit `term_ui ~> 1.0-rc` for all needed features (dynamic resize events, raw mode, styled text with fg/bg/bold/dim, component stacking with `stack(:vertical, ...)`, Unicode output). If any missing, build shim in `Spark.TUI.Layout` using raw ANSI escape sequences as fallback. Document any workarounds. | `mix deps.get` succeeds. `mix compile` succeeds. Terminal resize triggers `:resized` event. Unicode box-drawing characters render correctly in iTerm2, Kitty, Terminal.app. |
| spark-dsh.9 | Write/update tests for new TUI modules | `test/spark/tui/layout_test.exs`: verify 85/15 split calculation, box-drawing border assembly, content clipping. `test/spark/tui/art_test.exs`: verify banner width, progress bar scaling, spinner cycle. `test/spark/tui/dashboard_test.exs`: update existing TUI tests for new model fields. `test/spark/tui/model_test.exs`: verify new struct defaults. All tests use `TermUI.Test` helpers if available, otherwise test pure rendering functions. | `mix test test/spark/tui/` — all pass. Coverage report shows >85% for new modules. No regression in existing tests. |
| spark-dsh.10 | QA review — pixel-perfect rendering across terminal sizes | Manual QA: launch TUI at 80×24, 120×40, 200×60. Verify: box borders align perfectly (no misaligned corners), ASCII art banner is centered, progress bars scale correctly, scroll indicators appear at boundaries, input cursor blinks in command deck, resize recalculates layout without artifacts, colors render correctly (cyan bold headers, green success, red errors, yellow warnings), no flickering on any terminal. Take screenshots at each size. | Visual inspection checklist passed. No layout bugs. Borders perfectly aligned. |

### Phase 19: Planning Agent System Prompt — "Code Puppy" Methodology (`spark-pup`, 4 tasks)

> **Source:** Deep investigation of `fast_puppy/code_puppy/agents/agent_planning.py` (Python reference) by `planning-agent-3e8ed8`.
> **Philosophy:** Read-only investigation → Huge exhaustive plan → Approval gate → Structured handoff. The Planning Agent NEVER writes code — it investigates, architects, and coordinates.

| Task ID | Title | Acceptance Criteria | Key Tests |
|---------|-------|---------------------|----------|
| spark-pup.1 | Create `Spark.Prompt.PlanningAgent` — the exact System Prompt module | Module `Spark.Prompt.PlanningAgent.system_prompt/0` returns the complete prompt string (see Part 2B of the implementation plan). Prompt enforces: (1) Read-only tools only: `list_files`, `read_file`, `grep`, `ask_user_question`, `list_agents`, `invoke_agent`, `list_or_search_skills`. CRITICAL: strictly FORBIDDEN from writing/editing/deleting files. (2) Deep context gathering: read relevant files, trace function calls, understand architecture before proposing. (3) "Huge Plan" generation: exhaustive step-by-step plan with exact file paths, specific functions to modify, edge cases, dependencies, testing strategy. Formatted in structured Markdown with emoji headings (🎯 OBJECTIVE, 📊 PROJECT ANALYSIS, 📋 EXECUTION PLAN, ⚠️ RISKS, 🔄 ALTERNATIVES, 🚀 NEXT STEPS). (4) Approval Gate: MUST stop and ask "Does this plan look good to you? Reply 'approve' to send to Coding Agent." (5) Handoff: format approved plan as structured JSON, pass via GenServer message to Coding Agent. Prompt includes Spark-specific knowledge (OTP patterns, module naming, test conventions). Agent identity: `planning-agent-3e8ed8`. | Prompt string is non-empty, contains all 5 rule sections, contains Spark-specific module references, includes read-only tool list. Prompt length between 2000-4000 tokens. |
| spark-pup.2 | Integrate prompt into `Spark.LLM.Client` and `Spark.Config` | Add config path `[:planning_agent, :system_prompt]` with default `Spark.Prompt.PlanningAgent.system_prompt/0`. `Spark.Config` supports `get([:planning_agent, :system_prompt])`. `Spark.LLM.Client` checks agent type when building messages: if agent is `:planning` (orchestrator actor), inject planning system prompt instead of default. Prompt supports hot reload via `:prompt_reloaded` event (re-read from config). User can override prompt via `~/.spark/prompts/planning_agent.md` with higher priority than default. | Orchestrator LLM call includes planning prompt. Config override respected. Hot reload changes prompt for next planning call. `mix test test/spark/llm/` passes. |
| spark-pup.3 | Create Python vs. Elixir comparison documentation | `docs/planning_agent_comparison.md` documents: how Python `fast_puppy/code_puppy/agents/agent_planning.py` handles planning (BaseAgent subclass, `get_system_prompt()`, tool restriction via `get_available_tools()`, invoke_agent handoff) vs. how Spark handles it (prompt in `Spark.Prompt.PlanningAgent`, tool restriction via prompt + `Spark.ToolRegistry`, GenServer message passing handoff). Includes a table mapping Python concepts to Elixir equivalents. | Document is well-formatted Markdown, contains comparison table, references exact file paths in both codebases. |
| spark-pup.4 | Test prompt rendering in TUI canvas + end-to-end planning flow | Integration test: `test/spark/integration/planning_prompt_e2e_test.exs`. Uses `Spark.LLM.MockProvider` with a pre-canned planning response in the structured Markdown format. Verifies: (1) Orchestrator receives planning prompt (assert prompt contains "Read-Only Investigation"), (2) Mock LLM returns plan with 🎯📊📋⚠️🔄🚀 headings, (3) Plan parsed by `Spark.PlanParser` extracts phases and tasks correctly, (4) TUI canvas renders plan Markdown with correct styling (headings in cyan bold, checkboxes styled, code fences dimmed). Also: `test/spark/prompt/planning_agent_prompt_test.exs` verifies prompt structure (all 5 sections present, no write tools mentioned). | E2E test: goal → planning prompt injected → mock returns structured plan → parsed into `Spark.Types.Plan` → rendered in TUI canvas with correct styling. Prompt test: all 5 rule sections present, read-only tools verified, Spark-specific references present. |

---

### Architecture Review Summary

| Category | Before (v4.0) | After (v4.1 with spark-ard) |
|----------|--------------|---------------------------|
| GenServer Responsiveness | 300s mailbox blocking | < 1ms for all `handle_call` responses |
| Memory Growth | Unbounded `history` list | Capped at 50 entries + Silver compaction |
| IPC Overhead | `GenServer.call` Worker→Dispatcher | `cast` + EventBus acknowledgment |
| HTTP Connections | Fresh TCP+TLS per request | Finch pool with keep-alive |
| Streaming Backpressure | None (mailbox flood) | GenStage demand-driven pipeline |
| Fault Recovery | Flat `:one_for_one`, no checkpointing | `:rest_for_one` + 30s disk checkpoints |
| Error Handling | Blanket `try/rescue` | Narrow rescue, let-it-crash for bugs |
| CLI Shutdown | Immediate exit, orphaned Workers | 5s drain + log flush + connection close |
| Typespecs | ~5% coverage | 100% public API coverage |

---

*Filed by `planning-agent-3e8ed8` via Principal Architect Review — 2025.*

---

## Hot Reload Contracts Summary

Every reloadable component must define:
- **What triggers reload** (file/config change)
- **Scope** (running processes vs future calls only)
- **Validation** (how to check before applying)
- **Rollback** (how to restore on failure)
- **Event emitted** (on EventBus)
- **Memory record** (written to Bronze)

| Component | Trigger | Scope | Validation | Rollback | Event |
|-----------|---------|-------|-------------|----------|-------|
| Prompts | ~/.spark/prompts/*.md change | Future LLM calls only | Readable, non-empty | Keep previous prompt | :prompt_reloaded |
| Config | ~/.spark/config.json change | Future settings only | Valid JSON, known fields | Keep old config | :config_reloaded |
| Tools | ~/.spark/tools/*.ex change | New Workers only | Compiles, implements Spark.Tool | Keep previous module | :tool_reloaded |
| Policy | ~/.spark/policy/*.json change | Future validations | Valid known fields | Keep old policy | :policy_reloaded |
| Guidance | ~/.spark/guidance/*.md change | Future injections | Valid markdown | Keep old guidance | :guidance_reloaded |
| Orchestrator code | Dev mode .ex change | Preserves state via code_change/3 | State migration | Keep old state, report failure | :hot_reload_completed/failed |

---

## Development Constraints

1. **No external agent frameworks** — OTP primitives only
2. **Allowed deps:** Req, Jason, Floki, Phoenix.PubSub, standard Elixir/Erlang
3. **Explicit GenServer message passing** — no callback-heavy abstractions
4. **Every module testable independently**
5. **Every phase includes tests**
6. **Every reloadable module includes hot reload acceptance criteria**
7. **Static prefix must stay stable** — never append volatile data
8. **Workers are disposable** — receive task + context, return structured result
9. **Planning Agent is read-only** — `Spark.Prompt.PlanningAgent` enforces no-write policy via prompt. Planning agent investigates codebase, generates exhaustive plans in structured Markdown with 🎯📊📋⚠️🔄🚀 format, gates on user approval, and hands off structured JSON to Coding Agent via GenServer message passing.

---

*Filed by `planning-agent-754a5d` via `bd` — the beads issue tracker.*
