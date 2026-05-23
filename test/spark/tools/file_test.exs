defmodule Spark.Tools.FileTest do
  use ExUnit.Case, async: false

  alias Spark.Tools.{ReadFile, WriteFile, EditFile}

  setup do
    # Create a temp project root for each test
    tmp = Path.join(System.tmp_dir!(), "spark_file_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    on_exit(fn ->
      File.rm_rf!(tmp)
    end)

    {:ok, project_root: tmp}
  end

  # --- ReadFile ---

  describe "ReadFile.execute/2" do
    test "reads an existing file", %{project_root: root} do
      File.write!(Path.join(root, "hello.txt"), "hello world")
      assert {:ok, result} = ReadFile.execute(%{path: "hello.txt"}, %{project_root: root})
      assert result.content == "hello world"
      assert result.truncated == false
    end

    test "returns error for missing file", %{project_root: root} do
      assert {:error, reason} = ReadFile.execute(%{path: "missing.txt"}, %{project_root: root})
      assert reason.reason == :file_not_found
    end

    test "rejects path escaping project root", %{project_root: root} do
      assert {:error, reason} = ReadFile.execute(%{path: "../../etc/passwd"}, %{project_root: root})
      assert reason.reason == :path_escape
    end

    test "truncates large files", %{project_root: root} do
      big = String.duplicate("A", 1000)
      File.write!(Path.join(root, "big.txt"), big)
      assert {:ok, result} = ReadFile.execute(%{path: "big.txt"}, %{project_root: root, max_output_bytes: 100})
      assert result.truncated == true
      assert String.contains?(result.content, "truncated")
    end

    test "returns error when path is missing" do
      assert {:error, reason} = ReadFile.execute(%{}, %{})
      assert reason.reason == :missing_path
    end
  end

  # --- WriteFile ---

  describe "WriteFile.execute/2" do
    test "writes content to a new file", %{project_root: root} do
      assert {:ok, result} = WriteFile.execute(
        %{path: "new_file.txt", content: "hello", task_id: "t1"},
        %{project_root: root}
      )
      assert result.bytes_written == 5
      assert File.read!(Path.join(root, "new_file.txt")) == "hello"
    end

    test "creates intermediate directories", %{project_root: root} do
      assert {:ok, _} = WriteFile.execute(
        %{path: "sub/dir/file.txt", content: "nested", task_id: "t1"},
        %{project_root: root}
      )
      assert File.read!(Path.join(root, "sub/dir/file.txt")) == "nested"
    end

    test "requires task_id", %{project_root: root} do
      assert {:error, reason} = WriteFile.execute(
        %{path: "nope.txt", content: "data"},
        %{project_root: root}
      )
      assert reason.reason == :missing_required_fields
    end

    test "rejects path escaping project root", %{project_root: root} do
      assert {:error, reason} = WriteFile.execute(
        %{path: "../../tmp/evil.txt", content: "bad", task_id: "t1"},
        %{project_root: root}
      )
      assert reason.reason == :path_escape
    end

    test "returns error with empty task_id", %{project_root: root} do
      assert {:error, reason} = WriteFile.execute(
        %{path: "nope.txt", content: "data", task_id: ""},
        %{project_root: root}
      )
      assert reason.reason == :missing_required_fields
    end
  end

  # --- EditFile ---

  describe "EditFile.execute/2" do
    test "performs exact search/replace", %{project_root: root} do
      File.write!(Path.join(root, "edit.txt"), "foo bar baz")
      assert {:ok, result} = EditFile.execute(
        %{path: "edit.txt", search: "bar", replace: "qux", task_id: "t1"},
        %{project_root: root}
      )
      assert result.replacements == 1
      assert File.read!(Path.join(root, "edit.txt")) == "foo qux baz"
    end

    test "fails when search string not found", %{project_root: root} do
      File.write!(Path.join(root, "edit2.txt"), "hello world")
      assert {:error, reason} = EditFile.execute(
        %{path: "edit2.txt", search: "missing", replace: "nope", task_id: "t1"},
        %{project_root: root}
      )
      assert reason.reason == :search_not_found
    end

    test "fails when search string appears multiple times", %{project_root: root} do
      File.write!(Path.join(root, "edit3.txt"), "ha ha ha")
      assert {:error, reason} = EditFile.execute(
        %{path: "edit3.txt", search: "ha", replace: "ho", task_id: "t1"},
        %{project_root: root}
      )
      assert reason.reason == :ambiguous_match
    end

    test "requires task_id", %{project_root: root} do
      File.write!(Path.join(root, "edit4.txt"), "some content")
      assert {:error, reason} = EditFile.execute(
        %{path: "edit4.txt", search: "some", replace: "any"},
        %{project_root: root}
      )
      assert reason.reason == :missing_required_fields
    end

    test "rejects path escaping project root", %{project_root: root} do
      assert {:error, reason} = EditFile.execute(
        %{path: "../../etc/hosts", search: "a", replace: "b", task_id: "t1"},
        %{project_root: root}
      )
      assert reason.reason == :path_escape
    end

    test "fails on missing file", %{project_root: root} do
      assert {:error, reason} = EditFile.execute(
        %{path: "nope.txt", search: "a", replace: "b", task_id: "t1"},
        %{project_root: root}
      )
      assert reason.reason == :file_not_found
    end
  end
end
