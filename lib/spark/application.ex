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
    - Spark.Guidance (GenServer)
    - Spark.ToolSupervisor (Task.Supervisor)
    - Spark.WorkerSupervisor (DynamicSupervisor)
    - Spark.Dispatcher (GenServer, prod only)
    - Spark.Orchestrator (GenServer, prod only)
  """

  use Application

  @impl true
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

          # Guidance system (spark-31u.1)
          {Spark.Guidance, []},

          # Dispatcher (spark-u4b.1–u4b.6)
          {Spark.Dispatcher, []},

          # Orchestrator (spark-anh.1–anh.6)
          {Spark.Orchestrator, []}
        ]
      end

    children =
      [
        # Registries
        {Registry, keys: :unique, name: Spark.SessionRegistry},
        # spark-pl3.2: ToolRegistry as GenServer
        {Spark.ToolRegistry, []},

        # PubSub (spark-bny.1)
        {Phoenix.PubSub, name: Spark.PubSub},

        # Config & secrets (spark-ega.6, spark-ega.7) — idempotent start
        maybe_agent_child(Spark.Config),
        maybe_agent_child(Spark.Policy),
        maybe_agent_child(Spark.Prompt.Store),

        # Tool execution (spark-pl3.3)
        {Task.Supervisor, name: Spark.ToolSupervisor},

        # Worker pool (spark-pvp.1)
        {DynamicSupervisor, name: Spark.WorkerSupervisor, strategy: :one_for_one,
         max_restarts: 100, max_seconds: 5}
      ] ++ prod_children

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
