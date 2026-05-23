defmodule Spark.Workspace.SandboxTest do
  use ExUnit.Case, async: true

  alias Spark.Workspace.Sandbox

  describe "validate_path/2" do
    test "allows paths within project root" do
      assert :ok = Sandbox.validate_path("src/foo.ex", "/project")
    end

    test "allows absolute paths within project root" do
      assert :ok = Sandbox.validate_path("/project/src/foo.ex", "/project")
    end

    test "rejects path traversal with ../" do
      assert {:error, reason} = Sandbox.validate_path("../../etc/passwd", "/project")
      assert reason in [:path_traversal, :escapes_project_root]
    end

    test "rejects path that escapes project root" do
      result = Sandbox.validate_path("/other_project/file.ex", "/project")
      assert {:error, :escapes_project_root} = result
    end

    test "allows simple relative paths" do
      assert :ok = Sandbox.validate_path("lib/spark/app.ex", "/project")
    end

    test "rejects deeply nested traversal" do
      assert {:error, :path_traversal} = Sandbox.validate_path("a/b/../../../etc/passwd", "/project")
    end
  end

  describe "is_ignored?/1" do
    test "detects .git as ignored" do
      assert Sandbox.is_ignored?(".git/config")
    end

    test "detects _build as ignored" do
      assert Sandbox.is_ignored?("_build/dev/lib/spark")
    end

    test "detects deps as ignored" do
      assert Sandbox.is_ignored?("deps/phoenix/lib")
    end

    test "detects node_modules as ignored" do
      assert Sandbox.is_ignored?("node_modules/react/index.js")
    end

    test "normal project paths are not ignored" do
      refute Sandbox.is_ignored?("lib/spark/worker.ex")
    end

    test "path with ignored dir as component is detected" do
      assert Sandbox.is_ignored?("/project/deps/phoenix/mix.exs")
    end
  end

  describe "expand_path/2" do
    test "resolves relative paths against root" do
      result = Sandbox.expand_path("src/foo.ex", "/project")
      assert result == Path.expand("/project/src/foo.ex")
    end

    test "absolute paths are returned expanded" do
      result = Sandbox.expand_path("/absolute/path/file.ex", "/project")
      assert result == "/absolute/path/file.ex"
    end

    test "resolves . segments" do
      result = Sandbox.expand_path("./src/foo.ex", "/project")
      assert result == Path.expand("/project/src/foo.ex")
    end
  end
end
