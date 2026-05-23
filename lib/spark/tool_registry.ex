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
  Clears all registered tools and versions. Useful for test cleanup.
  """
  @spec clear() :: :ok
  def clear do
    GenServer.call(@registry_name, :clear)
  end

  # --- GenServer callbacks ---

  @impl true
  def init(_opts) do
    {:ok, %{tools: %{}, versions: %{}}}
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

  # --- Private helpers ---

  defp normalize_metadata(metadata) when is_map(metadata), do: metadata
  defp normalize_metadata(metadata) when is_list(metadata), do: Enum.into(metadata, %{})
end
