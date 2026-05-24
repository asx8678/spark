defmodule Spark.ToolRegistry do
  @moduledoc """
  GenServer-backed registry for Spark tools.

  Stores tool modules with metadata, enforces unique names,
  and provides lookup / listing / schema aggregation for LLM consumers.

  ## Registration

    - `register/2` — register a tool module with metadata; rejects duplicate
      names unless `replace: true` is passed in metadata.
    - `unregister/1` — remove a tool by name.

  ## Lookup

    - `lookup/1` — find a registered tool by name.
    - `list/0` — all registered tools with metadata.
    - `schemas/0` — aggregated schemas for LLM tool-calling.
    - `version/1` — registration version (incremented on each register/replace).
  """

  use GenServer

  @registry_name __MODULE__

  # --- Client API ---

  @doc """
  Starts the ToolRegistry GenServer.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @registry_name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Registers a tool module under its name with optional metadata.

  Returns `:ok` on success, `{:error, {:already_registered, name}}` if the
  name is taken unless `replace: true` is in metadata.

  Metadata keys:
    - `:replace` — if `true`, overwrites an existing registration.
    - `:version` — auto-incremented; override only if you know what you're doing.
    - Any other keys are stored alongside the tool for later retrieval.
  """
  @spec register(module(), keyword() | map()) :: :ok | {:error, term()}
  def register(module, metadata \\ []) do
    GenServer.call(@registry_name, {:register, module, metadata})
  end

  @doc """
  Unregisters a tool by name.

  Returns `:ok` whether or not the tool was registered.
  """
  @spec unregister(String.t()) :: :ok
  def unregister(tool_name) do
    GenServer.call(@registry_name, {:unregister, tool_name})
  end

  @doc """
  Looks up a registered tool by name.

  Returns `{:ok, %{module: module, metadata: metadata}}` or `{:error, {:not_found, name}}`.
  """
  @spec lookup(String.t()) :: {:ok, map()} | {:error, term()}
  def lookup(tool_name) do
    GenServer.call(@registry_name, {:lookup, tool_name})
  end

  @doc """
  Lists all registered tools with their metadata.

  Returns a map of `%{tool_name => %{module: module, metadata: metadata, version: version}}`.
  """
  @spec list() :: map()
  def list do
    GenServer.call(@registry_name, :list)
  end

  @doc """
  Returns all tool schemas aggregated for LLM tool-calling.

  Returns a list of `%{name: name, description: desc, schema: schema, risk: risk}`.
  """
  @spec schemas() :: [map()]
  def schemas do
    GenServer.call(@registry_name, :schemas)
  end

  @doc """
  Returns the registration version for a tool.

  Versions start at 1 and increment on each register (or replace).
  Returns `{:error, {:not_found, name}}` if the tool is not registered.
  """
  @spec version(String.t()) :: {:ok, pos_integer()} | {:error, term()}
  def version(tool_name) do
    GenServer.call(@registry_name, {:version, tool_name})
  end

  @doc """
  Registers all built-in Spark tools.

  Called automatically during application startup. Idempotent —
  skips tools that are already registered.
  """
  @spec register_defaults() :: :ok
  def register_defaults do
    for mod <- default_tool_modules() do
      try do
        # Use replace: true so re-registration (e.g. hot reload) doesn't fail
        case register(mod, replace: true) do
          :ok -> :ok
          {:error, {:already_registered, _}} -> :ok
          {:error, _} -> :ok
        end
      rescue
        _ -> :ok
      end
    end

    :ok
  end

  @doc """
  Returns the list of built-in tool modules.
  """
  @spec default_tool_modules() :: [module()]
  def default_tool_modules do
    [
      Spark.Tools.ReadFile,
      Spark.Tools.WriteFile,
      Spark.Tools.EditFile,
      Spark.Tools.ListDir,
      Spark.Tools.Glob,
      Spark.Tools.Grep,
      Spark.Tools.Bash,
      Spark.Tools.WebFetch,
      Spark.Tools.WebSearch,
      Spark.Tools.CreateAndLoadTool
    ]
  end

  @doc """
  Returns OpenAI-compatible function tool schemas for all registered tools.

  Each entry: `%{type: "function", function: %{name: name, description: desc, parameters: schema}}`
  Suitable for passing as the `:tools` field in LLM completion requests.
  """
  @spec openai_schemas() :: [map()]
  def openai_schemas do
    GenServer.call(@registry_name, :openai_schemas)
  end

  @doc """
  Clears all registered tools and versions. Useful for test cleanup.
  """
  @spec clear() :: :ok
  def clear do
    GenServer.call(@registry_name, :clear)
  end

  # --- GenServer callbacks ---

  @impl true
  def init(opts) do
    # Register default tools during startup (safe even if called multiple times)
    state = %{tools: %{}, versions: %{}}

    if Keyword.get(opts, :register_defaults, true) do
      # Schedule registration after init returns so the GenServer is fully started
      send(self(), :register_defaults)
    end

    {:ok, state}
  end

  @impl true
  def handle_call({:register, module, metadata}, _from, state) do
    unless Spark.Tool.implements?(module) do
      {:reply, {:error, {:not_a_tool, module}}, state}
    else
      tool_name = module.name()
      replace? = get_in(Enum.into(metadata, %{}), [:replace]) || false

      case Map.get(state.tools, tool_name) do
        nil ->
          version = Map.get(state.versions, tool_name, 0) + 1
          entry = %{module: module, metadata: normalize_metadata(metadata), version: version}
          state = put_in(state.tools[tool_name], entry)
          state = put_in(state.versions[tool_name], version)
          {:reply, :ok, state}

        _existing when replace? ->
          version = Map.get(state.versions, tool_name, 0) + 1
          entry = %{module: module, metadata: normalize_metadata(metadata), version: version}
          state = put_in(state.tools[tool_name], entry)
          state = put_in(state.versions[tool_name], version)
          {:reply, :ok, state}

        _existing ->
          {:reply, {:error, {:already_registered, tool_name}}, state}
      end
    end
  end

  @impl true
  def handle_call({:unregister, tool_name}, _from, state) do
    state = update_in(state.tools, &Map.delete(&1, tool_name))
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:lookup, tool_name}, _from, state) do
    case Map.get(state.tools, tool_name) do
      nil -> {:reply, {:error, {:not_found, tool_name}}, state}
      entry -> {:reply, {:ok, entry}, state}
    end
  end

  @impl true
  def handle_call(:list, _from, state) do
    {:reply, state.tools, state}
  end

  @impl true
  def handle_call(:schemas, _from, state) do
    schemas =
      state.tools
      |> Enum.map(fn {_name, %{module: mod}} ->
        %{
          name: mod.name(),
          description: mod.description(),
          schema: mod.schema(),
          risk: mod.risk()
        }
      end)

    {:reply, schemas, state}
  end

  @impl true
  def handle_call({:version, tool_name}, _from, state) do
    case Map.get(state.versions, tool_name) do
      nil -> {:reply, {:error, {:not_found, tool_name}}, state}
      v -> {:reply, {:ok, v}, state}
    end
  end

  @impl true
  def handle_call(:clear, _from, _state) do
    {:reply, :ok, %{tools: %{}, versions: %{}}}
  end

  @impl true
  def handle_call(:openai_schemas, _from, state) do
    schemas =
      state.tools
      |> Enum.map(fn {_name, %{module: mod}} ->
        %{
          type: "function",
          function: %{
            name: mod.name(),
            description: mod.description(),
            parameters: mod.schema()
          }
        }
      end)

    {:reply, schemas, state}
  end

  @impl true
  def handle_info(:register_defaults, state) do
    new_state =
      Enum.reduce(Spark.ToolRegistry.default_tool_modules(), state, fn mod, acc ->
        try do
          case Spark.Tool.implements?(mod) do
            true ->
              tool_name = mod.name()
              version = Map.get(acc.versions, tool_name, 0) + 1
              entry = %{module: mod, metadata: %{}, version: version}
              acc = put_in(acc.tools[tool_name], entry)
              put_in(acc.versions[tool_name], version)

            false ->
              acc
          end
        rescue
          _ -> acc
        end
      end)

    {:noreply, new_state}
  end

  # --- Private helpers ---

  defp normalize_metadata(metadata) when is_map(metadata), do: metadata
  defp normalize_metadata(metadata) when is_list(metadata), do: Enum.into(metadata, %{})
end
