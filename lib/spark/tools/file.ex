defmodule Spark.Tools.ReadFile do
  @moduledoc """
  Reads a file from the project root.

  Args:
    - path (required): project-root-relative path to read

  Truncates large output based on context[:max_output_bytes].
  """

  @behaviour Spark.Tool

  @max_output_bytes 20_000

  @impl true
  def name, do: "read_file"

  @impl true
  def description, do: "Read a file's contents relative to the project root."

  @impl true
  def schema do
    %{
      type: "object",
      required: ["path"],
      properties: %{
        path: %{type: "string", description: "Project-root-relative file path"}
      }
    }
  end

  @impl true
  def risk, do: :low

  @impl true
  def execute(%{path: path}, context) when is_binary(path) do
    root = Map.get(context, :project_root, File.cwd!())
    full = Path.expand(path, root)

    with :ok <- ensure_in_project_root?(full, root),
         {:ok, content} <- File.read(full) do
      max = Map.get(context, :max_output_bytes, @max_output_bytes)
      truncated = maybe_truncate(content, max)
      {:ok, %{path: path, content: truncated, truncated: byte_size(content) > max}}
    else
      {:error, :enoent} -> {:error, %{path: path, reason: :file_not_found}}
      {:error, :eacces} -> {:error, %{path: path, reason: :permission_denied}}
      {:error, {:path_escape, path}} -> {:error, %{path: path, reason: :path_escape}}
      {:error, reason} -> {:error, %{path: path, reason: reason}}
    end
  end

  def execute(_args, _context) do
    {:error, %{reason: :missing_path}}
  end

  defp ensure_in_project_root?(full, root) do
    if String.starts_with?(full, root <> "/") or full == root do
      :ok
    else
      {:error, {:path_escape, full}}
    end
  end

  defp maybe_truncate(content, max_bytes) when byte_size(content) > max_bytes do
    binary_part(content, 0, max_bytes) <>
      "\n... [truncated #{byte_size(content) - max_bytes} bytes]"
  end

  defp maybe_truncate(content, _max_bytes), do: content
end

defmodule Spark.Tools.WriteFile do
  @moduledoc """
  Writes content to a file relative to the project root.

  Args:
    - path (required): project-root-relative path to write
    - content (required): file content to write
    - task_id (required): calling task identifier

  Validates the write path stays within the project root.
  """

  @behaviour Spark.Tool

  @impl true
  def name, do: "write_file"

  @impl true
  def description, do: "Write content to a file relative to the project root. Requires task_id."

  @impl true
  def schema do
    %{
      type: "object",
      required: ["path", "content", "task_id"],
      properties: %{
        path: %{type: "string", description: "Project-root-relative file path"},
        content: %{type: "string", description: "Content to write"},
        task_id: %{type: "string", description: "Owning task identifier"}
      }
    }
  end

  @impl true
  def risk, do: :medium

  @impl true
  def execute(%{path: path, content: content, task_id: task_id}, context)
      when is_binary(path) and is_binary(content) and is_binary(task_id) and task_id != "" do
    root = Map.get(context, :project_root, File.cwd!())
    full = Path.expand(path, root)

    with :ok <- ensure_in_project_root?(full, root) do
      dir = Path.dirname(full)
      File.mkdir_p!(dir)

      case File.write(full, content) do
        :ok -> {:ok, %{path: path, bytes_written: byte_size(content), task_id: task_id}}
        {:error, reason} -> {:error, %{path: path, reason: reason}}
      end
    else
      {:error, {:path_escape, _}} -> {:error, %{path: path, reason: :path_escape}}
    end
  end

  def execute(%{path: _path}, _context) do
    {:error, %{reason: :missing_required_fields}}
  end

  def execute(_args, _context) do
    {:error, %{reason: :missing_path}}
  end

  defp ensure_in_project_root?(full, root) do
    if String.starts_with?(full, root <> "/") or full == root do
      :ok
    else
      {:error, {:path_escape, full}}
    end
  end
end

defmodule Spark.Tools.EditFile do
  @moduledoc """
  Performs exact search/replace on a file relative to the project root.

  Args:
    - path (required): project-root-relative path
    - search (required): exact text to find
    - replace (required): replacement text
    - task_id (required): calling task identifier

  Fails if the search string is not found or appears multiple times.
  """

  @behaviour Spark.Tool

  @impl true
  def name, do: "edit_file"

  @impl true
  def description, do: "Exact search/replace edit on a file. Requires task_id."

  @impl true
  def schema do
    %{
      type: "object",
      required: ["path", "search", "replace", "task_id"],
      properties: %{
        path: %{type: "string", description: "Project-root-relative file path"},
        search: %{type: "string", description: "Exact text to find"},
        replace: %{type: "string", description: "Replacement text"},
        task_id: %{type: "string", description: "Owning task identifier"}
      }
    }
  end

  @impl true
  def risk, do: :medium

  @impl true
  def execute(%{path: path, search: search, replace: replace, task_id: task_id}, context)
      when is_binary(path) and is_binary(search) and is_binary(replace) and
             is_binary(task_id) and task_id != "" do
    root = Map.get(context, :project_root, File.cwd!())
    full = Path.expand(path, root)

    with :ok <- ensure_in_project_root?(full, root),
         {:ok, content} <- File.read(full),
         {:ok, count} <- count_occurrences(content, search),
         {:ok, new_content} <- apply_replace(content, search, replace, count) do
      case File.write(full, new_content) do
        :ok ->
          {:ok,
           %{
             path: path,
             replacements: count,
             task_id: task_id
           }}

        {:error, reason} ->
          {:error, %{path: path, reason: reason}}
      end
    else
      {:error, {:path_escape, _}} ->
        {:error, %{path: path, reason: :path_escape}}

      {:error, :enoent} ->
        {:error, %{path: path, reason: :file_not_found}}

      {:error, {:not_found, search}} ->
        {:error, %{path: path, reason: :search_not_found, search: search}}

      {:error, {:multiple_matches, n}} ->
        {:error, %{path: path, reason: :ambiguous_match, matches: n}}

      {:error, reason} ->
        {:error, %{path: path, reason: reason}}
    end
  end

  def execute(%{path: _path}, _context) do
    {:error, %{reason: :missing_required_fields}}
  end

  def execute(_args, _context) do
    {:error, %{reason: :missing_path}}
  end

  defp ensure_in_project_root?(full, root) do
    if String.starts_with?(full, root <> "/") or full == root do
      :ok
    else
      {:error, {:path_escape, full}}
    end
  end

  defp count_occurrences(content, search) do
    count = count_matches(content, search)

    cond do
      count == 0 -> {:error, {:not_found, search}}
      count == 1 -> {:ok, 1}
      true -> {:ok, count}
    end
  end

  defp apply_replace(content, search, replace, 1) do
    {:ok, String.replace(content, search, replace, global: false)}
  end

  defp apply_replace(_content, _search, _replace, count) do
    {:error, {:multiple_matches, count}}
  end

  defp count_matches(content, search) do
    length(String.split(content, search)) - 1
  end
end
