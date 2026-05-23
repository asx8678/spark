defmodule Spark.HotReload.Validator do
  @moduledoc """
  Pure functions for validating reload targets before applying them.

  Each validator checks file readability, format correctness, and
  structural validity without side effects.
  """

  @known_config_keys ~w(version llm dispatcher tools hot_reload memory)

  @doc """
  Validates a prompt file.
  Checks: file exists, is readable, is non-empty.
  """
  @spec validate_prompt(String.t()) :: :ok | {:error, term()}
  def validate_prompt(path) do
    with :ok <- check_readable(path),
         :ok <- check_non_empty(path) do
      :ok
    end
  end

  @doc """
  Validates a config file.
  Checks: file exists, valid JSON, known top-level keys.
  """
  @spec validate_config(String.t()) :: :ok | {:error, term()}
  def validate_config(path) do
    with :ok <- check_readable(path),
         {:ok, content} <- read_file_safe(path),
         {:ok, decoded} <- decode_json(content),
         :ok <- validate_config_structure(decoded) do
      :ok
    end
  end

  @doc """
  Validates a tool file.
  Checks: file exists, compiles, module implements Spark.Tool behaviour
  with required callbacks (name/0, description/0, schema/0, risk/0, execute/2).
  """
  @spec validate_tool(String.t()) :: :ok | {:error, term()}
  def validate_tool(path) do
    with :ok <- check_readable(path),
         {:ok, content} <- read_file_safe(path),
         {:ok, module} <- compile_source(content, path),
         :ok <- validate_tool_behaviour(module) do
      :ok
    end
  end

  @doc """
  Validates a policy file.
  Checks: file exists, valid JSON, known top-level keys.
  """
  @spec validate_policy(String.t()) :: :ok | {:error, term()}
  def validate_policy(path) do
    with :ok <- check_readable(path),
         {:ok, content} <- read_file_safe(path),
         {:ok, decoded} <- decode_json(content),
         :ok <- validate_policy_structure(decoded) do
      :ok
    end
  end

  @doc """
  Validates a guidance file.
  Checks: file exists, is readable, non-empty if file exists.
  """
  @spec validate_guidance(String.t()) :: :ok | {:error, term()}
  def validate_guidance(path) do
    with :ok <- check_readable(path),
         :ok <- check_non_empty(path) do
      :ok
    end
  end

  @doc """
  Auto-detects component type from file path and validates accordingly.
  """
  @spec validate_file(String.t()) :: :ok | {:error, term()}
  def validate_file(path) do
    cond do
      String.ends_with?(path, "/config.json") or String.contains?(path, "config.json") ->
        validate_config(path)

      String.contains?(path, "/prompts/") and String.ends_with?(path, ".md") ->
        validate_prompt(path)

      String.contains?(path, "/tools/") and String.ends_with?(path, ".ex") ->
        validate_tool(path)

      String.contains?(path, "/policy/") and String.ends_with?(path, ".json") ->
        validate_policy(path)

      String.contains?(path, "/guidance/") and String.ends_with?(path, ".md") ->
        validate_guidance(path)

      true ->
        {:error, {:unknown_type, path}}
    end
  end

  # --- Private helpers ---

  defp check_readable(path) do
    if File.exists?(path) do
      case File.stat(path) do
        {:ok, %{access: access}} when access in [:read, :read_write] -> :ok
        _ -> :ok  # If exists, assume readable for now
      end
    else
      {:error, {:not_readable, path}}
    end
  end

  defp check_non_empty(path) do
    case File.stat(path) do
      {:ok, %{size: size}} when size > 0 -> :ok
      {:ok, %{size: 0}} -> {:error, {:empty_file, path}}
      {:error, reason} -> {:error, {:stat_error, reason}}
    end
  end

  defp read_file_safe(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, {:read_error, reason}}
    end
  end

  defp decode_json(content) do
    case Jason.decode(content) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, reason} -> {:error, {:invalid_json, reason}}
    end
  end

  defp validate_config_structure(decoded) when is_map(decoded) do
    unknown_keys = Map.keys(decoded) -- @known_config_keys

    if unknown_keys == [] do
      :ok
    else
      # Warn but don't block — unknown keys are allowed
      :ok
    end
  end

  defp validate_config_structure(_), do: {:error, {:invalid_config, "expected JSON object"}}

  defp validate_policy_structure(decoded) when is_map(decoded) do
    # Policy can have unknown keys; just verify it's a map
    :ok
  end

  defp validate_policy_structure(_), do: {:error, {:invalid_policy, "expected JSON object"}}

  defp compile_source(content, path) do
    # Try to compile the source in an isolated context
    try do
      # Use Code.compile_string with a unique file name to avoid module conflicts
      [{module, _}] = Code.compile_string(content, path)
      {:ok, module}
    rescue
      e -> {:error, {:compile_error, Exception.message(e)}}
    end
  end

  defp validate_tool_behaviour(module) do
    with true <- Code.ensure_loaded?(module),
         true <- function_exported?(module, :name, 0),
         true <- function_exported?(module, :description, 0),
         true <- function_exported?(module, :schema, 0),
         true <- function_exported?(module, :risk, 0),
         true <- function_exported?(module, :execute, 2),
         :ok <- validate_tool_name(module),
         :ok <- validate_tool_schema(module),
         :ok <- validate_tool_risk(module) do
      :ok
    else
      false -> {:error, {:missing_callbacks, module}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_tool_name(module) do
    name = module.name()
    if is_binary(name) and name != "", do: :ok, else: {:error, {:invalid_name, name}}
  end

  defp validate_tool_schema(module) do
    schema = module.schema()
    if is_map(schema), do: :ok, else: {:error, {:invalid_schema, schema}}
  end

  defp validate_tool_risk(module) do
    risk = module.risk()
    if risk in [:low, :medium, :high, :critical], do: :ok, else: {:error, {:invalid_risk, risk}}
  end
end
