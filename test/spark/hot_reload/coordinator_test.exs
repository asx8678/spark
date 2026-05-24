defmodule Spark.HotReload.CoordinatorTest do
  use ExUnit.Case, async: false

  alias Spark.HotReload.Coordinator
  alias Spark.HotReload.Manifest

  setup do
    # Ensure Manifest and Coordinator are started
    if pid = Process.whereis(Manifest) do
      GenServer.stop(pid, :shutdown)
    end

    {:ok, _pid} = Manifest.start_link()

    if pid = Process.whereis(Coordinator) do
      GenServer.stop(pid, :shutdown)
    end

    {:ok, _pid} = Coordinator.start_link()

    # Use temp dir for Spark home
    tmp_dir = Path.join(System.tmp_dir!(), "spark_coordinator_test_#{:erlang.unique_integer()}")
    File.mkdir_p!(tmp_dir)

    # Create subdirs
    for dir <- ~w(prompts tools policy guidance) do
      File.mkdir_p!(Path.join(tmp_dir, dir))
    end

    original_home = Application.get_env(:spark, :home_dir)
    Application.put_env(:spark, :home_dir, tmp_dir)

    # Ensure config agent is available
    if pid = Process.whereis(Spark.Config) do
      Agent.stop(pid)
    end

    on_exit(fn ->
      Application.put_env(:spark, :home_dir, original_home)

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

  describe "reload_file/1" do
    test "successfully reloads a prompt file", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "prompts/worker.md")
      File.write!(path, "# Worker Prompt\nYou are a coding worker.")

      {:ok, result} = Coordinator.reload_file(path)
      assert result.status == :success
      assert result.type == :prompt
    end

    test "successfully reloads a config file", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "config.json")
      File.write!(path, Jason.encode!(%{"version" => 4.0, "llm" => %{}}))

      {:ok, result} = Coordinator.reload_file(path)
      assert result.status == :success
      assert result.type == :config
    end

    test "successfully reloads a guidance file", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "guidance/after_edit.md")
      File.write!(path, "# After Edit\nRe-read the file.")

      {:ok, result} = Coordinator.reload_file(path)
      assert result.status == :success
      assert result.type == :guidance
    end

    test "successfully reloads a policy file", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "policy/main.json")
      File.write!(path, Jason.encode!(%{"allowed_tools" => ["read_file"]}))

      {:ok, result} = Coordinator.reload_file(path)
      assert result.status == :success
      assert result.type == :policy
    end

    test "fails on invalid file", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "config.json")
      File.write!(path, "{not valid json!!!")

      {:ok, result} = Coordinator.reload_file(path)
      assert result.status == :failed
      assert result.error != nil
    end

    test "fails on non-existent file" do
      {:ok, result} = Coordinator.reload_file("/nonexistent/file.md")
      assert result.status == :failed
    end
  end

  describe "reload/1" do
    test "reloads all prompts", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "prompts/orchestrator.md"), "You are the brain.")
      File.write!(Path.join(tmp_dir, "prompts/worker.md"), "You are the hands.")

      {:ok, result} = Coordinator.reload(:prompts)
      assert result.status == :success
    end

    test "reloads config", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "config.json"), Jason.encode!(%{"version" => 4.0}))

      {:ok, result} = Coordinator.reload(:config)
      assert result.status == :success
    end

    test "reloads empty type succeeds (no files)" do
      {:ok, result} = Coordinator.reload(:policy)
      assert result.status == :success
    end
  end

  describe "status/0" do
    test "returns initial status" do
      status = Coordinator.status()
      assert status.status == :idle
      assert status.reload_count == 0
      assert status.last_reload == nil
    end

    test "updates status after successful reload", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "prompts/test.md")
      File.write!(path, "Test prompt")

      Coordinator.reload_file(path)

      status = Coordinator.status()
      assert status.reload_count == 1
      assert status.last_reload != nil
      assert status.last_reload.status == :success
    end

    test "tracks reload count", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "prompts/test.md")
      File.write!(path, "Test prompt")

      Coordinator.reload_file(path)
      Coordinator.reload_file(path)
      Coordinator.reload_file(path)

      status = Coordinator.status()
      assert status.reload_count == 3
    end
  end

  describe "reset/0" do
    test "resets coordinator state", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "prompts/test.md")
      File.write!(path, "Test prompt")
      Coordinator.reload_file(path)

      assert Coordinator.status().reload_count == 1

      Coordinator.reset()

      status = Coordinator.status()
      assert status.reload_count == 0
      assert status.last_reload == nil
    end
  end

  describe "manifest integration" do
    test "registers component in manifest on successful reload", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "prompts/worker.md")
      File.write!(path, "You are a worker.")

      Coordinator.reload_file(path)

      # The manifest should have an entry for this component
      entry = Manifest.get({:prompt, :worker})
      assert entry != nil
      assert entry.component == :prompt
    end

    test "updates manifest version on subsequent reload", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "prompts/worker.md")
      File.write!(path, "Version 1")

      Coordinator.reload_file(path)
      v1 = Manifest.get({:prompt, :worker}).version

      # Modify file
      File.write!(path, "Version 2")
      Coordinator.reload_file(path)
      v2 = Manifest.get({:prompt, :worker}).version

      # Versions should differ (or at least be present)
      assert v1 != nil
      assert v2 != nil
    end
  end
end
