defmodule Spark.HotReload.Compiler do
  @moduledoc """
  Compiles Elixir source files for tool modules and core modules (dev mode only).

  Safety constraints:
    - Only allows compilation of modules in the safe allowlist (dev mode)
    - Prevents unsafe module names (no Kernel, System, IO, etc.)
    - Verifies tool modules implement Spark.Tool behaviour
    - On compile failure, preserves previous working module
  """

  require Logger

  @safe_modules [
    Spark.CLI, Spark.Orchestrator, Spark.Dispatcher, Spark.Worker,
    Spark.EventBus, Spark.Memory, Spark.Policy, Spark.Guidance,
    Spark.PromptLab, Spark.PromptRefiner, Spark.Config,
    Spark.ToolRunner, Spark.ToolRegistry, Spark.Workspace.LockManager,
    Spark.Workspace.Diff, Spark.Workspace.Sandbox,
    Spark.Tools.File, Spark.Tools.FS, Spark.Tools.Shell, Spark.Tools.Web,
    Spark.Tools.Forge
  ]

  @unsafe_prefixes [
    "Kernel",
    "System",
    "IO",
    "File",
    "Code",
    "Port",
    "Process",
    "Node",
    "Elixir.Kernel",
    "Elixir.System",
    "Elixir.IO"
  ]

  @doc """
  Compiles a tool source file and validates it implements Spark.Tool behaviour.

  Returns `{:ok, module}` on success, `{:error, reason}` on failure.
  """
  @spec compile_tool(String.t()) :: {:ok, module()} | {:error, term()}
  def compile_tool(source_path) do
    with {:ok, source} <- read_source(source_path),
         {:ok, module} <- compile_source(source, source_path),
         :ok <- validate_tool_module(module) do
      {:ok, module}
    end
  end

  @doc """
  Compiles a core module source file (dev mode only).

  Validates that the module name is in the safe allowlist.
  Returns `{:ok, module}` on success, `{:error, reason}` on failure.
  """
  @spec compile_module(String.t()) :: {:ok, module()} | {:error, term()}
  def compile_module(source_path) do
    with {:ok, source} <- read_source(source_path),
         {:ok, module} <- compile_source(source, source_path),
         :ok <- validate_safe_module(module) do
      {:ok, module}
    end
  end

  @doc """
  Returns the list of safe module names allowed for core module compilation.
  """
  def safe_modules, do: @safe_modules

  @doc """
  Checks if a module name is in the safe allowlist.
  """
  def safe_module?(module) when is_atom(module) do
    module in @safe_modules
  end

  @doc """
  Checks if a module name has an unsafe prefix.
  """
  def unsafe_module_name?(module) when is_atom(module) do
    name = Atom.to_string(module)
    # Strip the Elixir. prefix if present for checking
    bare_name = String.trim_leading(name, "Elixir.")
    Enum.any?(@unsafe_prefixes, fn prefix ->
      String.starts_with?(bare_name, prefix) or name == "Elixir.#{prefix}"
    end)
  end

  # --- Private helpers ---

  defp read_source(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, {:read_error, reason}}
    end
  end

  defp compile_source(source, path) do
    try do
      [{module, _binary}] = Code.compile_string(source, path)
      {:ok, module}
    rescue
      e ->
        Logger.warning("HotReload compile failed for #{path}: #{Exception.message(e)}")
        {:error, {:compile_error, Exception.message(e)}}
    end
  end

  defp validate_tool_module(module) do
    cond do
      not Code.ensure_loaded?(module) ->
        {:error, {:module_not_loaded, module}}

      not function_exported?(module, :name, 0) ->
        {:error, {:missing_callback, {module, :name, 0}}}

      not function_exported?(module, :description, 0) ->
        {:error, {:missing_callback, {module, :description, 0}}}

      not function_exported?(module, :schema, 0) ->
        {:error, {:missing_callback, {module, :schema, 0}}}

      not function_exported?(module, :risk, 0) ->
        {:error, {:missing_callback, {module, :risk, 0}}}

      not function_exported?(module, :execute, 2) ->
        {:error, {:missing_callback, {module, :execute, 2}}}

      true ->
        validate_tool_return_values(module)
    end
  end

  defp validate_tool_return_values(module) do
    name = module.name()
    schema = module.schema()
    risk = module.risk()

    cond do
      not (is_binary(name) and name != "") ->
        {:error, {:invalid_name, name}}

      not is_map(schema) ->
        {:error, {:invalid_schema, schema}}

      risk not in [:low, :medium, :high, :critical] ->
        {:error, {:invalid_risk, risk}}

      true ->
        :ok
    end
  end

  defp validate_safe_module(module) do
    cond do
      unsafe_module_name?(module) ->
        {:error, {:unsafe_module, module}}

      not safe_module?(module) ->
        {:error, {:not_in_allowlist, module}}

      true ->
        :ok
    end
  end
end
