defmodule Spark.Tools.CodePuppyAliases do
  @moduledoc """
  Code Puppy-compatible tool aliases for Spark.

  These tools provide Code Puppy-style names and UX patterns while delegating
  to existing Spark tool infrastructure. They are registered alongside the
  original Spark tools for backward compatibility.

  Aliases:
    - ListFiles (list_files) — delegates to ListDir with recursive support
    - CreateFile (create_file) — refuses overwrite unless explicit
    - ReplaceInFile (replace_in_file) — sequential exact replacements
    - DeleteSnippet (delete_snippet) — remove first occurrence of text
    - DeleteFile (delete_file) — path scoped to project root
    - AgentRunShellCommand (agent_run_shell_command) — shell with cwd/timeout/background
  """

  # ─── ListFiles ───────────────────────────────────────────────────────

  defmodule ListFiles do
    @moduledoc """
    List files and directories with intelligent filtering and safety features.

    Automatically ignores build artifacts, caches, and common noise.
    Code Puppy-compatible alias for list_dir with recursive support.
    """

    @behaviour Spark.Tool

    @default_skip ~w(.git _build deps node_modules .elixir_ls)

    @impl true
    def name, do: "list_files"

    @impl true
    def description,
      do:
        "List files and directories with intelligent filtering and safety features. Automatically ignores build artifacts, caches, and common noise."

    @impl true
    def schema do
      %{
        type: "object",
        required: [],
        properties: %{
          directory: %{
            type: "string",
            description: "Directory path to list (default: current directory)"
          },
          recursive: %{
            type: "boolean",
            description: "Whether to list recursively (default: false)"
          }
        }
      }
    end

    @impl true
    def risk, do: :low

    @impl true
    def execute(args, context) do
      directory = Map.get(args, :directory, ".")
      recursive = Map.get(args, :recursive, false)
      root = Map.get(context, :project_root, File.cwd!())
      full = Path.expand(directory, root)
      skip = Map.get(context, :skip, @default_skip)

      cond do
        not String.starts_with?(full, root <> "/") and full != root ->
          {:error, %{directory: directory, reason: :path_escape}}

        not File.dir?(full) ->
          {:error, %{directory: directory, reason: :not_a_directory}}

        true ->
          entries = list_entries(full, root, recursive, skip)
          output = format_entries(entries)
          {:ok, %{directory: directory, recursive: recursive, entries: entries, output: output}}
      end
    end

    defp list_entries(dir, root, true, skip) do
      do_list_recursive(dir, root, skip)
    end

    defp list_entries(dir, _root, false, skip) do
      dir
      |> File.ls!()
      |> Enum.reject(fn entry -> entry in skip end)
      |> Enum.sort()
      |> Enum.map(fn entry ->
        full = Path.join(dir, entry)
        type = if File.dir?(full), do: :directory, else: :file
        %{name: entry, type: type}
      end)
    end

    defp do_list_recursive(dir, root, skip) do
      dir
      |> File.ls!()
      |> Enum.reject(fn entry -> entry in skip end)
      |> Enum.sort()
      |> Enum.flat_map(fn entry ->
        full = Path.join(dir, entry)

        if File.dir?(full) do
          [%{name: Path.relative_to(full, root), type: :directory}] ++
            do_list_recursive(full, root, skip)
        else
          [%{name: Path.relative_to(full, root), type: :file}]
        end
      end)
    end

    defp format_entries(entries) do
      entries
      |> Enum.map(fn
        %{type: :directory, name: name} -> "#{name}/"
        %{name: name} -> name
      end)
      |> Enum.join("\n")
    end
  end

  # ─── CreateFile ─────────────────────────────────────────────────────

  defmodule CreateFile do
    @moduledoc """
    Create a new file or overwrite an existing one with the provided content.

    Refuses to overwrite an existing file unless overwrite is true,
    matching Code Puppy's safety model.
    """

    @behaviour Spark.Tool

    @impl true
    def name, do: "create_file"

    @impl true
    def description,
      do: "Create a new file or overwrite an existing one with the provided content."

    @impl true
    def schema do
      %{
        type: "object",
        required: ["file_path", "content"],
        properties: %{
          file_path: %{type: "string", description: "Path for the new file"},
          content: %{type: "string", description: "Content to write"},
          overwrite: %{type: "boolean", description: "Allow overwriting existing file (default: false)"}
        }
      }
    end

    @impl true
    def risk, do: :medium

    @impl true
    def execute(args, context) do
      file_path = Map.get(args, :file_path)
      content = Map.get(args, :content, "")
      overwrite = Map.get(args, :overwrite, false)

      if is_nil(file_path) or file_path == "" do
        {:error, %{reason: :missing_file_path}}
      else
        root = Map.get(context, :project_root, File.cwd!())
        full = Path.expand(file_path, root)

        with :ok <- ensure_in_project_root?(full, root) do
          if File.exists?(full) and not overwrite do
            {:error, %{file_path: file_path, reason: :file_already_exists, hint: "Set overwrite: true to overwrite"}}
          else
            dir = Path.dirname(full)
            File.mkdir_p!(dir)

            existed_before = File.exists?(full)
            case File.write(full, content) do
              :ok ->
                {:ok, %{file_path: file_path, bytes_written: byte_size(content), overwritten: existed_before}}

              {:error, reason} ->
                {:error, %{file_path: file_path, reason: reason}}
            end
          end
        else
          {:error, {:path_escape, _}} -> {:error, %{file_path: file_path, reason: :path_escape}}
        end
      end
    end

    defp ensure_in_project_root?(full, root) do
      if String.starts_with?(full, root <> "/") or full == root do
        :ok
      else
        {:error, {:path_escape, full}}
      end
    end
  end

  # ─── ReplaceInFile ──────────────────────────────────────────────────

  defmodule ReplaceInFile do
    @moduledoc """
    Apply targeted text replacements to an existing file.

    Each replacement specifies an old_str to find and a new_str to replace it with.
    Replacements are applied sequentially. Prefer this over full file rewrites.
    """

    @behaviour Spark.Tool

    @impl true
    def name, do: "replace_in_file"

    @impl true
    def description,
      do:
        "Apply targeted text replacements to an existing file. Each replacement specifies an old_str to find and a new_str to replace it with. Replacements are applied sequentially."

    @impl true
    def schema do
      %{
        type: "object",
        required: ["file_path", "replacements"],
        properties: %{
          file_path: %{type: "string", description: "Path to the file to modify"},
          replacements: %{
            type: "array",
            items: %{
              type: "object",
              required: ["old_str", "new_str"],
              properties: %{
                old_str: %{type: "string", description: "Exact text to find"},
                new_str: %{type: "string", description: "Replacement text"}
              }
            },
            description: "List of replacements to apply sequentially"
          }
        }
      }
    end

    @impl true
    def risk, do: :medium

    @impl true
    def execute(args, context) do
      file_path = Map.get(args, :file_path)
      replacements = Map.get(args, :replacements, [])

      cond do
        is_nil(file_path) or file_path == "" ->
          {:error, %{reason: :missing_file_path}}

        not is_list(replacements) or replacements == [] ->
          {:error, %{file_path: file_path, reason: :empty_replacements}}

        true ->
          root = Map.get(context, :project_root, File.cwd!())
          full = Path.expand(file_path, root)

          with :ok <- ensure_in_project_root?(full, root),
               {:ok, content} <- File.read(full) do
            {new_content, results} = apply_replacements(content, replacements)

            case File.write(full, new_content) do
              :ok ->
                {:ok,
                 %{
                   file_path: file_path,
                   replacements_applied: length(results),
                   results: results
                 }}

              {:error, reason} ->
                {:error, %{file_path: file_path, reason: reason}}
            end
          else
            {:error, {:path_escape, _}} -> {:error, %{file_path: file_path, reason: :path_escape}}
            {:error, :enoent} -> {:error, %{file_path: file_path, reason: :file_not_found}}
            {:error, reason} -> {:error, %{file_path: file_path, reason: reason}}
          end
      end
    end

    defp ensure_in_project_root?(full, root) do
      if String.starts_with?(full, root <> "/") or full == root do
        :ok
      else
        {:error, {:path_escape, full}}
      end
    end

    defp apply_replacements(content, replacements) do
      Enum.reduce(replacements, {content, []}, fn rep, {acc, results} ->
        old_str = get_str_field(rep, :old_str)
        new_str = get_str_field(rep, :new_str)

        if String.contains?(acc, old_str) do
          new_acc = String.replace(acc, old_str, new_str, global: false)
          {new_acc, results ++ [%{found: true, old_str: truncate_str(old_str, 50)}]}
        else
          {acc, results ++ [%{found: false, old_str: truncate_str(old_str, 50), error: :not_found}]}
        end
      end)
    end

    defp get_str_field(map, key) when is_atom(key) do
      Map.get(map, key) || Map.get(map, Atom.to_string(key), "")
    end

    defp truncate_str(str, max) when is_binary(str) and byte_size(str) > max do
      binary_part(str, 0, max) <> "..."
    end

    defp truncate_str(str, _max), do: str
  end

  # ─── DeleteSnippet ──────────────────────────────────────────────────

  defmodule DeleteSnippet do
    @moduledoc """
    Remove the first occurrence of a text snippet from a file.
    """

    @behaviour Spark.Tool

    @impl true
    def name, do: "delete_snippet"

    @impl true
    def description, do: "Remove the first occurrence of a text snippet from a file."

    @impl true
    def schema do
      %{
        type: "object",
        required: ["file_path", "snippet"],
        properties: %{
          file_path: %{type: "string", description: "Path to the file"},
          snippet: %{type: "string", description: "Exact text snippet to remove"}
        }
      }
    end

    @impl true
    def risk, do: :medium

    @impl true
    def execute(args, context) do
      file_path = Map.get(args, :file_path)
      snippet = Map.get(args, :snippet)

      cond do
        is_nil(file_path) or file_path == "" ->
          {:error, %{reason: :missing_file_path}}

        is_nil(snippet) or snippet == "" ->
          {:error, %{file_path: file_path, reason: :missing_snippet}}

        true ->
          root = Map.get(context, :project_root, File.cwd!())
          full = Path.expand(file_path, root)

          with :ok <- ensure_in_project_root?(full, root),
               {:ok, content} <- File.read(full) do
            if String.contains?(content, snippet) do
              new_content = String.replace(content, snippet, "", global: false)

              case File.write(full, new_content) do
                :ok ->
                  {:ok, %{file_path: file_path, snippet_removed: true, bytes_removed: byte_size(snippet)}}

                {:error, reason} ->
                  {:error, %{file_path: file_path, reason: reason}}
              end
            else
              {:error, %{file_path: file_path, reason: :snippet_not_found}}
            end
          else
            {:error, {:path_escape, _}} -> {:error, %{file_path: file_path, reason: :path_escape}}
            {:error, :enoent} -> {:error, %{file_path: file_path, reason: :file_not_found}}
            {:error, reason} -> {:error, %{file_path: file_path, reason: reason}}
          end
      end
    end

    defp ensure_in_project_root?(full, root) do
      if String.starts_with?(full, root <> "/") or full == root do
        :ok
      else
        {:error, {:path_escape, full}}
      end
    end
  end

  # ─── DeleteFile ──────────────────────────────────────────────────────

  defmodule DeleteFile do
    @moduledoc """
    Safely delete a file and report the deletion.

    Delete operations intentionally do not generate or print diffs of removed content.
    Path scoped to project root.
    """

    @behaviour Spark.Tool

    @impl true
    def name, do: "delete_file"

    @impl true
    def description,
      do:
        "Safely delete a file and report the deletion. Delete operations intentionally do not generate or print diffs of removed content."

    @impl true
    def schema do
      %{
        type: "object",
        required: ["file_path"],
        properties: %{
          file_path: %{type: "string", description: "Path to the file to delete"}
        }
      }
    end

    @impl true
    def risk, do: :high

    @impl true
    def execute(args, context) do
      file_path = Map.get(args, :file_path)

      if is_nil(file_path) or file_path == "" do
        {:error, %{reason: :missing_file_path}}
      else
        root = Map.get(context, :project_root, File.cwd!())
        full = Path.expand(file_path, root)

        with :ok <- ensure_in_project_root?(full, root) do
          if File.exists?(full) and not File.dir?(full) do
            case File.rm(full) do
              :ok -> {:ok, %{file_path: file_path, deleted: true}}
              {:error, reason} -> {:error, %{file_path: file_path, reason: reason}}
            end
          else
            {:error, %{file_path: file_path, reason: :file_not_found}}
          end
        else
          {:error, {:path_escape, _}} -> {:error, %{file_path: file_path, reason: :path_escape}}
        end
      end
    end

    defp ensure_in_project_root?(full, root) do
      if String.starts_with?(full, root <> "/") or full == root do
        :ok
      else
        {:error, {:path_escape, full}}
      end
    end
  end

  # ─── AgentRunShellCommand ────────────────────────────────────────────

  defmodule AgentRunShellCommand do
    @moduledoc """
    Execute a shell command with comprehensive monitoring and safety features.

    Supports streaming output, timeout handling, and background execution.
    Code Puppy-compatible alias for bash with extended args.
    """

    @behaviour Spark.Tool

    @dangerous_patterns [
      ~r/\brm\s+.*-[rR].*[fF].*\s\/(\s|$)/,
      ~r/\brm\s+.*-[fF].*[rR].*\s\/(\s|$)/,
      ~r/\brm\s+.*--no-preserve-root/,
      ~r/\bsudo\b/,
      ~r/\bmkfs\b/,
      ~r/\bdd\s+if=.*of=\/dev\//,
      ~r/\bchmod\s+-R\s+777\s+\/$/,
      ~r/\bchown\s+-R\s+.*\s+\/$/,
      ~r/\bformat\s+[A-Z]:/i,
      ~r/\bshutdown\b/,
      ~r/\breboot\b/,
      ~r/\binit\s+[06]/,
      ~r/\bwget\s+.*\|\s*sh\b/,
      ~r/\bcurl\s+.*\|\s*(ba)?sh\b/
    ]

    @impl true
    def name, do: "agent_run_shell_command"

    @impl true
    def description,
      do:
        "Execute a shell command with comprehensive monitoring and safety features. Supports streaming output, timeout handling, and background execution."

    @impl true
    def schema do
      %{
        type: "object",
        required: ["command"],
        properties: %{
          command: %{type: "string", description: "Shell command to execute"},
          cwd: %{type: "string", description: "Working directory for the command"},
          timeout: %{type: "integer", description: "Timeout in seconds (default: 60)"},
          background: %{type: "boolean", description: "Run in background (default: false)"}
        }
      }
    end

    @impl true
    def risk, do: :high

    @impl true
    def execute(args, context) do
      command = Map.get(args, :command)
      cwd = Map.get(args, :cwd)
      timeout_secs = Map.get(args, :timeout, 60)
      background = Map.get(args, :background, false)
      root = Map.get(context, :project_root, File.cwd!())

      if is_nil(command) or command == "" do
        {:error, %{reason: :missing_command}}
      else
        case check_dangerous(command) do
          :ok ->
            # Resolve cwd relative to project root
            resolved_cwd =
              if cwd && cwd != "" do
                full = Path.expand(cwd, root)
                if String.starts_with?(full, root <> "/") or full == root, do: full, else: root
              else
                root
              end

            timeout_ms = timeout_secs * 1000

            if background do
              # Background: spawn and return immediately
              spawn(fn -> do_execute(command, resolved_cwd, timeout_ms) end)
              {:ok, %{command: command, status: :background, cwd: resolved_cwd}}
            else
              do_execute(command, resolved_cwd, timeout_ms)
            end

          {:error, _} ->
            {:error, %{command: command, reason: :dangerous_command_blocked}}
        end
      end
    end

    defp check_dangerous(command) do
      if Enum.any?(@dangerous_patterns, &Regex.match?(&1, command)) do
        {:error, %{reason: :dangerous_command_blocked, command: command}}
      else
        :ok
      end
    end

    defp do_execute(command, cwd, timeout_ms) do
      try do
        task =
          Task.async(fn ->
            {stdout, exit_code} = System.cmd("sh", ["-c", command], cd: cwd, stderr_to_stdout: true)
            {exit_code, stdout}
          end)

        case Task.yield(task, timeout_ms) || Task.shutdown(task, 5000) do
          {:ok, {exit_code, stdout}} ->
            {:ok, %{command: command, exit_code: exit_code, stdout: stdout, cwd: cwd}}

          nil ->
            {:error, %{command: command, reason: :timeout, cwd: cwd}}

          {:exit, reason} ->
            {:error, %{command: command, reason: {:crashed, reason}, cwd: cwd}}
        end
      rescue
        e ->
          {:error, %{command: command, reason: {:execution_error, Exception.message(e)}, cwd: cwd}}
      end
    end
  end
end
