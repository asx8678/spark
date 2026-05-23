defmodule Spark.HotReload.Coordinator do
  @moduledoc """
  GenServer orchestrating the hot reload lifecycle.

  Coordinates validation, reload, and rollback across all component types.
  Uses Spark.HotReload.Validator for validation, Spark.HotReload.Manifest
  for version tracking, and Spark.HotReload.Rollback for failure recovery.

  Since EventBus isn't built yet (Phase 3), events are logged and stored
  in Coordinator state for status queries.
  """

  use GenServer

  require Logger

  @type reload_status :: :idle | :reloading | :success | :failed

  @type reload_result :: %{
          type: atom(),
          component_key: {atom(), atom() | String.t()} | nil,
          status: :success | :failed,
          timestamp: DateTime.t(),
          error: term() | nil,
          path: String.t() | nil
        }

  defstruct last_reload: nil,
            reload_count: 0,
            status: :idle

  # Public API

  @doc """
  Starts the Coordinator GenServer.
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Reloads all components of a given type.

  Types: `:prompts`, `:tools`, `:config`, `:policy`, `:guidance`
  """
  def reload(type) when type in [:prompts, :tools, :config, :policy, :guidance] do
    GenServer.call(__MODULE__, {:reload_type, type}, 30_000)
  end

  @doc """
  Reloads a specific file, auto-detecting the component type from the path.
  """
  def reload_file(path) when is_binary(path) do
    GenServer.call(__MODULE__, {:reload_file, path}, 30_000)
  end

  @doc """
  Returns current Coordinator status including last reload result.
  """
  def status do
    GenServer.call(__MODULE__, :status)
  end

  @doc """
  Resets the Coordinator state (useful for testing).
  """
  def reset do
    GenServer.call(__MODULE__, :reset)
  end

  # GenServer callbacks

  @impl true
  def init(_opts) do
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_call({:reload_type, type}, _from, state) do
    result = do_reload_type(type)
    new_state = %{state | last_reload: result, reload_count: state.reload_count + 1,
                          status: if(result.status == :success, do: :success, else: :failed)}
    {:reply, {:ok, result}, new_state}
  end

  @impl true
  def handle_call({:reload_file, path}, _from, state) do
    result = do_reload_file(path)
    new_state = %{state | last_reload: result, reload_count: state.reload_count + 1,
                          status: if(result.status == :success, do: :success, else: :failed)}
    {:reply, {:ok, result}, new_state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      status: state.status,
      reload_count: state.reload_count,
      last_reload: state.last_reload
    }
    {:reply, status, state}
  end

  @impl true
  def handle_call(:reset, _from, _state) do
    {:reply, :ok, %__MODULE__{}}
  end

  # --- Private implementation ---

  defp do_reload_type(type) do
    Logger.info("HotReload: starting reload of type #{type}")
    now = DateTime.utc_now()

    home = Spark.Config.home_dir()
    paths = find_paths_for_type(type, home)

    results =
      Enum.map(paths, fn path ->
        do_reload_file(path)
      end)

    failed = Enum.filter(results, &(&1.status == :failed))

    if Enum.empty?(failed) do
      %{type: type, component_key: nil, status: :success, timestamp: now,
        error: nil, path: nil}
    else
      %{type: type, component_key: nil, status: :failed, timestamp: now,
        error: {:partial_failures, length(failed), length(results)}, path: nil}
    end
  end

  defp do_reload_file(path) do
    Logger.info("HotReload: starting reload of file #{path}")
    now = DateTime.utc_now()

    component_key = detect_component_key(path)

    # Step 1: Validate
    case Spark.HotReload.Validator.validate_file(path) do
      :ok ->
        # Step 2: Apply reload
        case apply_reload(path, component_key) do
          {:ok, _entry} ->
            Logger.info("HotReload: completed reload of #{path}")
            %{type: elem(component_key, 0), component_key: component_key,
              status: :success, timestamp: DateTime.utc_now(), error: nil, path: path}

          {:error, reason} ->
            # Step 3: Rollback on failure
            Logger.warning("HotReload: reload failed for #{path}: #{inspect(reason)}")
            Spark.HotReload.Rollback.rollback(component_key, reason)

            %{type: elem(component_key, 0), component_key: component_key,
              status: :failed, timestamp: DateTime.utc_now(), error: reason, path: path}
        end

      {:error, reason} ->
        Logger.warning("HotReload: validation failed for #{path}: #{inspect(reason)}")

        # Don't rollback if validation fails — nothing was applied yet
        %{type: detect_type_from_path(path), component_key: component_key,
          status: :failed, timestamp: now, error: reason, path: path}
    end
  end

  defp apply_reload(path, {component_type, name} = component_key) do
    hash = compute_file_hash(path)

    metadata = %{
      version: generate_version(),
      hash: hash,
      path: path
    }

    component_map = %{
      component: component_type,
      name: name,
      path: path,
      version: metadata.version,
      hash: hash
    }

    # For tools, try to compile
    if component_type == :tool do
      case Spark.HotReload.Compiler.compile_tool(path) do
        {:ok, module} ->
          component_map = Map.put(component_map, :module, module)
          update_or_register(component_key, component_map, metadata)

        {:error, reason} ->
          {:error, reason}
      end
    else
      update_or_register(component_key, component_map, metadata)
    end
  end

  defp update_or_register(component_key, component_map, metadata) do
    if Spark.HotReload.Manifest.exists?(component_key) do
      Spark.HotReload.Manifest.update(component_key, metadata)
    else
      Spark.HotReload.Manifest.register(component_map)
    end
  end

  defp detect_component_key(path) do
    cond do
      String.contains?(path, "/prompts/") ->
        {:prompt, Path.basename(path, ".md") |> String.to_atom()}

      String.contains?(path, "/tools/") ->
        {:tool, Path.basename(path, ".ex")}

      String.contains?(path, "config.json") ->
        {:config, :runtime}

      String.contains?(path, "/policy/") ->
        {:policy, :main}

      String.contains?(path, "/guidance/") ->
        {:guidance, Path.basename(path, ".md") |> String.to_atom()}

      true ->
        {:unknown, Path.basename(path)}
    end
  end

  defp detect_type_from_path(path) do
    cond do
      String.contains?(path, "/prompts/") -> :prompt
      String.contains?(path, "/tools/") -> :tool
      String.contains?(path, "config.json") -> :config
      String.contains?(path, "/policy/") -> :policy
      String.contains?(path, "/guidance/") -> :guidance
      true -> :unknown
    end
  end

  defp find_paths_for_type(:prompts, home) do
    find_files(Path.join(home, "prompts"), "*.md")
  end

  defp find_paths_for_type(:tools, home) do
    find_files(Path.join(home, "tools"), "*.ex")
  end

  defp find_paths_for_type(:config, home) do
    path = Path.join(home, "config.json")
    if File.exists?(path), do: [path], else: []
  end

  defp find_paths_for_type(:policy, home) do
    find_files(Path.join(home, "policy"), "*.json")
  end

  defp find_paths_for_type(:guidance, home) do
    find_files(Path.join(home, "guidance"), "*.md")
  end

  defp find_files(dir, pattern) do
    if File.dir?(dir) do
      Path.wildcard(Path.join(dir, "**/#{pattern}"))
    else
      []
    end
  end

  defp compute_file_hash(path) do
    case File.read(path) do
      {:ok, content} ->
        :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

      {:error, _} ->
        ""
    end
  end

  defp generate_version do
    ts = DateTime.utc_now() |> DateTime.to_iso8601()
    rand = :crypto.strong_rand_bytes(4) |> Base.url_encode64(padding: false)
    "#{ts}-#{rand}"
  end
end
