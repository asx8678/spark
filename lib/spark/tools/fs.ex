defmodule Spark.Tools.ListDir do
  @moduledoc """
  Lists directory contents relative to the project root.

  Skips common noise directories (.git, _build, deps, node_modules) by default.
  Truncates large output based on context[:max_output_bytes].
  """

  @behaviour Spark.Tool

  @max_output_bytes 20_000
  @default_skip ~w(.git _build deps node_modules)

  @impl true
  def name, do: "list_dir"

  @impl true
  def description,
    do: "List directory contents relative to the project root. Skips noise dirs by default."

  @impl true
  def schema do
    %{
      type: "object",
      required: ["path"],
      properties: %{
        path: %{type: "string", description: "Project-root-relative directory path"},
        skip: %{
          type: "array",
          items: %{type: "string"},
          description: "Dir names to skip (default: .git, _build, deps, node_modules)"
        }
      }
    }
  end

  @impl true
  def risk, do: :low

  @impl true
  def execute(%{path: path}, context) when is_binary(path) do
    root = Map.get(context, :project_root, File.cwd!())
    full = Path.expand(path, root)
    skip = Map.get(context, :skip, Map.get(context, :skip_dirs, @default_skip))

    cond do
      not String.starts_with?(full, root <> "/") and full != root ->
        {:error, %{path: path, reason: :path_escape}}

      not File.dir?(full) ->
        {:error, %{path: path, reason: :not_a_directory}}

      true ->
        entries =
          full
          |> File.ls!()
          |> Enum.reject(fn entry -> entry in skip end)
          |> Enum.sort()

        formatted = format_entries(full, entries)
        max = Map.get(context, :max_output_bytes, @max_output_bytes)
        truncated = maybe_truncate(formatted, max)

        {:ok,
         %{
           path: path,
           entries: entries,
           output: truncated,
           truncated: byte_size(formatted) > max
         }}
    end
  end

  def execute(_args, _context) do
    {:error, %{reason: :missing_path}}
  end

  defp format_entries(dir, entries) do
    Enum.map(entries, fn entry ->
      full = Path.join(dir, entry)
      if File.dir?(full), do: "#{entry}/", else: entry
    end)
    |> Enum.join("\n")
  end

  defp maybe_truncate(content, max_bytes) when byte_size(content) > max_bytes do
    binary_part(content, 0, max_bytes) <>
      "\n... [truncated #{byte_size(content) - max_bytes} bytes]"
  end

  defp maybe_truncate(content, _max_bytes), do: content
end

defmodule Spark.Tools.Glob do
  @moduledoc """
  Finds files matching a glob pattern within the project root.

  Uses Path.wildcard/2 scoped to the project root.
  Truncates large output based on context[:max_output_bytes].
  """

  @behaviour Spark.Tool

  @max_output_bytes 20_000

  @impl true
  def name, do: "glob"

  @impl true
  def description, do: "Find files matching a glob pattern within the project root."

  @impl true
  def schema do
    %{
      type: "object",
      required: ["pattern"],
      properties: %{
        pattern: %{type: "string", description: "Glob pattern (e.g. '**/*.ex')"}
      }
    }
  end

  @impl true
  def risk, do: :low

  @impl true
  def execute(%{pattern: pattern}, context) when is_binary(pattern) do
    root = Map.get(context, :project_root, File.cwd!())

    # Scope the glob to the project root
    full_pattern = if Path.type(pattern) == :absolute, do: pattern, else: Path.join(root, pattern)

    matches =
      Path.wildcard(full_pattern)
      |> Enum.filter(fn path -> String.starts_with?(path, root) end)
      # Strip the root prefix for cleaner output
      |> Enum.map(fn path -> Path.relative_to(path, root) end)
      |> Enum.sort()

    formatted = Enum.join(matches, "\n")
    max = Map.get(context, :max_output_bytes, @max_output_bytes)
    truncated = maybe_truncate(formatted, max)

    {:ok,
     %{
       pattern: pattern,
       matches: matches,
       count: length(matches),
       output: truncated,
       truncated: byte_size(formatted) > max
     }}
  end

  def execute(_args, _context) do
    {:error, %{reason: :missing_pattern}}
  end

  defp maybe_truncate(content, max_bytes) when byte_size(content) > max_bytes do
    binary_part(content, 0, max_bytes) <>
      "\n... [truncated #{byte_size(content) - max_bytes} bytes]"
  end

  defp maybe_truncate(content, _max_bytes), do: content
end

defmodule Spark.Tools.Grep do
  @moduledoc """
  Searches for a text pattern in files within the project root.

  Skips common noise directories (.git, _build, deps, node_modules).
  Truncates large output based on context[:max_output_bytes].
  """

  @behaviour Spark.Tool

  @max_output_bytes 20_000
  @default_skip ~w(.git _build deps node_modules)

  @impl true
  def name, do: "grep"

  @impl true
  def description, do: "Search for a text pattern in project files. Skips noise dirs by default."

  @impl true
  def schema do
    %{
      type: "object",
      required: ["pattern"],
      properties: %{
        pattern: %{type: "string", description: "Text pattern to search for"},
        path: %{
          type: "string",
          description: "Subdirectory within project root to search (default: .)"
        }
      }
    }
  end

  @impl true
  def risk, do: :low

  @impl true
  def execute(%{pattern: pattern}, context) when is_binary(pattern) do
    root = Map.get(context, :project_root, File.cwd!())
    search_path = Map.get(context, :path, Map.get(context, :search_path, "."))
    skip = Map.get(context, :skip, Map.get(context, :skip_dirs, @default_skip))

    full_search = Path.expand(search_path, root)

    if not String.starts_with?(full_search, root) and full_search != root do
      {:error, %{pattern: pattern, path: search_path, reason: :path_escape}}
    else
      matches = do_grep(full_search, pattern, skip, root)
      formatted = format_matches(matches)
      max = Map.get(context, :max_output_bytes, @max_output_bytes)
      truncated = maybe_truncate(formatted, max)

      {:ok,
       %{
         pattern: pattern,
         path: search_path,
         matches: length(matches),
         output: truncated,
         truncated: byte_size(formatted) > max
       }}
    end
  end

  def execute(_args, _context) do
    {:error, %{reason: :missing_pattern}}
  end

  defp do_grep(dir, pattern, skip, root) do
    dir
    |> File.ls!()
    |> Enum.reject(fn entry -> entry in skip end)
    |> Enum.flat_map(fn entry ->
      full = Path.join(dir, entry)
      rel = Path.relative_to(full, root)

      cond do
        File.dir?(full) ->
          do_grep(full, pattern, skip, root)

        File.regular?(full) ->
          case File.read(full) do
            {:ok, content} ->
              content
              |> String.split("\n")
              |> Enum.with_index(1)
              |> Enum.filter(fn {line, _idx} -> String.contains?(line, pattern) end)
              |> Enum.map(fn {line, idx} -> {rel, idx, line} end)

            _ ->
              []
          end

        true ->
          []
      end
    end)
  end

  defp format_matches(matches) do
    Enum.map(matches, fn {file, line, text} ->
      "#{file}:#{line}: #{String.trim(text)}"
    end)
    |> Enum.join("\n")
  end

  defp maybe_truncate(content, max_bytes) when byte_size(content) > max_bytes do
    binary_part(content, 0, max_bytes) <>
      "\n... [truncated #{byte_size(content) - max_bytes} bytes]"
  end

  defp maybe_truncate(content, _max_bytes), do: content
end
