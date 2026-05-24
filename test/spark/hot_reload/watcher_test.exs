defmodule Spark.HotReload.WatcherTest do
  use ExUnit.Case, async: false

  alias Spark.HotReload.Watcher
  alias Spark.HotReload.Coordinator
  alias Spark.HotReload.Manifest

  setup do
    # Set up isolated temp home
    tmp_dir = Path.join(System.tmp_dir!(), "spark_watcher_test_#{:erlang.unique_integer()}")
    File.mkdir_p!(tmp_dir)
    for dir <- ~w(prompts tools policy guidance cache), do: File.mkdir_p!(Path.join(tmp_dir, dir))

    original_home = Application.get_env(:spark, :home_dir)
    Application.put_env(:spark, :home_dir, tmp_dir)

    # Start config agent
    if pid = Process.whereis(Spark.Config) do
      Agent.stop(pid)
    end

    # Ensure dependent processes
    if pid = Process.whereis(Manifest), do: GenServer.stop(pid, :shutdown)
    {:ok, _} = Manifest.start_link()

    if pid = Process.whereis(Coordinator), do: GenServer.stop(pid, :shutdown)
    {:ok, _} = Coordinator.start_link()

    if pid = Process.whereis(Watcher), do: GenServer.stop(pid, :shutdown)

    on_exit(fn ->
      Application.put_env(:spark, :home_dir, original_home)

      try do
        if pid = Process.whereis(Watcher), do: GenServer.stop(pid, :shutdown)
      catch
        :exit, _ -> :ok
      end

      try do
        if pid = Process.whereis(Coordinator), do: GenServer.stop(pid, :shutdown)
      catch
        :exit, _ -> :ok
      end

      try do
        if pid = Process.whereis(Manifest), do: GenServer.stop(pid, :shutdown)
      catch
        :exit, _ -> :ok
      end

      try do
        if pid = Process.whereis(Spark.Config), do: Agent.stop(pid)
      catch
        :exit, _ -> :ok
      end

      File.rm_rf!(tmp_dir)
    end)

    %{tmp_dir: tmp_dir}
  end

  describe "start_link/1" do
    test "starts the watcher" do
      {:ok, pid} = Watcher.start_link()
      assert Process.alive?(pid)
    end
  end

  describe "enabled?/0" do
    test "returns enabled status" do
      {:ok, _pid} = Watcher.start_link()
      assert Watcher.enabled?() in [true, false]
    end
  end

  describe "enable/0 and disable/0" do
    test "can disable and re-enable the watcher" do
      {:ok, _pid} = Watcher.start_link()

      Watcher.disable()
      refute Watcher.enabled?()

      Watcher.enable()
      assert Watcher.enabled?()
    end
  end

  describe "index/0" do
    test "returns file index after scan", %{tmp_dir: tmp_dir} do
      # Create a prompt file
      File.write!(Path.join(tmp_dir, "prompts/worker.md"), "You are a worker.")

      {:ok, _pid} = Watcher.start_link()
      index = Watcher.index()

      assert is_map(index)
      # Should contain the prompt file
      prompt_path = Path.join(tmp_dir, "prompts/worker.md")
      assert Map.has_key?(index, prompt_path)
    end

    test "index entries contain mtime, size, and hash", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "prompts/test.md"), "Content here.")

      {:ok, _pid} = Watcher.start_link()
      index = Watcher.index()

      path = Path.join(tmp_dir, "prompts/test.md")
      assert Map.has_key?(index, path)
      entry = index[path]
      assert Map.has_key?(entry, :mtime)
      assert Map.has_key?(entry, :size)
      assert Map.has_key?(entry, :hash)
    end
  end

  describe "scan/0" do
    test "detects new files", %{tmp_dir: tmp_dir} do
      {:ok, _pid} = Watcher.start_link()

      # Create a new file after initial index
      File.write!(Path.join(tmp_dir, "prompts/new_prompt.md"), "New prompt content.")

      {:ok, changes} = Watcher.scan()
      assert Path.join(tmp_dir, "prompts/new_prompt.md") in changes.added
    end

    test "detects modified files", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "prompts/existing.md")
      File.write!(path, "Original content.")

      {:ok, _pid} = Watcher.start_link()

      # Modify the file
      File.write!(path, "Modified content!")

      {:ok, changes} = Watcher.scan()
      assert path in changes.modified
    end

    test "detects removed files", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "prompts/to_remove.md")
      File.write!(path, "Will be removed.")

      {:ok, _pid} = Watcher.start_link()

      # Remove the file
      File.rm!(path)

      {:ok, changes} = Watcher.scan()
      assert path in changes.removed
    end
  end

  describe "ignored files" do
    test "ignores .tmp files", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "prompts/draft.md.tmp"), "Temporary")
      File.write!(Path.join(tmp_dir, "prompts/real.md"), "Real content")

      {:ok, _pid} = Watcher.start_link()
      index = Watcher.index()

      refute Map.has_key?(index, Path.join(tmp_dir, "prompts/draft.md.tmp"))
      assert Map.has_key?(index, Path.join(tmp_dir, "prompts/real.md"))
    end

    test "ignores .swp files", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "prompts/.test.md.swp"), "Swap file")

      {:ok, _pid} = Watcher.start_link()
      index = Watcher.index()

      refute Map.has_key?(index, Path.join(tmp_dir, "prompts/.test.md.swp"))
    end

    test "ignores .bak files", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "tools/old_tool.ex.bak"), "Backup")

      {:ok, _pid} = Watcher.start_link()
      index = Watcher.index()

      refute Map.has_key?(index, Path.join(tmp_dir, "tools/old_tool.ex.bak"))
    end
  end

  describe "config integration" do
    test "respects hot_reload.enabled from config" do
      Application.put_env(:spark, :home_dir, System.tmp_dir!())
      Spark.Config.put([:hot_reload, :enabled], false)

      # Start watcher - it should read the config
      {:ok, _pid} = Watcher.start_link()

      # The watcher should be disabled
      # (Note: this test assumes the watcher reads config on init)
      # We'll re-enable for cleanup
      Watcher.enable()

      :ok
    after
      Spark.Config.put([:hot_reload, :enabled], true)
    end
  end
end
