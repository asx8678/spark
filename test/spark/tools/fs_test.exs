defmodule Spark.Tools.FSTest do
  use ExUnit.Case, async: false

  alias Spark.Tools.{ListDir, Glob, Grep}

  setup do
    tmp = Path.join(System.tmp_dir!(), "spark_fs_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    # Create a simple project structure
    File.write!(Path.join(tmp, "hello.ex"), "defmodule Hello do\n  def hello, do: :world\nend\n")
    File.write!(Path.join(tmp, "config.ex"), "defmodule Config do\n  def value, do: 42\nend\n")
    File.mkdir_p!(Path.join(tmp, "lib"))
    File.write!(Path.join(tmp, "lib/app.ex"), "defmodule App do\n  def run, do: :ok\nend\n")
    File.mkdir_p!(Path.join(tmp, ".git"))
    File.mkdir_p!(Path.join(tmp, "node_modules"))
    File.write!(Path.join(tmp, "lib/secret.ex"), "-- secret --")

    on_exit(fn ->
      File.rm_rf!(tmp)
    end)

    {:ok, project_root: tmp}
  end

  # --- ListDir ---

  describe "ListDir.execute/2" do
    test "lists directory contents", %{project_root: root} do
      assert {:ok, result} = ListDir.execute(%{path: "."}, %{project_root: root})
      assert "hello.ex" in result.entries
      assert "config.ex" in result.entries
      assert "lib" in result.entries
    end

    test "skips noise directories by default", %{project_root: root} do
      assert {:ok, result} = ListDir.execute(%{path: "."}, %{project_root: root})
      # .git and node_modules should be skipped
      refute ".git" in result.entries
      refute "node_modules" in result.entries
    end

    test "lists subdirectory", %{project_root: root} do
      assert {:ok, result} = ListDir.execute(%{path: "lib"}, %{project_root: root})
      assert "app.ex" in result.entries
      assert "secret.ex" in result.entries
    end

    test "returns error for non-existent directory", %{project_root: root} do
      assert {:error, reason} = ListDir.execute(%{path: "nonexistent"}, %{project_root: root})
      assert reason.reason == :not_a_directory
    end

    test "rejects path escaping project root", %{project_root: root} do
      assert {:error, reason} = ListDir.execute(%{path: "../../etc"}, %{project_root: root})
      assert reason.reason == :path_escape
    end

    test "returns error when path is missing" do
      assert {:error, reason} = ListDir.execute(%{}, %{})
      assert reason.reason == :missing_path
    end

    test "truncates large output", %{project_root: root} do
      # Create many files to exceed the small truncation limit
      for i <- 1..100 do
        File.write!(Path.join(root, "file_#{i}.txt"), String.duplicate("x", 100))
      end

      assert {:ok, result} =
               ListDir.execute(%{path: "."}, %{project_root: root, max_output_bytes: 200})

      assert result.truncated == true
      assert String.contains?(result.output, "truncated")
    end
  end

  # --- Glob ---

  describe "Glob.execute/2" do
    test "finds files matching a glob pattern", %{project_root: root} do
      assert {:ok, result} = Glob.execute(%{pattern: "**/*.ex"}, %{project_root: root})
      assert result.count >= 4
      assert "hello.ex" in result.matches
      assert "lib/app.ex" in result.matches
    end

    test "returns empty list for no matches", %{project_root: root} do
      assert {:ok, result} = Glob.execute(%{pattern: "**/*.xyz"}, %{project_root: root})
      assert result.count == 0
    end

    test "returns error when pattern is missing" do
      assert {:error, reason} = Glob.execute(%{}, %{})
      assert reason.reason == :missing_pattern
    end

    test "scopes results to project root", %{project_root: root} do
      assert {:ok, result} = Glob.execute(%{pattern: "**/*.ex"}, %{project_root: root})
      # All matches should be relative to root
      Enum.each(result.matches, fn match ->
        refute String.starts_with?(match, "/")
      end)
    end
  end

  # --- Grep ---

  describe "Grep.execute/2" do
    test "finds pattern in files", %{project_root: root} do
      assert {:ok, result} = Grep.execute(%{pattern: "defmodule"}, %{project_root: root})
      assert result.matches > 0
      assert String.contains?(result.output, "defmodule")
    end

    test "reports no matches for missing pattern", %{project_root: root} do
      assert {:ok, result} = Grep.execute(%{pattern: "ZYGXWVUT"}, %{project_root: root})
      assert result.matches == 0
    end

    test "shows file and line numbers", %{project_root: root} do
      assert {:ok, result} = Grep.execute(%{pattern: "defmodule"}, %{project_root: root})
      # Output should include file:line: format
      assert String.contains?(result.output, ":")
    end

    test "skips noise directories", %{project_root: root} do
      # Put a file in .git that would match
      File.write!(Path.join(root, ".git/config"), "defmodule Hidden do end")
      assert {:ok, result} = Grep.execute(%{pattern: "defmodule"}, %{project_root: root})
      # .git should be skipped
      refute String.contains?(result.output, ".git/config")
    end

    test "rejects path escaping project root", %{project_root: root} do
      assert {:error, reason} =
               Grep.execute(%{pattern: "test"}, %{project_root: root, search_path: "../../etc"})

      assert reason.reason == :path_escape
    end

    test "returns error when pattern is missing" do
      assert {:error, reason} = Grep.execute(%{}, %{})
      assert reason.reason == :missing_pattern
    end

    test "truncates large output", %{project_root: root} do
      # Create a file with many matching lines
      content = Enum.map(1..500, fn i -> "pattern_match_line_#{i}" end) |> Enum.join("\n")
      File.write!(Path.join(root, "big_match.txt"), content)

      assert {:ok, result} =
               Grep.execute(%{pattern: "pattern_match"}, %{
                 project_root: root,
                 max_output_bytes: 200
               })

      assert result.truncated == true
    end
  end
end
