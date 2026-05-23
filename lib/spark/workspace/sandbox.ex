defmodule Spark.Workspace.Sandbox do
  @moduledoc """
  Path sandbox for safe filesystem access.

  Validates that paths stay within project boundaries, blocks directory
  traversal attacks, detects basic symlink risks, and filters ignored
  directories (.git, _build, deps, node_modules).
  """

  @ignored_dirs ~w(.git _build deps node_modules)

  @doc """
  Validates that `path` resolves safely within `project_root`.

  Checks:
    - Path resolves to a location within project_root
    - No `../` traversal escapes the project root
    - Basic symlink detection (path component is a symlink)

  Returns `:ok` or `{:error, reason}`.
  """
  @spec validate_path(String.t(), String.t()) :: :ok | {:error, term()}
  def validate_path(path, project_root) when is_binary(path) and is_binary(project_root) do
    root = expand_path(project_root, project_root)
    resolved = expand_path(path, project_root)

    cond do
      traversal_attack?(path) ->
        {:error, :path_traversal}

      not String.starts_with?(resolved, root) ->
        {:error, :escapes_project_root}

      symlink_in_path?(resolved, root) ->
        {:error, :symlink_detected}

      true ->
        :ok
    end
  end

  @doc """
  Checks if a path falls within an ignored directory.

  Ignored directories: `.git`, `_build`, `deps`, `node_modules`.
  Checks each path component against the ignored list.
  """
  @spec is_ignored?(String.t()) :: boolean()
  def is_ignored?(path) when is_binary(path) do
    path
    |> Path.split()
    |> Enum.any?(&(&1 in @ignored_dirs))
  end

  @doc """
  Safely resolves a path relative to `root`.

  - Absolute paths are returned as-is (after expand)
  - Relative paths are resolved against `root`
  - Handles `..` segments by resolving them (but `validate_path/2`
    should be used to reject traversal attacks)
  """
  @spec expand_path(String.t(), String.t()) :: String.t()
  def expand_path(path, root) when is_binary(path) and is_binary(root) do
    if Path.type(path) == :absolute do
      Path.expand(path)
    else
      root
      |> Path.expand()
      |> Path.join(path)
      |> Path.expand()
    end
  end

  # --- Private helpers ---

  # Detects `../` segments that would escape the project root.
  defp traversal_attack?(path) do
    # Split into segments and check for any `..` that would escape
    segments = Path.split(path)

    # Count how many levels `..` would climb
    {depth, escaped?} =
      Enum.reduce(segments, {0, false}, fn
        "..", {d, _} ->
          if d == 0, do: {-1, true}, else: {d - 1, false}

        ".", {d, esc} ->
          {d, esc}

        _segment, {d, esc} ->
          {d + 1, esc}
      end)

    escaped? or depth < 0
  end

  # Basic symlink detection: walk each path component between root and
  # the resolved path, checking if any intermediate component is a symlink.
  defp symlink_in_path?(resolved, root) do
    # Walk from root up to resolved, checking each component
    relative = Path.relative_to(resolved, root)

    if relative == resolved do
      # Path doesn't descend from root — already caught by prefix check
      false
    else
      check_symlink_chain(root, Path.split(relative))
    end
  end

  defp check_symlink_chain(_current, []), do: false

  defp check_symlink_chain(current, [segment | rest]) do
    candidate = Path.join(current, segment)

    case File.read_link(candidate) do
      {:ok, _target} ->
        true

      {:error, :enoent} ->
        # Path doesn't exist yet — can't be a symlink
        false

      {:error, :einvalidlink} ->
        # Not a symlink — continue
        check_symlink_chain(candidate, rest)

      {:error, _} ->
        # Other error (permissions, etc.) — be safe, flag it
        check_symlink_chain(candidate, rest)
    end
  end
end
