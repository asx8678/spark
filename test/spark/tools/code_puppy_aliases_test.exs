defmodule Spark.Tools.CodePuppyAliasesTest do
  use ExUnit.Case, async: false

  alias Spark.ToolRegistry
  alias Spark.ToolRunner

  @base_ctx %{task_id: "test_task_1"}

  setup do
    ToolRegistry.clear()

    on_exit(fn ->
      ToolRegistry.clear()
    end)

    :ok
  end

  describe "ListFiles tool" do
    test "implements Spark.Tool behaviour" do
      assert Spark.Tool.implements?(Spark.Tools.CodePuppyAliases.ListFiles)
    end

    test "has correct name" do
      assert Spark.Tools.CodePuppyAliases.ListFiles.name() == "list_files"
    end

    test "has Code Puppy description" do
      desc = Spark.Tools.CodePuppyAliases.ListFiles.description()
      assert desc =~ "intelligent filtering"
      assert desc =~ "safety features"
    end
  end

  describe "CreateFile tool" do
    test "implements Spark.Tool behaviour" do
      assert Spark.Tool.implements?(Spark.Tools.CodePuppyAliases.CreateFile)
    end

    test "has correct name" do
      assert Spark.Tools.CodePuppyAliases.CreateFile.name() == "create_file"
    end

    test "refuses overwrite by default" do
      ToolRegistry.register(Spark.Tools.CodePuppyAliases.CreateFile)

      # Use a path within the project root (tmp under the project)
      tmp_dir = Path.join(File.cwd!(), "tmp_test_cp")
      File.mkdir_p!(tmp_dir)
      tmp_path = Path.join(tmp_dir, "spark_cp_test_#{:erlang.unique_integer([:positive])}.txt")

      # Create first time
      rel_path = Path.relative_to(tmp_path, File.cwd!())
      assert {:ok, _} =
               ToolRunner.run("create_file", %{file_path: rel_path, content: "hello"}, @base_ctx)

      # Second time without overwrite should fail
      assert {:error, _} =
               ToolRunner.run("create_file", %{file_path: rel_path, content: "world"}, @base_ctx)

      # With overwrite should succeed
      assert {:ok, _} =
               ToolRunner.run("create_file", %{file_path: rel_path, content: "world", overwrite: true}, @base_ctx)

      # Cleanup
      File.rm(tmp_path)
      File.rmdir(tmp_dir)
    end
  end

  describe "ReplaceInFile tool" do
    test "implements Spark.Tool behaviour" do
      assert Spark.Tool.implements?(Spark.Tools.CodePuppyAliases.ReplaceInFile)
    end

    test "has correct name" do
      assert Spark.Tools.CodePuppyAliases.ReplaceInFile.name() == "replace_in_file"
    end

    test "applies sequential replacements" do
      ToolRegistry.register(Spark.Tools.CodePuppyAliases.ReplaceInFile)

      tmp_dir = Path.join(File.cwd!(), "tmp_test_cp")
      File.mkdir_p!(tmp_dir)
      tmp_path = Path.join(tmp_dir, "spark_cp_replace_#{:erlang.unique_integer([:positive])}.txt")
      File.write!(tmp_path, "hello world foo bar")

      rel_path = Path.relative_to(tmp_path, File.cwd!())

      replacements = [
        %{old_str: "hello", new_str: "goodbye"},
        %{old_str: "foo", new_str: "baz"}
      ]

      assert {:ok, result} =
               ToolRunner.run("replace_in_file", %{file_path: rel_path, replacements: replacements}, @base_ctx)

      assert result.result.replacements_applied == 2
      assert File.read!(tmp_path) == "goodbye world baz bar"

      File.rm(tmp_path)
      File.rmdir(tmp_dir)
    end
  end

  describe "DeleteSnippet tool" do
    test "implements Spark.Tool behaviour" do
      assert Spark.Tool.implements?(Spark.Tools.CodePuppyAliases.DeleteSnippet)
    end

    test "has correct name" do
      assert Spark.Tools.CodePuppyAliases.DeleteSnippet.name() == "delete_snippet"
    end

    test "removes first occurrence" do
      ToolRegistry.register(Spark.Tools.CodePuppyAliases.DeleteSnippet)

      tmp_dir = Path.join(File.cwd!(), "tmp_test_cp")
      File.mkdir_p!(tmp_dir)
      tmp_path = Path.join(tmp_dir, "spark_cp_del_#{:erlang.unique_integer([:positive])}.txt")
      File.write!(tmp_path, "hello world hello world")

      rel_path = Path.relative_to(tmp_path, File.cwd!())

      assert {:ok, _} =
               ToolRunner.run("delete_snippet", %{file_path: rel_path, snippet: "hello "}, @base_ctx)

      # Only first occurrence removed
      assert File.read!(tmp_path) == "world hello world"

      File.rm(tmp_path)
      File.rmdir(tmp_dir)
    end
  end

  describe "DeleteFile tool" do
    test "implements Spark.Tool behaviour" do
      assert Spark.Tool.implements?(Spark.Tools.CodePuppyAliases.DeleteFile)
    end

    test "has correct name" do
      assert Spark.Tools.CodePuppyAliases.DeleteFile.name() == "delete_file"
    end

    test "deletes an existing file (when policy allows)" do
      # delete_file has :high risk but policy may classify it as critical.
      # Verify the tool module works by calling execute directly, bypassing policy.
      args = %{file_path: "tmp_test_cp/spark_cp_delfile_test.txt"}
      tmp_dir = Path.join(File.cwd!(), "tmp_test_cp")
      File.mkdir_p!(tmp_dir)
      tmp_path = Path.join(tmp_dir, "spark_cp_delfile_test.txt")
      File.write!(tmp_path, "delete me")

      assert {:ok, _} = Spark.Tools.CodePuppyAliases.DeleteFile.execute(args, %{})
      refute File.exists?(tmp_path)

      File.rmdir(tmp_dir)
    end
  end

  describe "AgentRunShellCommand tool" do
    test "implements Spark.Tool behaviour" do
      assert Spark.Tool.implements?(Spark.Tools.CodePuppyAliases.AgentRunShellCommand)
    end

    test "has correct name" do
      assert Spark.Tools.CodePuppyAliases.AgentRunShellCommand.name() == "agent_run_shell_command"
    end

    test "executes a simple command" do
      ToolRegistry.register(Spark.Tools.CodePuppyAliases.AgentRunShellCommand)

      assert {:ok, result} =
               ToolRunner.run("agent_run_shell_command", %{command: "echo hello"}, @base_ctx)

      assert result.result.exit_code == 0
      assert result.result.stdout =~ "hello"
    end

    test "blocks dangerous commands" do
      ToolRegistry.register(Spark.Tools.CodePuppyAliases.AgentRunShellCommand)

      assert {:error, _} =
               ToolRunner.run("agent_run_shell_command", %{command: "sudo rm -rf /"}, @base_ctx)
    end
  end
end
