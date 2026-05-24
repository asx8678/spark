defmodule Spark.Tools.CreateAndLoadTool do
  @moduledoc """
  Dynamically creates and loads a new tool at runtime.

  Writes the tool source to ~/.spark/tools/, compiles it,
  validates it implements Spark.Tool, and registers it in ToolRegistry.

  Requires high-risk approval. Emits :tool_reloaded event.
  Will not overwrite existing tools without explicit approval.
  """

  @behaviour Spark.Tool

  alias Spark.ToolRegistry
  alias Spark.HotReload.Compiler
  alias Spark.EventBus

  @impl true
  def name, do: "create_and_load_tool"

  @impl true
  def description,
    do: "Create and dynamically load a new tool at runtime. High-risk — requires approval."

  @impl true
  def schema do
    %{
      type: "object",
      required: ["name", "source_code", "task_id"],
      properties: %{
        name: %{type: "string", description: "Tool name (used as filename and registry key)"},
        source_code: %{type: "string", description: "Elixir source code implementing Spark.Tool"},
        task_id: %{type: "string", description: "Owning task identifier"},
        overwrite: %{
          type: "boolean",
          description: "Allow overwriting an existing tool (default: false)"
        }
      }
    }
  end

  @impl true
  def risk, do: :high

  @impl true
  def execute(%{name: name, source_code: source_code, task_id: task_id}, context)
      when is_binary(name) and is_binary(source_code) and is_binary(task_id) and task_id != "" do
    overwrite = Map.get(context, :overwrite, Map.get(context, :force, false))

    with :ok <- validate_name(name),
         :ok <- check_existing(name, overwrite),
         :ok <- write_tool_file(name, source_code),
         {:ok, module} <- compile_tool(name),
         :ok <- register_tool(module, overwrite) do
      # Emit :tool_reloaded event
      EventBus.publish_hot_reload(
        :tool_reloaded,
        %{
          tool_name: name,
          module: module
        }, source: :forge)

      {:ok,
       %{
         name: name,
         module: module,
         status: :created,
         task_id: task_id
       }}
    else
      {:error, reason} ->
        {:error, Map.merge(%{name: name, task_id: task_id}, normalize_error(reason))}
    end
  end

  def execute(%{name: _, source_code: _}, _context) do
    {:error, %{reason: :missing_task_id}}
  end

  def execute(_args, _context) do
    {:error, %{reason: :missing_required_fields}}
  end

  # --- Private ---

  defp validate_name(name) do
    cond do
      name == "" ->
        {:error, :empty_name}

      not Regex.match?(~r/^[a-z][a-z0-9_]*$/, name) ->
        {:error, :invalid_name_format}

      byte_size(name) > 64 ->
        {:error, :name_too_long}

      true ->
        :ok
    end
  end

  defp check_existing(name, overwrite) do
    case ToolRegistry.lookup(name) do
      {:ok, _} when not overwrite ->
        {:error, {:already_exists, name}}

      {:ok, _} when overwrite ->
        :ok

      {:error, {:not_found, _}} ->
        # Check if file exists on disk too
        path = tool_path(name)

        if File.exists?(path) and not overwrite do
          {:error, {:file_already_exists, path}}
        else
          :ok
        end
    end
  end

  defp write_tool_file(name, source_code) do
    path = tool_path(name)
    dir = Path.dirname(path)
    File.mkdir_p!(dir)

    case File.write(path, source_code) do
      :ok -> :ok
      {:error, reason} -> {:error, {:write_failed, reason}}
    end
  end

  defp compile_tool(name) do
    path = tool_path(name)

    case Compiler.compile_tool(path) do
      {:ok, module} -> {:ok, module}
      {:error, reason} -> {:error, {:compile_failed, reason}}
    end
  end

  defp register_tool(module, overwrite) do
    metadata = if overwrite, do: [replace: true], else: []

    case ToolRegistry.register(module, metadata) do
      :ok ->
        :ok

      {:error, {:already_registered, name}} ->
        if overwrite do
          ToolRegistry.register(module, replace: true)
        else
          {:error, {:registration_failed, name}}
        end

      {:error, reason} ->
        {:error, {:registration_failed, reason}}
    end
  end

  defp tool_path(name) do
    Path.join([Spark.Config.home_dir(), "tools", "#{name}.ex"])
  end

  defp normalize_error({k, v}), do: %{k => v}
  defp normalize_error(reason) when is_atom(reason), do: %{reason: reason}
  defp normalize_error(reason), do: %{detail: reason}
end
