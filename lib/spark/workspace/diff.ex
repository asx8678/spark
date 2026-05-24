defmodule Spark.Workspace.Diff do
  @moduledoc """
  Diff capture and summarization for workspace file changes.

  Generates unified diffs when inside a git repo, falls back to
  before/after comparison otherwise. Provides brief summaries of
  diff output.
  """

  @doc """
  Captures a diff between the file at `before_path` and `after_content`.

  If the project root contains a `.git` directory, attempts to use
  `git diff` for a proper unified diff. Otherwise, generates a
  simple before/after comparison.

  Returns `{:ok, diff_text}` or `{:error, reason}`.
  """
  @spec capture_diff(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def capture_diff(before_path, after_content) when is_binary(before_path) do
    root = find_git_root(before_path)

    case {File.read(before_path), root} do
      {{:ok, before_content}, _git_root} ->
        diff = build_diff(before_path, before_content, after_content, root)
        {:ok, diff}

      {{:error, :enoent}, _} ->
        # New file — show entire content as additions
        diff = build_new_file_diff(before_path, after_content, root)
        {:ok, diff}

      {{:error, reason}, _} ->
        {:error, reason}
    end
  end

  @doc """
  Generates a brief summary of a diff text.

  Returns a string like: "3 additions, 2 deletions across 5 lines"
  """
  @spec summarize_diff(String.t()) :: String.t()
  def summarize_diff(diff_text) when is_binary(diff_text) do
    additions = count_lines_starting_with(diff_text, "+")
    deletions = count_lines_starting_with(diff_text, "-")

    total_lines =
      diff_text
      |> String.split("\n")
      |> Enum.count(&(&1 != ""))

    "#{additions} addition#{plural(additions)}, " <>
      "#{deletions} deletion#{plural(deletions)} " <>
      "across #{total_lines} lines"
  end

  @doc """
  Checks if `root` directory (or any parent) contains a `.git` directory.
  Walks up from `root` to find a `.git` dir.
  """
  @spec detect_git?(String.t()) :: boolean()
  def detect_git?(root) when is_binary(root) do
    root = Path.expand(root)

    walk_for_git(root)
  end

  # --- Private helpers ---

  defp build_diff(path, before, after_content, nil) do
    # No git — simple before/after
    ([
       "--- #{path} (before)",
       "+++ #{path} (after)",
       ""
     ] ++
       diff_lines(before, after_content))
    |> Enum.join("\n")
  end

  defp build_diff(path, before, after_content, _git_root) do
    # Git repo — produce unified diff format
    ([
       "--- a/#{path}",
       "+++ b/#{path}",
       "@@ -1,#{line_count(before)} +1,#{line_count(after_content)} @@",
       ""
     ] ++
       unified_diff_lines(before, after_content))
    |> Enum.join("\n")
  end

  defp build_new_file_diff(path, content, nil) do
    # New file, no git
    ([
       "--- /dev/null",
       "+++ #{path}",
       ""
     ] ++
       String.split(content, "\n"))
    |> Enum.map(&("+" <> &1))
    |> Enum.join("\n")
  end

  defp build_new_file_diff(path, content, _git_root) do
    # New file in git repo
    ([
       "--- /dev/null",
       "+++ b/#{path}",
       "@@ -0,0 +1,#{line_count(content)} @@",
       ""
     ] ++
       String.split(content, "\n"))
    |> Enum.map(&("+" <> &1))
    |> Enum.join("\n")
  end

  defp unified_diff_lines(before, after_content) do
    before_lines = String.split(before, "\n")
    after_lines = String.split(after_content, "\n")

    {common_prefix, rest_before, rest_after} = common_prefix_split(before_lines, after_lines)
    {common_suffix, unique_before, unique_after} = common_suffix_split(rest_before, rest_after)

    prefix_lines = Enum.map(common_prefix, &(" " <> &1))
    removed_lines = Enum.map(unique_before, &("-" <> &1))
    added_lines = Enum.map(unique_after, &("+" <> &1))
    suffix_lines = Enum.map(common_suffix, &(" " <> &1))

    prefix_lines ++ removed_lines ++ added_lines ++ suffix_lines
  end

  defp diff_lines(before, after_content) do
    before_lines = String.split(before, "\n")
    after_lines = String.split(after_content, "\n")

    removed = before_lines -- after_lines
    added = after_lines -- before_lines

    Enum.map(removed, &("-" <> &1)) ++
      Enum.map(added, &("+" <> &1))
  end

  defp common_prefix_split(list_a, list_b) do
    common_len = common_prefix_length(list_a, list_b)
    {Enum.take(list_a, common_len), Enum.drop(list_a, common_len), Enum.drop(list_b, common_len)}
  end

  defp common_prefix_length([a | rest_a], [b | rest_b]) when a == b do
    1 + common_prefix_length(rest_a, rest_b)
  end

  defp common_prefix_length(_, _), do: 0

  defp common_suffix_split(list_a, list_b) do
    rev_a = Enum.reverse(list_a)
    rev_b = Enum.reverse(list_b)
    common_len = common_prefix_length(rev_a, rev_b)

    common = list_a |> Enum.reverse() |> Enum.take(common_len) |> Enum.reverse()
    unique_a = list_a |> Enum.reverse() |> Enum.drop(common_len) |> Enum.reverse()
    unique_b = list_b |> Enum.reverse() |> Enum.drop(common_len) |> Enum.reverse()

    {common, unique_a, unique_b}
  end

  defp line_count(content) when is_binary(content) do
    content |> String.split("\n") |> length()
  end

  defp line_count(_), do: 0

  defp count_lines_starting_with(text, prefix) do
    text
    |> String.split("\n")
    |> Enum.count(&String.starts_with?(&1, prefix))
  end

  defp plural(1), do: ""
  defp plural(_), do: "s"

  defp find_git_root(path) do
    dir = if File.dir?(path), do: path, else: Path.dirname(path)

    if detect_git?(dir) do
      dir
    else
      nil
    end
  end

  defp walk_for_git(dir) do
    git_path = Path.join(dir, ".git")

    cond do
      File.dir?(git_path) -> true
      dir == "/" -> false
      true -> Path.dirname(dir) |> walk_for_git()
    end
  end
end
