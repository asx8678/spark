defmodule Spark.HotReload.Watcher do
  @moduledoc """
  GenServer that polls configured paths for changes and triggers reloads.

  No external file watching dependency — uses Process.send_after polling.

  Watched paths (relative to Spark home):
    - config.json
    - prompts/**/*.md
    - tools/**/*.ex
    - policy/**/*.json
    - guidance/**/*.md
    - lib/spark/**/*.ex (dev mode only)

  Ignored patterns: *.tmp, *.swp, *.bak, .DS_Store

  Config from Spark.Config:
    hot_reload.enabled — whether to watch
    hot_reload.mode — :dev enables lib/spark watching
    hot_reload.poll_interval_ms — how often to poll
  """

  use GenServer

  require Logger

  @ignored_patterns ~w(.tmp .swp .bak .DS_Store)
  @debounce_ms 500

  defstruct [
    :timer_ref,
    file_index: %{},
    debounce_map: %{},
    enabled: true,
    poll_interval_ms: 1000,
    mode: :dev
  ]

  # Public API

  @doc """
  Starts the Watcher GenServer.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Forces an immediate scan of all watched paths.
  """
  @spec scan() :: {:ok, map()}
  def scan do
    GenServer.call(__MODULE__, :scan)
  end

  @doc """
  Returns the current file index.
  """
  @spec index() :: map()
  def index do
    GenServer.call(__MODULE__, :index)
  end

  @doc """
  Enables the watcher (starts polling).
  """
  @spec enable() :: :ok
  def enable do
    GenServer.call(__MODULE__, :enable)
  end

  @doc """
  Disables the watcher (stops polling).
  """
  @spec disable() :: :ok
  def disable do
    GenServer.call(__MODULE__, :disable)
  end

  @doc """
  Returns whether the watcher is currently enabled.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    GenServer.call(__MODULE__, :enabled?)
  end

  # GenServer callbacks

  @impl true
  def init(_opts) do
    enabled = Spark.Config.get([:hot_reload, :enabled], true)
    poll_interval = Spark.Config.get([:hot_reload, :poll_interval_ms], 1000)
    mode = Spark.Config.get([:hot_reload, :mode], :dev)

    state = %__MODULE__{
      enabled: enabled,
      poll_interval_ms: poll_interval,
      mode: if(is_binary(mode), do: String.to_atom(mode), else: mode)
    }

    state = if state.enabled, do: schedule_poll(state), else: state

    # Build initial index on startup
    state =
      if state.enabled do
        %{state | file_index: build_index(state)}
      else
        state
      end

    {:ok, state}
  end

  @impl true
  def handle_call(:scan, _from, state) do
    new_index = build_index(state)
    changes = detect_changes(state.file_index, new_index)
    # For manual scan, skip debounce and trigger all changes directly
    all_paths = changes.added ++ changes.modified ++ changes.removed
    trigger_reloads_direct(all_paths, state)

    {:reply, {:ok, changes}, %{state | file_index: new_index}}
  end

  @impl true
  def handle_call(:index, _from, state) do
    {:reply, state.file_index, state}
  end

  @impl true
  def handle_call(:enable, _from, state) do
    new_state = %{state | enabled: true}
    new_state = schedule_poll(new_state)
    new_state = %{new_state | file_index: build_index(new_state)}
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:disable, _from, state) do
    new_state = cancel_poll(%{state | enabled: false})
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:enabled?, _from, state) do
    {:reply, state.enabled, state}
  end

  @impl true
  def handle_info(:poll, state) do
    if state.enabled do
      new_index = build_index(state)
      changes = detect_changes(state.file_index, new_index)

      # Apply debounce
      {_debounced_result, to_reload, new_debounce} =
        apply_debounce(changes, state.debounce_map, state.poll_interval_ms)

      trigger_reloads_direct(to_reload, state)

      new_state = %{state | file_index: new_index, debounce_map: new_debounce}
      new_state = schedule_poll(new_state)
      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  # --- Private helpers ---

  defp schedule_poll(state) do
    cancel_poll(state)
    ref = Process.send_after(self(), :poll, state.poll_interval_ms)
    %{state | timer_ref: ref}
  end

  defp cancel_poll(%{timer_ref: nil} = state), do: state

  defp cancel_poll(%{timer_ref: ref} = state) do
    Process.cancel_timer(ref)
    %{state | timer_ref: nil}
  end

  defp build_index(state) do
    home = Spark.Config.home_dir()

    paths = watch_paths(home, state.mode)
    ignored = @ignored_patterns

    Enum.flat_map(paths, fn pattern ->
      Path.wildcard(pattern)
      |> Enum.reject(fn path -> ignored_file?(path, ignored) end)
      |> Enum.map(fn path -> {path, file_stat(path)} end)
    end)
    |> Map.new()
  end

  defp watch_paths(home, mode) do
    base = [
      Path.join(home, "config.json"),
      Path.join(home, "prompts/**/*.md"),
      Path.join(home, "tools/**/*.ex"),
      Path.join(home, "policy/**/*.json"),
      Path.join(home, "guidance/**/*.md")
    ]

    if mode == :dev do
      # Dev mode: also watch lib/spark
      project_lib = Path.join(File.cwd!() || ".", "lib/spark/**/*.ex")
      [project_lib | base]
    else
      base
    end
  end

  defp ignored_file?(path, patterns) do
    basename = Path.basename(path)

    Enum.any?(patterns, fn pattern ->
      String.ends_with?(basename, pattern)
    end)
  end

  defp file_stat(path) do
    case File.stat(path) do
      {:ok, stat} ->
        hash = compute_hash(path)

        %{
          mtime: stat.mtime,
          size: stat.size,
          hash: hash
        }

      {:error, _} ->
        nil
    end
  end

  defp compute_hash(path) do
    case File.read(path) do
      {:ok, content} ->
        :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

      {:error, _} ->
        ""
    end
  end

  defp detect_changes(old_index, new_index) do
    old_paths = Map.keys(old_index)
    new_paths = Map.keys(new_index)

    # New files
    added = new_paths -- old_paths

    # Removed files
    removed = old_paths -- new_paths

    # Modified files (hash or mtime changed)
    modified =
      Enum.filter(old_paths -- removed, fn path ->
        old_stat = Map.get(old_index, path)
        new_stat = Map.get(new_index, path)

        old_stat != nil and new_stat != nil and
          (old_stat.hash != new_stat.hash or old_stat.mtime != new_stat.mtime)
      end)

    %{added: added, modified: modified, removed: removed}
  end

  defp apply_debounce(
         %{added: added, modified: modified, removed: removed} = _changes,
         debounce_map,
         _poll_interval
       ) do
    now = System.monotonic_time(:millisecond)

    all_changed = added ++ modified ++ removed

    {to_reload, new_debounce} =
      Enum.reduce(all_changed, {[], debounce_map}, fn path, {reload_acc, debounce_acc} ->
        last_change = Map.get(debounce_acc, path, 0)
        elapsed = now - last_change

        if elapsed >= @debounce_ms do
          {reload_acc ++ [path], Map.put(debounce_acc, path, now)}
        else
          # Debounced — skip this change for now
          {reload_acc, debounce_acc}
        end
      end)

    {%{added: added, modified: modified, removed: removed}, to_reload, new_debounce}
  end

  defp trigger_reloads_direct(paths, state) do
    if state.enabled and paths != [] do
      Logger.info("HotReload.Watcher: triggering reload for #{length(paths)} file(s)")

      Enum.each(paths, fn path ->
        Logger.info("HotReload.Watcher: triggering reload for #{path}")
        Spark.HotReload.Coordinator.reload_file(path)
      end)
    end
  end
end
