defmodule Spark.Application do
  @moduledoc """
  Spark v4.0 Application supervision tree.

  Full OTP tree per spark-ega.8:
    - Spark.SessionRegistry (unique Registry)
    - Spark.ToolRegistry (GenServer)
    - Spark.PubSub (Phoenix.PubSub)
    - Spark.Config (Agent, auto-starts if needed)
    - Spark.Policy (Agent, auto-starts if needed)
    - Spark.Prompt.Store (Agent, auto-starts if needed)
    - Spark.HotReload.Manifest (GenServer)
    - Spark.HotReload.Coordinator (GenServer)
    - Spark.HotReload.Watcher (GenServer, conditional)
    - Spark.Workspace.LockManager (GenServer)
    - Spark.ExecutionSupervisor (:rest_for_one subtree, prod only)
      - Spark.Guidance (GenServer)
      - Spark.Dispatcher (GenServer)
      - Spark.Orchestrator (GenServer)
    - Spark.ToolSupervisor (Task.Supervisor)
    - Spark.WorkerSupervisor (DynamicSupervisor)
  """

  use Application

  @impl true
  @spec start(Application.start_type(), term()) :: {:ok, pid()} | {:error, term()}
  def start(_type, _args) do
    # Ensure home directory exists on boot
    Spark.Config.ensure_home!()

    hot_reload_enabled =
      Spark.Config.get([:hot_reload, :enabled], true) in [true, "true"]

    test_env? = Mix.env() == :test

    # In test, most GenServers need fresh state per test, so they're
    # started manually by test setup.  In prod/dev, they're supervised
    # here for fault tolerance and clean boot.
    prod_children =
      if test_env? do
        []
      else
        [
          # Agent & Model Manager (spark-a8m)
          {Spark.AgentManager, []},

          # Hot reload subsystem (spark-1uu.1–1uu.7)
          {Spark.HotReload.Manifest, []},
          {Spark.HotReload.Coordinator, []},
          {Spark.HotReload.Watcher, [enabled: hot_reload_enabled]},

          # Workspace safety (spark-57y.1)
          {Spark.Workspace.LockManager, []},

          # Execution subtree: Guidance → Dispatcher → Orchestrator
          # :rest_for_one — if Dispatcher crashes, Orchestrator restarts
          # too (re-syncs state). See Spark.ExecutionSupervisor.
          {Spark.ExecutionSupervisor, []}
        ]
      end

    children =
      [
        # Registries
        {Registry, keys: :unique, name: Spark.SessionRegistry},
        # spark-pl3.2: ToolRegistry as GenServer (registers built-in tools on init)
        {Spark.ToolRegistry, [register_defaults: true]},

        # PubSub (spark-bny.1)
        {Phoenix.PubSub, name: Spark.PubSub},

        # HTTP connection pool — starts in all envs so LLM calls work
        {Finch,
         name: Spark.FinchPool,
         pools: %{
           "https://pass.wafer.ai" => [
             size: 20,
             conn_opts: [timeout: 15_000]
           ],
           default: [
             size: 10,
             conn_opts: [timeout: 15_000]
           ]
         },
         pool_timeout: 10_000},

        # LLM resilience: circuit breaker + rate limiter (ETS table owners)
        {Spark.LLM.CircuitBreaker, []},
        {Spark.LLM.RateLimiter, []},

        # Config & secrets (spark-ega.6, spark-ega.7) — idempotent start
        maybe_agent_child(Spark.Config),
        maybe_agent_child(Spark.Config.Secrets),
        maybe_agent_child(Spark.Policy),
        maybe_agent_child(Spark.Prompt.Store),

        # Tool execution (spark-pl3.3)
        {Task.Supervisor, name: Spark.ToolSupervisor},

        # Worker pool (spark-pvp.1)
        {DynamicSupervisor,
         name: Spark.WorkerSupervisor, strategy: :one_for_one, max_restarts: 100, max_seconds: 5}
      ] ++ prod_children

    # Shutdown order: children terminate in reverse start order when the
    # supervisor stops. Within the ExecutionSupervisor subtree, Orchestrator
    # drains first, then Dispatcher, then Guidance — ensuring workers finish
    # before their dispatcher.  For graceful TUI shutdown, Spark.Dispatcher.drain/1
    # is called explicitly before the supervisor tears down.
    opts = [strategy: :one_for_one, name: Spark.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Child spec that tolerates an already-started Agent (e.g. lazy-started
  # by ensure_agent_started during boot). Uses :temporary restart
  # so the supervisor doesn't try to restart it on exit.
  defp maybe_agent_child(mod) do
    %{
      id: mod,
      start: {mod, :start_link, []},
      type: :worker,
      restart: :temporary
    }
  end
end
