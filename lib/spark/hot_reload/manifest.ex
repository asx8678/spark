defmodule Spark.HotReload.Manifest do
  @moduledoc """
  ETS-backed state store tracking reloadable component versions.

  Each manifest entry tracks the active and previous version of a
  reloadable component, enabling rollback on failed reloads.

  Component keys are tuples like `{:prompt, :orchestrator}`,
  `{:tool, "grep"}`, `{:config, :runtime}`, etc.
  """

  use GenServer

  @table :spark_hot_reload_manifest

  # Public API

  @doc """
  Starts the Manifest GenServer.
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Registers a new component in the manifest.
  `component_map` must include `:component` and `:name` keys.
  Additional fields: `:module`, `:path`, `:version`, `:hash`, `:metadata`.
  """
  def register(component_map) do
    GenServer.call(__MODULE__, {:register, component_map})
  end

  @doc """
  Updates an existing component. Moves current entry to `previous`
  and stores the new metadata as active.
  """
  def update(component_key, metadata) do
    GenServer.call(__MODULE__, {:update, component_key, metadata})
  end

  @doc """
  Gets the active version of a component by key.
  Returns nil if not found.
  """
  def get(component_key) do
    case :ets.lookup(@table, component_key) do
      [{^component_key, entry}] -> entry
      [] -> nil
    end
  end

  @doc """
  Lists all active components in the manifest.
  """
  def list do
    :ets.tab2list(@table)
    |> Enum.map(fn {_key, entry} -> entry end)
  end

  @doc """
  Gets the previous version of a component for rollback.
  Returns nil if no previous version exists.
  """
  def previous(component_key) do
    case get(component_key) do
      %{previous: prev} when prev != nil -> prev
      _ -> nil
    end
  end

  @doc """
  Rolls back a component to its previous version.
  Swaps previous to active and current to previous.
  Returns `:ok` or `{:error, :no_previous}`.
  """
  def rollback_to_previous(component_key) do
    GenServer.call(__MODULE__, {:rollback, component_key})
  end

  @doc """
  Checks if a component is registered in the manifest.
  """
  def exists?(component_key) do
    get(component_key) != nil
  end

  # GenServer callbacks

  @impl true
  def init(_opts) do
    # Delete stale named table from previous crash if it exists
    if :ets.whereis(@table) != :undefined do
      :ets.delete(@table)
    end
    table = :ets.new(@table, [:set, :named_table, :public, read_concurrency: true])
    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:register, component_map}, _from, state) do
    component = Map.fetch!(component_map, :component)
    name = Map.fetch!(component_map, :name)
    key = {component, name}

    now = DateTime.utc_now()

    entry = %{
      component: component,
      name: name,
      module: Map.get(component_map, :module),
      path: Map.get(component_map, :path),
      version: Map.get(component_map, :version, generate_version()),
      hash: Map.get(component_map, :hash, ""),
      status: :active,
      loaded_at: now,
      previous: nil,
      metadata: Map.get(component_map, :metadata, %{})
    }

    :ets.insert(@table, {key, entry})
    {:reply, {:ok, entry}, state}
  end

  @impl true
  def handle_call({:update, component_key, metadata}, _from, state) do
    case :ets.lookup(@table, component_key) do
      [{^component_key, current}] ->
        previous = %{
          version: current.version,
          hash: current.hash,
          loaded_at: current.loaded_at,
          metadata: current.metadata,
          module: Map.get(current, :module)
        }

        now = DateTime.utc_now()

        updated = %{
          current
          | version: Map.get(metadata, :version, generate_version()),
            hash: Map.get(metadata, :hash, current.hash),
            module: Map.get(metadata, :module, current.module),
            path: Map.get(metadata, :path, current.path),
            loaded_at: now,
            previous: previous,
            metadata: Map.get(metadata, :metadata, current.metadata)
        }

        :ets.insert(@table, {component_key, updated})
        {:reply, {:ok, updated}, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:rollback, component_key}, _from, state) do
    case :ets.lookup(@table, component_key) do
      [{^component_key, %{previous: nil}}] ->
        {:reply, {:error, :no_previous}, state}

      [{^component_key, current}] when current.previous != nil ->
        prev = current.previous
        now = DateTime.utc_now()

        rolled_back = %{
          current
          | version: prev.version,
            hash: prev.hash,
            module: Map.get(prev, :module),
            loaded_at: now,
            status: :active,
            previous: nil
        }

        :ets.insert(@table, {component_key, rolled_back})
        {:reply, {:ok, rolled_back}, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  defp generate_version do
    ts = DateTime.utc_now() |> DateTime.to_iso8601()
    rand = :crypto.strong_rand_bytes(4) |> Base.url_encode64(padding: false)
    "#{ts}-#{rand}"
  end
end
