defmodule Spark.Prompt.Store do
  @moduledoc """
  Prompt loading and management for Spark.

  Loads prompt markdown files from ~/.spark/prompts/:
    - orchestrator.md
    - worker.md
    - refiner.md

  Provides `get/1`, `version/1`, `hash/1`, `reload/1`, `reload_all/0`.
  Creates default prompts if files are absent.
  """

  use Agent

  alias Spark.Config

  @prompt_keys [:orchestrator, :worker, :refiner]
  @prompts_dir "prompts"

  # --- Default prompts ---

  @default_prompts %{
    orchestrator: """
    # Spark Orchestrator

    You are the Spark orchestrator agent. Your job is to:
    - Understand user goals
    - Create execution plans with clear tasks
    - Await user approval before execution
    - Review task results and synthesize answers

    Always produce valid JSON plans with tasks array.
    """,
    worker: """
    # Spark Worker

    You are a Spark worker agent. Your job is to:
    - Execute assigned tasks precisely
    - Use tools to read, write, and search files
    - Report results clearly and concisely
    - Follow policy constraints

    Always report tool outcomes honestly.
    """,
    refiner: """
    # Spark Prompt Refiner

    You are a prompt refiner agent. Your job is to:
    - Analyze prompt failures from execution logs
    - Suggest specific improvements to prompts
    - Create candidate prompts for testing
    - Produce clear diffs and recommendations

    Focus on actionable improvements, not vague advice.
    """
  }

  # --- Public API ---

  @doc """
  Starts the Store agent.
  """
  def start_link(_opts \\ []) do
    case Process.whereis(__MODULE__) do
      nil -> Agent.start_link(fn -> load_all_from_disk() end, name: __MODULE__)
      pid -> {:ok, pid}
    end
  end

  @doc """
  Gets the prompt content for a given key (:orchestrator, :worker, :refiner).
  Loads from disk and caches if not present.
  """
  @spec get(atom()) :: String.t()
  def get(key) when key in @prompt_keys do
    ensure_loaded(key)
    Agent.get(__MODULE__, fn state ->
      case Map.get(state, key) do
        %{content: content} -> content
        nil -> Map.get(@default_prompts, key, "")
      end
    end)
  end

  def get(key), do: raise(ArgumentError, "Unknown prompt key: #{inspect(key)}")

  @doc """
  Returns the version string for a prompt.
  """
  @spec version(atom()) :: String.t()
  def version(key) when key in @prompt_keys do
    ensure_loaded(key)
    Agent.get(__MODULE__, fn state ->
      get_in(state, [key, :version]) || "unknown"
    end)
  end

  @doc """
  Returns the SHA-256 hash of the prompt file content.
  """
  @spec hash(atom()) :: String.t()
  def hash(key) when key in @prompt_keys do
    ensure_loaded(key)
    Agent.get(__MODULE__, fn state ->
      get_in(state, [key, :hash]) || ""
    end)
  end

  @doc """
  Reloads a single prompt from disk.
  """
  @spec reload(atom()) :: {:ok, map()} | {:error, term()}
  def reload(key) when key in @prompt_keys do
    case read_prompt_file(key) do
      {:ok, content} ->
        entry = build_entry(key, content)
        Agent.update(__MODULE__, fn state -> Map.put(state, key, entry) end)
        {:ok, entry}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def reload(key), do: {:error, {:unknown_key, key}}

  @doc """
  Reloads all prompts from disk.
  """
  @spec reload_all() :: :ok
  def reload_all do
    Agent.update(__MODULE__, fn _state -> load_all_from_disk() end)
    :ok
  end

  @doc """
  Returns all prompt keys.
  """
  @spec keys() :: [atom()]
  def keys, do: @prompt_keys

  @doc """
  Returns the path for a prompt file.
  """
  @spec path(atom()) :: String.t()
  def path(key) when key in @prompt_keys do
    Path.join(prompts_dir(), "#{key}.md")
  end

  @doc """
  Writes content to a prompt file and reloads it.
  """
  @spec write(atom(), String.t()) :: {:ok, map()} | {:error, term()}
  def write(key, content) when key in @prompt_keys do
    file_path = path(key)
    File.mkdir_p!(Path.dirname(file_path))

    case File.write(file_path, content) do
      :ok -> reload(key)
      {:error, reason} -> {:error, reason}
    end
  end

  # --- Private ---

  # Ensures a key is loaded — does NOT call Agent.get/update
  # recursively. Uses a cast-like pattern.
  defp ensure_loaded(key) do
    loaded? = Agent.get(__MODULE__, fn state -> Map.has_key?(state, key) end)
    unless loaded?, do: load_key(key)
  end

  defp load_key(key) do
    # Read and cache outside of Agent callbacks to avoid deadlock
    case read_prompt_file(key) do
      {:ok, content} ->
        entry = build_entry(key, content)
        Agent.update(__MODULE__, fn state -> Map.put(state, key, entry) end)

      {:error, :not_found} ->
        default = Map.get(@default_prompts, key, "")
        write_default!(key, default)
        entry = build_entry(key, default)
        Agent.update(__MODULE__, fn state -> Map.put(state, key, entry) end)

      {:error, _reason} ->
        default = Map.get(@default_prompts, key, "")
        entry = build_entry(key, default)
        Agent.update(__MODULE__, fn state -> Map.put(state, key, entry) end)
    end
  end

  defp load_all_from_disk do
    @prompt_keys
    |> Enum.map(fn key ->
      case read_prompt_file(key) do
        {:ok, content} -> {key, build_entry(key, content)}
        {:error, :not_found} ->
          default = Map.get(@default_prompts, key, "")
          write_default!(key, default)
          {key, build_entry(key, default)}
        {:error, _reason} ->
          default = Map.get(@default_prompts, key, "")
          {key, build_entry(key, default)}
      end
    end)
    |> Map.new()
  end

  defp read_prompt_file(key) do
    file_path = path(key)

    case File.read(file_path) do
      {:ok, content} -> {:ok, content}
      {:error, :enoent} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp write_default!(key, content) do
    file_path = path(key)
    File.mkdir_p!(Path.dirname(file_path))
    File.write!(file_path, content)
  end

  defp build_entry(key, content) do
    hash = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
    version = generate_version()

    %{
      key: key,
      content: content,
      hash: hash,
      version: version,
      path: path(key),
      loaded_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  defp generate_version do
    ts = DateTime.utc_now() |> DateTime.to_iso8601()
    rand = :crypto.strong_rand_bytes(4) |> Base.url_encode64(padding: false)
    "#{ts}-#{rand}"
  end

  defp prompts_dir do
    Path.join(Config.home_dir(), @prompts_dir)
  end
end
