defmodule Spark.Config do
  @moduledoc """
  Manages the Spark home directory (~/.spark/), runtime configuration,
  and encrypted secret storage.

  Directory layout:
    ~/.spark/
    ├── config.json
    ├── secrets.enc
    ├── sessions/
    ├── memory/
    ├── tools/
    ├── prompts/
    ├── policy/
    ├── guidance/
    ├── logs/
    └── cache/

  The home directory can be overridden via Application env `:spark, :home_dir`
  or the `SPARK_HOME` environment variable for testing.
  """

  use Agent

  @default_config %{
    "version" => 4.0,
    "llm" => %{
      "orchestrator_provider" => "wafer",
      "orchestrator_model" => "deepseek-chat",
      "worker_provider" => "wafer",
      "worker_model" => "glm-5.1",
      "base_url" => "https://pass.wafer.ai/v1"
    },
    "agents" => %{
      "planning" => %{
        "actor_type" => "orchestrator",
        "provider" => "deepseek",
        "model" => "deepseek-v4-pro",
        "base_url" => "https://api.deepseek.com"
      },
      "coding" => %{
        "actor_type" => "worker",
        "provider" => "wafer",
        "model" => "glm-5.1",
        "base_url" => "https://pass.wafer.ai/v1"
      }
    },
    "dispatcher" => %{
      "max_concurrency" => 3,
      "default_task_timeout_ms" => 300_000,
      "max_retries" => 2
    },
    "tools" => %{
      "shell_timeout_ms" => 30_000,
      "output_truncation_bytes" => 20_000
    },
    "hot_reload" => %{
      "enabled" => true,
      "mode" => "dev",
      "poll_interval_ms" => 1000,
      "targets" => ["prompts", "tools", "config", "policy", "guidance"]
    },
    "memory" => %{
      "bronze_enabled" => true,
      "silver_enabled" => true,
      "gold_enabled" => true
    }
  }

  @subdirs ~w(sessions memory tools prompts policy guidance logs cache)

  @doc """
  Returns the Spark home directory path.
  Priority: Application env :home_dir > SPARK_HOME env > ~/.spark
  """
  def home_dir do
    cond do
      dir = Application.get_env(:spark, :home_dir) -> dir
      dir = System.get_env("SPARK_HOME") -> dir
      true -> Path.join(System.user_home!(), ".spark")
    end
  end

  @doc """
  Returns the default config map.
  """
  def default_config, do: @default_config

  @doc """
  Creates the Spark home directory and all required subdirectories.
  Writes the default config.json if one does not exist.
  Idempotent — safe to call multiple times.
  """
  def ensure_home! do
    home = home_dir()
    File.mkdir_p!(home)

    for subdir <- @subdirs do
      File.mkdir_p!(Path.join(home, subdir))
    end

    config_path = config_path()
    unless File.exists?(config_path) do
      write_config!(@default_config)
    end

    :ok
  end

  @doc """
  Returns the path to config.json.
  """
  def config_path do
    Path.join(home_dir(), "config.json")
  end

  @doc """
  Returns the current runtime config map.
  Starts the config agent if not running.
  """
  def runtime_config do
    ensure_agent_started()
    Agent.get(__MODULE__, & &1)
  end

  @doc """
  Gets a config value by key (string or list of strings for nested access).
  Returns nil if key not found.
  """
  def get(key), do: get(key, nil)

  @doc """
  Gets a config value by key with a default.
  Supports nested access via dot-notation string or list of keys.
  """
  def get(key, default) when is_list(key) do
    config = runtime_config()
    get_nested(config, key, default)
  end

  def get(key, default) when is_binary(key) do
    parts = String.split(key, ".")
    get(parts, default)
  end

  def get(key, default) when is_atom(key) do
    get(Atom.to_string(key), default)
  end

  @doc """
  Updates a config value by key (string or list of strings for nested access).
  """
  def put(key, value) when is_list(key) do
    ensure_agent_started()
    Agent.update(__MODULE__, fn config ->
      put_nested(config, key, value)
    end)
  end

  def put(key, value) when is_binary(key) do
    parts = String.split(key, ".")
    put(parts, value)
  end

  def put(key, value) when is_atom(key) do
    put(Atom.to_string(key), value)
  end

  @doc """
  Updates a config value and persists the full runtime config to config.json.
  Returns :ok or {:error, reason}. On write failure, the in-memory config is left unchanged.
  """
  def put_persistent(key, value) when is_list(key) do
    ensure_agent_started()

    Agent.get_and_update(__MODULE__, fn config ->
      new_config = put_nested(config, key, value)

      case write_config(new_config) do
        :ok -> {:ok, new_config}
        {:error, reason} -> {{:error, reason}, config}
      end
    end)
  end

  def put_persistent(key, value) when is_binary(key) do
    parts = String.split(key, ".")
    put_persistent(parts, value)
  end

  def put_persistent(key, value) when is_atom(key) do
    put_persistent(Atom.to_string(key), value)
  end

  @doc """
  Reloads configuration from disk (config.json).
  Returns {:ok, config} on success, {:error, reason} on failure.
  Does not crash on invalid config — keeps previous config on error.
  """
  def reload do
    case read_config_file() do
      {:ok, new_config} ->
        ensure_agent_started()
        Agent.update(__MODULE__, fn _old -> new_config end)
        {:ok, new_config}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Starts the config Agent. Called automatically by ensure_home!/0 and runtime_config/0.
  """
  def start_link(_opts \\ []) do
    case Process.whereis(__MODULE__) do
      nil ->
        initial = case read_config_file() do
          {:ok, config} -> config
          {:error, _} -> @default_config
        end
        Agent.start_link(fn -> initial end, name: __MODULE__)

      pid ->
        {:ok, pid}
    end
  end

  # --- Secret management (delegated to Spark.Config.Secrets) ---

  @doc """
  Lists secret keys (without values).
  """
  defdelegate list_secret_keys, to: Spark.Config.Secrets

  @doc """
  Gets a decrypted secret value by key. Returns nil if not found.
  """
  defdelegate get_secret(key), to: Spark.Config.Secrets

  @doc """
  Encrypts and stores a secret value.
  """
  defdelegate put_secret(key, value), to: Spark.Config.Secrets

  @doc """
  Deletes a secret by key.
  """
  defdelegate delete_secret(key), to: Spark.Config.Secrets

  # --- Private helpers ---

  defp ensure_agent_started do
    case Process.whereis(__MODULE__) do
      nil ->
        # Start agent synchronously for the calling process
        case start_link() do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
        end
      _pid ->
        :ok
    end
  end

  defp read_config_file do
    path = config_path()

    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, config} -> {:ok, config}
          {:error, reason} -> {:error, {:invalid_json, reason}}
        end

      {:error, :enoent} ->
        {:error, :config_not_found}

      {:error, reason} ->
        {:error, {:read_error, reason}}
    end
  end

  defp write_config(config) do
    try do
      path = config_path()
      json = Jason.encode!(config, pretty: true)

      case File.write(path, json) do
        :ok -> :ok
        {:error, reason} -> {:error, {:write_error, reason}}
      end
    rescue
      e -> {:error, {:config_write_failed, Exception.message(e)}}
    end
  end

  defp write_config!(config) do
    case write_config(config) do
      :ok -> :ok
      {:error, reason} -> raise "Failed to write Spark config: #{inspect(reason)}"
    end
  end

  defp get_nested(config, [], _default), do: config
  defp get_nested(config, [key | rest], default) do
    case Map.fetch(config, key) do
      {:ok, value} when is_map(value) and rest != [] -> get_nested(value, rest, default)
      {:ok, value} when rest == [] -> value
      {:ok, value} when not is_map(value) and rest != [] -> default
      :error -> default
    end
  end

  defp put_nested(config, [key], value) do
    Map.put(config, key, value)
  end

  defp put_nested(config, [key | rest], value) do
    inner = Map.get(config, key, %{})
    Map.put(config, key, put_nested(inner, rest, value))
  end


end
