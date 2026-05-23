defmodule Spark.Prompt.StoreTest do
  use ExUnit.Case, async: false

  alias Spark.Prompt.Store
  alias Spark.Config

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "spark_store_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)

    orig_home = Application.get_env(:spark, :home_dir)
    Application.put_env(:spark, :home_dir, tmp_dir)
    Config.ensure_home!()

    # Start the Store agent for this test
    case Store.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    on_exit(fn ->
      Application.delete_env(:spark, :home_dir)
      if orig_home, do: Application.put_env(:spark, :home_dir, orig_home)
      # Kill the agent between tests
      try do
        pid = Process.whereis(Store)
        if pid, do: GenServer.stop(pid)
      rescue
        _ -> :ok
      end
      File.rm_rf!(tmp_dir)
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  describe "get/1" do
    test "returns default prompt when file doesn't exist" do
      content = Store.get(:orchestrator)
      assert is_binary(content)
      assert content =~ "Orchestrator"
    end

    test "returns content from file when it exists", %{tmp_dir: tmp_dir} do
      prompt_path = Path.join(tmp_dir, "prompts/orchestrator.md")
      File.mkdir_p!(Path.dirname(prompt_path))
      File.write!(prompt_path, "Custom orchestrator prompt")

      # Reload to pick up the file
      Store.reload(:orchestrator)

      content = Store.get(:orchestrator)
      assert content == "Custom orchestrator prompt"
    end

    test "raises for unknown key" do
      assert_raise ArgumentError, ~r/Unknown prompt key/, fn ->
        Store.get(:nonexistent)
      end
    end
  end

  describe "version/1 and hash/1" do
    test "returns version string" do
      version = Store.version(:orchestrator)
      assert is_binary(version)
      assert version != ""
    end

    test "returns hash string" do
      hash = Store.hash(:orchestrator)
      assert is_binary(hash)
      # SHA-256 hex is 64 chars
      assert String.length(hash) == 64
    end
  end

  describe "reload/1" do
    test "reloads prompt from disk", %{tmp_dir: tmp_dir} do
      prompt_path = Path.join(tmp_dir, "prompts/worker.md")
      File.mkdir_p!(Path.dirname(prompt_path))
      File.write!(prompt_path, "Updated worker prompt")

      {:ok, entry} = Store.reload(:worker)
      assert entry.content == "Updated worker prompt"

      content = Store.get(:worker)
      assert content == "Updated worker prompt"
    end

    test "returns error for unknown key" do
      assert {:error, {:unknown_key, :bad_key}} = Store.reload(:bad_key)
    end
  end

  describe "reload_all/0" do
    test "reloads all prompts" do
      assert :ok = Store.reload_all()
    end
  end

  describe "write/2" do
    test "writes content to file and reloads" do
      {:ok, entry} = Store.write(:refiner, "New refiner content")
      assert entry.content == "New refiner content"

      # Verify file on disk
      {:ok, disk_content} = File.read(Store.path(:refiner))
      assert disk_content == "New refiner content"
    end
  end

  describe "keys/0" do
    test "returns all prompt keys" do
      assert :orchestrator in Store.keys()
      assert :worker in Store.keys()
      assert :refiner in Store.keys()
    end
  end

  describe "path/1" do
    test "returns correct path format" do
      assert Store.path(:orchestrator) =~ "prompts/orchestrator.md"
      assert Store.path(:worker) =~ "prompts/worker.md"
      assert Store.path(:refiner) =~ "prompts/refiner.md"
    end
  end
end
