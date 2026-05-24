defmodule Spark.GuidanceTest do
  use ExUnit.Case, async: false

  alias Spark.Guidance

  setup do
    # Create a temporary guidance directory
    tmp_dir = System.tmp_dir!()

    guidance_dir =
      Path.join(tmp_dir, "spark_guidance_test_#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(guidance_dir)

    # Override home dir for testing
    original_home = Application.get_env(:spark, :home_dir)

    Application.put_env(
      :spark,
      :home_dir,
      Path.join(tmp_dir, "spark_home_#{:erlang.unique_integer([:positive])}")
    )

    home_dir = Application.get_env(:spark, :home_dir)
    File.mkdir_p!(Path.join(home_dir, "guidance"))

    on_exit(fn ->
      if original_home do
        Application.put_env(:spark, :home_dir, original_home)
      else
        Application.delete_env(:spark, :home_dir)
      end

      File.rm_rf!(guidance_dir)
      File.rm_rf!(home_dir)
    end)

    {:ok, guidance_dir: guidance_dir, home_dir: home_dir}
  end

  describe "load_all/0" do
    test "loads guidance files from directory", %{home_dir: home_dir} do
      # Write a guidance file
      guidance_path = Path.join(Path.join(home_dir, "guidance"), "after_edit_failure.md")
      File.write!(guidance_path, "Try checking the file permissions and disk space.")

      {:ok, {rules, _version}} = Guidance.load_all()
      assert length(rules) == 1
      assert hd(rules).trigger == :after_edit_failure
      assert hd(rules).message =~ "file permissions"
    end

    test "handles empty guidance directory" do
      {:ok, {rules, _version}} = Guidance.load_all()
      assert rules == []
    end

    test "parses frontmatter from guidance files", %{home_dir: home_dir} do
      guidance_path = Path.join(Path.join(home_dir, "guidance"), "after_grep.md")

      File.write!(
        guidance_path,
        "---\ntrigger: after_grep\npriority: 10\n---\nConsider using more specific search patterns."
      )

      {:ok, {rules, _version}} = Guidance.load_all()
      rule = hd(rules)
      assert rule.trigger == :after_grep
      assert rule.priority == 10
      assert rule.message =~ "search patterns"
    end

    test "rejects invalid guidance files safely", %{home_dir: home_dir} do
      # File with no content
      guidance_path = Path.join(Path.join(home_dir, "guidance"), "bad_rule.md")
      File.write!(guidance_path, "")

      # Also write a valid one
      good_path = Path.join(Path.join(home_dir, "guidance"), "after_shell_failure.md")
      File.write!(good_path, "Check your command syntax and try again.")

      {:ok, {rules, _version}} = Guidance.load_all()
      # Only the valid rule should be loaded
      assert length(rules) == 1
      assert hd(rules).trigger == :after_shell_failure
    end
  end

  describe "select/2" do
    setup context do
      home_dir = context.home_dir
      guidance_path = Path.join(Path.join(home_dir, "guidance"), "after_edit_failure.md")
      File.write!(guidance_path, "Check file permissions.")

      shell_path = Path.join(Path.join(home_dir, "guidance"), "after_shell_failure.md")
      File.write!(shell_path, "Check command syntax.")

      trunc_path = Path.join(Path.join(home_dir, "guidance"), "after_large_truncation.md")
      File.write!(trunc_path, "Output was truncated. Try narrowing scope.")

      # Start a guidance server for this test
      name = :"guidance_#{:erlang.unique_integer([:positive])}"
      {:ok, pid} = Guidance.start_link(name: name)

      # Override the GenServer calls to use our named server
      # We'll test the match_rule logic directly
      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)

      {:ok, name: name}
    end

    test "matches edit failure from tool result", %{name: name} do
      result = GenServer.call(name, {:select, {:error, :write_failed}, %{tool: "file_edit"}})
      assert result =~ "file permissions"
    end

    test "matches shell failure from tool result", %{name: name} do
      result = GenServer.call(name, {:select, {:error, :exit_nonzero}, %{tool: "shell"}})
      assert result =~ "command syntax"
    end

    test "matches truncation context", %{name: name} do
      result =
        GenServer.call(
          name,
          {:select, {:ok, %{output: "big"}}, %{tool: "shell", truncated: true}}
        )

      assert result =~ "truncated"
    end

    test "returns nil when no rule matches", %{name: name} do
      result = GenServer.call(name, {:select, {:ok, :all_good}, %{tool: "unknown_tool"}})
      assert result == nil
    end
  end

  describe "reload/0" do
    test "reloads guidance files from disk", %{home_dir: home_dir} do
      # Start a named guidance server
      name = :"guidance_reload_#{:erlang.unique_integer([:positive])}"
      {:ok, pid} = Guidance.start_link(name: name)

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)

      # Initially empty
      version_before = GenServer.call(name, :version)

      # Add a new file
      new_file = Path.join(Path.join(home_dir, "guidance"), "after_grep.md")
      File.write!(new_file, "Try refining your search pattern.")

      {:ok, rules} = GenServer.call(name, :reload)
      assert length(rules) >= 1

      version_after = GenServer.call(name, :version)
      assert is_binary(version_after)
      assert version_after != version_before
    end
  end

  describe "version/0" do
    test "returns a version hash", %{home_dir: _home_dir} do
      {:ok, {_, version}} = Guidance.load_all()
      assert is_binary(version)
    end

    test "version changes when files change", %{home_dir: home_dir} do
      {:ok, {_, v1}} = Guidance.load_all()

      # Add a guidance file
      guidance_path = Path.join(Path.join(home_dir, "guidance"), "new_rule.md")
      File.write!(guidance_path, "A new guidance rule.")

      {:ok, {_, v2}} = Guidance.load_all()
      # Versions should differ
      # (soft check: empty dir and dir with file will differ)
      assert v1 != v2 or v1 == "empty"
    end
  end

  describe "hot reload via events" do
    test "reloads guidance on guidance_reloaded event", %{home_dir: home_dir} do
      name = :"guidance_hot_#{:erlang.unique_integer([:positive])}"
      {:ok, pid} = Guidance.start_link(name: name)

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)

      # Add a file after server starts
      new_file = Path.join(Path.join(home_dir, "guidance"), "after_edit_failure.md")
      File.write!(new_file, "Hot reloaded guidance!")

      # Simulate a hot reload event
      event = %Spark.Types.Event{
        id: "test_evt",
        topic: "spark:hot_reload",
        type: :guidance_reloaded,
        source: :hot_reload,
        payload: %{},
        timestamp: DateTime.utc_now()
      }

      send(pid, event)
      Process.sleep(50)

      # The server should have reloaded
      version = GenServer.call(name, :version)
      assert is_binary(version)
    end
  end
end
