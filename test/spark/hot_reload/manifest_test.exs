defmodule Spark.HotReload.ManifestTest do
  use ExUnit.Case, async: false

  alias Spark.HotReload.Manifest

  setup do
    # Start a fresh Manifest for each test
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

  describe "register/1" do
    test "registers a new component" do
      {:ok, entry} =
        Manifest.register(%{
          component: :prompt,
          name: :orchestrator,
          path: "~/.spark/prompts/orchestrator.md",
          hash: "sha256:abc123"
        })

      assert entry.component == :prompt
      assert entry.name == :orchestrator
      assert entry.status == :active
      assert entry.version != nil
      assert entry.loaded_at != nil
      assert entry.previous == nil
    end

    test "registers a tool component with module" do
      {:ok, entry} =
        Manifest.register(%{
          component: :tool,
          name: "grep",
          module: Spark.Tools.FS,
          path: "~/.spark/tools/grep.ex",
          version: "v1",
          hash: "sha256:def456"
        })

      assert entry.component == :tool
      assert entry.name == "grep"
      assert entry.module == Spark.Tools.FS
      assert entry.version == "v1"
    end

    test "registers config component" do
      {:ok, entry} =
        Manifest.register(%{
          component: :config,
          name: :runtime,
          path: "~/.spark/config.json"
        })

      assert entry.component == :config
      assert entry.name == :runtime
    end
  end

  describe "get/1" do
    test "gets an existing component" do
      Manifest.register(%{component: :prompt, name: :worker})

      entry = Manifest.get({:prompt, :worker})
      assert entry != nil
      assert entry.component == :prompt
      assert entry.name == :worker
    end

    test "returns nil for missing component" do
      assert Manifest.get({:prompt, :nonexistent}) == nil
    end
  end

  describe "list/0" do
    test "lists all registered components" do
      Manifest.register(%{component: :prompt, name: :orchestrator})
      Manifest.register(%{component: :prompt, name: :worker})
      Manifest.register(%{component: :config, name: :runtime})

      entries = Manifest.list()
      assert length(entries) == 3
    end

    test "returns empty list when nothing registered" do
      assert Manifest.list() == []
    end
  end

  describe "update/2" do
    test "updates an existing component and preserves previous" do
      {:ok, _original} =
        Manifest.register(%{
          component: :prompt,
          name: :worker,
          version: "v1",
          hash: "hash1"
        })

      {:ok, updated} =
        Manifest.update({:prompt, :worker}, %{
          version: "v2",
          hash: "hash2"
        })

      assert updated.version == "v2"
      assert updated.hash == "hash2"
      assert updated.previous != nil
      assert updated.previous.version == "v1"
      assert updated.previous.hash == "hash1"
    end

    test "returns error for nonexistent component" do
      assert {:error, :not_found} =
               Manifest.update({:prompt, :missing}, %{version: "v2"})
    end

    test "chain of updates preserves only one previous" do
      Manifest.register(%{component: :prompt, name: :worker, version: "v1", hash: "h1"})
      Manifest.update({:prompt, :worker}, %{version: "v2", hash: "h2"})
      {:ok, updated} = Manifest.update({:prompt, :worker}, %{version: "v3", hash: "h3"})

      assert updated.version == "v3"
      # Previous should be v2 (last version), not v1
      assert updated.previous.version == "v2"
    end
  end

  describe "previous/1" do
    test "returns previous version after update" do
      Manifest.register(%{component: :prompt, name: :worker, version: "v1", hash: "h1"})
      Manifest.update({:prompt, :worker}, %{version: "v2", hash: "h2"})

      prev = Manifest.previous({:prompt, :worker})
      assert prev != nil
      assert prev.version == "v1"
    end

    test "returns nil before any update" do
      Manifest.register(%{component: :prompt, name: :worker})

      assert Manifest.previous({:prompt, :worker}) == nil
    end

    test "returns nil for missing component" do
      assert Manifest.previous({:prompt, :missing}) == nil
    end
  end

  describe "rollback_to_previous/1" do
    test "rolls back to previous version" do
      Manifest.register(%{component: :prompt, name: :worker, version: "v1", hash: "h1"})
      Manifest.update({:prompt, :worker}, %{version: "v2", hash: "h2"})

      # Current version should be v2
      assert Manifest.get({:prompt, :worker}).version == "v2"

      # Rollback
      {:ok, rolled} = Manifest.rollback_to_previous({:prompt, :worker})
      assert rolled.version == "v1"
      assert rolled.hash == "h1"
      assert rolled.status == :active
      assert rolled.previous == nil
    end

    test "returns error when no previous version" do
      Manifest.register(%{component: :prompt, name: :worker})

      assert {:error, :no_previous} =
               Manifest.rollback_to_previous({:prompt, :worker})
    end

    test "returns error for nonexistent component" do
      assert {:error, :not_found} =
               Manifest.rollback_to_previous({:prompt, :missing})
    end
  end

  describe "exists?/1" do
    test "returns true for registered component" do
      Manifest.register(%{component: :policy, name: :main})
      assert Manifest.exists?({:policy, :main})
    end

    test "returns false for missing component" do
      refute Manifest.exists?({:policy, :missing})
    end
  end

  describe "version generation" do
    test "auto-generates version if not provided" do
      {:ok, entry} = Manifest.register(%{component: :prompt, name: :orchestrator})
      assert entry.version != nil
      assert is_binary(entry.version)
      # Version should contain ISO date prefix
      assert String.match?(entry.version, ~r/^\d{4}-\d{2}-\d{2}/)
    end
  end
end
