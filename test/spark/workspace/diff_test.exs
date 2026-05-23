defmodule Spark.Workspace.DiffTest do
  use ExUnit.Case, async: true

  alias Spark.Workspace.Diff

  describe "capture_diff/2" do
    setup do
      dir = System.tmp_dir!()
      dir = Path.join(dir, "spark_diff_test_#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      {:ok, dir: dir}
    end

    test "generates diff for existing file", %{dir: dir} do
      file_path = Path.join(dir, "test.ex")
      File.write!(file_path, "line 1\nline 2\nline 3\n")

      {:ok, diff} = Diff.capture_diff(file_path, "line 1\nmodified line\nline 3\n")
      assert diff =~ "modified"
      assert diff =~ "-line 2"
    end

    test "generates diff for new file (enoent)", %{dir: dir} do
      file_path = Path.join(dir, "new_file.ex")

      {:ok, diff} = Diff.capture_diff(file_path, "new content\n")
      assert diff =~ "/dev/null"
      assert diff =~ "new content"
    end

    test "diff shows additions and deletions", %{dir: dir} do
      file_path = Path.join(dir, "changed.ex")
      File.write!(file_path, "alpha\nbeta\ngamma\n")

      {:ok, diff} = Diff.capture_diff(file_path, "alpha\ndelta\ngamma\n")
      assert diff =~ "-"   # should have removals
      assert diff =~ "+"   # should have additions
    end
  end

  describe "summarize_diff/1" do
    test "summarizes additions and deletions" do
      diff = "- removed line\n- another removal\n+ added line\n+ another addition\n  context line"
      summary = Diff.summarize_diff(diff)
      assert summary =~ "2 additions"
      assert summary =~ "2 deletions"
      assert summary =~ "lines"
    end

    test "handles empty diff" do
      summary = Diff.summarize_diff("")
      assert summary =~ "0 additions"
      assert summary =~ "0 deletions"
    end

    test "singular form for single addition/deletion" do
      diff = "- one removal\n+ one addition\n  context"
      summary = Diff.summarize_diff(diff)
      assert summary =~ "1 addition"
      assert summary =~ "1 deletion"
    end
  end

  describe "detect_git?/1" do
    test "detects git in a git repo" do
      # This test assumes we're running in a git repo (the spark project)
      assert Diff.detect_git?("/Users/adam2/projects/spark")
    end

    test "returns false for non-git directory" do
      dir = System.tmp_dir!()
      refute Diff.detect_git?(dir)
    end
  end
end
