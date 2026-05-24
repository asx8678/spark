defmodule Spark.ConfigTest do
  use ExUnit.Case, async: false

  alias Spark.Config

  setup do
    # Use a temp directory for test isolation
    tmp_dir = Path.join(System.tmp_dir!(), "spark_test_#{:erlang.unique_integer()}")
    File.mkdir_p!(tmp_dir)

    # Override home_dir for tests
    original_home = Application.get_env(:spark, :home_dir)
    Application.put_env(:spark, :home_dir, tmp_dir)

    # Stop any existing agent
    if pid = Process.whereis(Spark.Config) do
      Agent.stop(pid)
    end

    on_exit(fn ->
      Application.put_env(:spark, :home_dir, original_home)

      if pid = Process.whereis(Spark.Config) do
        Agent.stop(pid)
      end

      File.rm_rf!(tmp_dir)
    end)

    %{tmp_dir: tmp_dir}
  end

  describe "home_dir/0" do
    test "uses Application env override" do
      assert Config.home_dir() != nil
      # Should use the tmp_dir we set in setup
      assert Config.home_dir() =~ "spark_test_"
    end
  end

  describe "ensure_home!/0" do
    test "creates expected directory structure", %{tmp_dir: tmp_dir} do
      Config.ensure_home!()

      expected_dirs = ~w(sessions memory tools prompts policy guidance logs cache)

      for dir <- expected_dirs do
        assert File.dir?(Path.join(tmp_dir, dir)), "Missing directory: #{dir}"
      end
    end

    test "creates default config.json on first boot", %{tmp_dir: tmp_dir} do
      Config.ensure_home!()

      config_path = Path.join(tmp_dir, "config.json")
      assert File.exists?(config_path)

      {:ok, raw} = File.read(config_path)
      {:ok, config} = Jason.decode(raw)
      assert config["version"] == 4.0
    end

    test "existing config preserved on second call", %{tmp_dir: tmp_dir} do
      Config.ensure_home!()

      # Modify config
      config_path = Path.join(tmp_dir, "config.json")
      original = File.read!(config_path)

      # Call ensure_home! again
      Config.ensure_home!()

      # Config should be unchanged
      assert File.read!(config_path) == original
    end

    test "idempotent - safe to call multiple times" do
      Config.ensure_home!()
      Config.ensure_home!()
      Config.ensure_home!()

      assert File.dir?(Config.home_dir())
    end
  end

  describe "default_config/0" do
    test "returns expected structure" do
      config = Config.default_config()

      assert config["version"] == 4.0
      assert config["llm"]["orchestrator_provider"] == "wafer"
      assert config["llm"]["worker_model"] == "glm-5.1"
      assert config["dispatcher"]["max_concurrency"] == 3
      assert config["tools"]["shell_timeout_ms"] == 30_000
      assert config["hot_reload"]["enabled"] == true
      assert config["memory"]["bronze_enabled"] == true
    end
  end

  describe "runtime_config/0" do
    test "returns config after ensure_home!" do
      Config.ensure_home!()
      config = Config.runtime_config()
      assert is_map(config)
      assert config["version"] == 4.0
    end
  end

  describe "get/1 and get/2" do
    setup do
      Config.ensure_home!()
      :ok
    end

    test "gets top-level config value" do
      assert Config.get("version") == 4.0
    end

    test "gets nested config value with dot notation" do
      assert Config.get("llm.orchestrator_model") == "deepseek-chat"
    end

    test "gets nested config value with list" do
      assert Config.get(["llm", "worker_model"]) == "glm-5.1"
    end

    test "returns default for missing key" do
      assert Config.get("nonexistent", "fallback") == "fallback"
    end

    test "returns nil for missing key without default" do
      assert Config.get("nonexistent") == nil
    end

    test "atom key works" do
      assert Config.get(:version) == 4.0
    end
  end

  describe "put/2" do
    setup do
      Config.ensure_home!()
      :ok
    end

    test "updates top-level value" do
      Config.put("version", 5.0)
      assert Config.get("version") == 5.0
    end

    test "updates nested value with dot notation" do
      Config.put("dispatcher.max_concurrency", 5)
      assert Config.get("dispatcher.max_concurrency") == 5
    end

    test "creates new nested path" do
      Config.put("custom.nested.key", "value")
      assert Config.get("custom.nested.key") == "value"
    end
  end

  describe "reload/0" do
    setup do
      Config.ensure_home!()
      :ok
    end

    test "reloads config from disk" do
      # Modify runtime config
      Config.put("dispatcher.max_concurrency", 10)
      assert Config.get("dispatcher.max_concurrency") == 10

      # Write a different config to disk
      new_config = Config.default_config()
      new_config = put_in(new_config, ["dispatcher", "max_concurrency"], 7)
      config_path = Config.config_path()
      File.write!(config_path, Jason.encode!(new_config, pretty: true))

      # Reload should pick up disk version
      assert {:ok, _} = Config.reload()
      assert Config.get("dispatcher.max_concurrency") == 7
    end

    test "invalid JSON fails safely without crashing" do
      config_path = Config.config_path()
      File.write!(config_path, "{invalid json!!!")

      result = Config.reload()
      assert {:error, {:invalid_json, _}} = result
      # Previous config should still be available
      assert Config.get("version") == 4.0
    end
  end
end
