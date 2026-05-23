defmodule Spark.HotReload.RollbackTest do
  use ExUnit.Case, async: false

  alias Spark.HotReload.Rollback
  alias Spark.HotReload.Manifest

  setup do
    if pid = Process.whereis(Manifest) do
      GenServer.stop(pid, :shutdown)
    end

    {:ok, _pid} = Manifest.start_link()

    on_exit(fn ->
      try do
        if pid = Process.whereis(Manifest), do: GenServer.stop(pid, :shutdown)
      catch
        :exit, _ -> :ok
      end
    end)

    :ok
  end

  describe "rollback/2" do
    test "rolls back a prompt component" do
      Manifest.register(%{component: :prompt, name: :worker, version: "v1", hash: "h1"})
      Manifest.update({:prompt, :worker}, %{version: "v2", hash: "h2"})

      assert Manifest.get({:prompt, :worker}).version == "v2"

      assert :ok = Rollback.rollback({:prompt, :worker}, :validation_failed)
      assert Manifest.get({:prompt, :worker}).version == "v1"
    end

    test "rolls back a config component" do
      Manifest.register(%{component: :config, name: :runtime, version: "v1", hash: "h1"})
      Manifest.update({:config, :runtime}, %{version: "v2", hash: "h2"})

      assert :ok = Rollback.rollback({:config, :runtime}, :json_parse_error)
      assert Manifest.get({:config, :runtime}).version == "v1"
    end

    test "rolls back a tool component" do
      Manifest.register(%{component: :tool, name: "grep", version: "v1", hash: "h1"})
      Manifest.update({:tool, "grep"}, %{version: "v2", hash: "h2"})

      assert :ok = Rollback.rollback({:tool, "grep"}, :compile_error)
      assert Manifest.get({:tool, "grep"}).version == "v1"
    end

    test "rolls back a policy component" do
      Manifest.register(%{component: :policy, name: :main, version: "v1", hash: "h1"})
      Manifest.update({:policy, :main}, %{version: "v2", hash: "h2"})

      assert :ok = Rollback.rollback({:policy, :main}, :invalid_structure)
      assert Manifest.get({:policy, :main}).version == "v1"
    end

    test "rolls back a guidance component" do
      Manifest.register(%{component: :guidance, name: :main, version: "v1", hash: "h1"})
      Manifest.update({:guidance, :main}, %{version: "v2", hash: "h2"})

      assert :ok = Rollback.rollback({:guidance, :main}, :empty_file)
      assert Manifest.get({:guidance, :main}).version == "v1"
    end

    test "returns error when no previous version" do
      Manifest.register(%{component: :prompt, name: :orchestrator, version: "v1", hash: "h1"})

      assert {:error, :no_previous_version} =
               Rollback.rollback({:prompt, :orchestrator}, :some_error)
    end

    test "returns error for unregistered component" do
      assert {:error, :no_previous_version} =
               Rollback.rollback({:prompt, :nonexistent}, :some_error)
    end

    test "does not crash on unexpected error types" do
      Manifest.register(%{component: :prompt, name: :worker, version: "v1", hash: "h1"})
      Manifest.update({:prompt, :worker}, %{version: "v2", hash: "h2"})

      assert :ok = Rollback.rollback({:prompt, :worker}, {:complex, :error, %{foo: :bar}})
    end
  end

  describe "available?/1" do
    test "returns true when previous version exists" do
      Manifest.register(%{component: :prompt, name: :worker, version: "v1", hash: "h1"})
      Manifest.update({:prompt, :worker}, %{version: "v2", hash: "h2"})

      assert Rollback.available?({:prompt, :worker})
    end

    test "returns false when no previous version" do
      Manifest.register(%{component: :prompt, name: :orchestrator, version: "v1"})

      refute Rollback.available?({:prompt, :orchestrator})
    end

    test "returns false for unregistered component" do
      refute Rollback.available?({:prompt, :nonexistent})
    end

    test "returns false for tool with no updates" do
      Manifest.register(%{component: :tool, name: "ls", version: "v1"})

      refute Rollback.available?({:tool, "ls"})
    end
  end
end
