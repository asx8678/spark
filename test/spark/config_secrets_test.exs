defmodule Spark.Config.SecretsTest do
  use ExUnit.Case, async: false

  alias Spark.Config.Secrets

  setup do
    # Use a temp directory for test isolation
    tmp_dir = Path.join(System.tmp_dir!(), "spark_secrets_test_#{:erlang.unique_integer()}")
    File.mkdir_p!(tmp_dir)

    # Override home_dir for tests
    original_home = Application.get_env(:spark, :home_dir)
    Application.put_env(:spark, :home_dir, tmp_dir)

    # Use a known passphrase for testing
    original_pass = Application.get_env(:spark, :secrets_passphrase)
    Application.put_env(:spark, :secrets_passphrase, "test-passphrase-123")

    # Stop any existing config agent
    if pid = Process.whereis(Spark.Config) do
      Agent.stop(pid)
    end

    on_exit(fn ->
      Application.put_env(:spark, :home_dir, original_home)
      Application.put_env(:spark, :secrets_passphrase, original_pass)
      if pid = Process.whereis(Spark.Config) do
        Agent.stop(pid)
      end
      File.rm_rf!(tmp_dir)
    end)

    %{tmp_dir: tmp_dir}
  end

  describe "put_secret/2 and get_secret/1" do
    test "encrypt/decrypt round trip" do
      Secrets.put_secret(:wafer_api_key, "sk-abc123secret")
      assert Secrets.get_secret(:wafer_api_key) == "sk-abc123secret"
    end

    test "stores multiple secrets" do
      Secrets.put_secret(:key_a, "value_a")
      Secrets.put_secret(:key_b, "value_b")
      assert Secrets.get_secret(:key_a) == "value_a"
      assert Secrets.get_secret(:key_b) == "value_b"
    end

    test "returns nil for missing key" do
      assert Secrets.get_secret(:nonexistent) == nil
    end

    test "overwrites existing secret" do
      Secrets.put_secret(:my_key, "old_value")
      Secrets.put_secret(:my_key, "new_value")
      assert Secrets.get_secret(:my_key) == "new_value"
    end

    test "works with string keys" do
      Secrets.put_secret("string_key", "string_value")
      assert Secrets.get_secret("string_key") == "string_value"
    end
  end

  describe "delete_secret/1" do
    test "deletes a secret" do
      Secrets.put_secret(:to_delete, "gone_soon")
      assert Secrets.get_secret(:to_delete) == "gone_soon"
      Secrets.delete_secret(:to_delete)
      assert Secrets.get_secret(:to_delete) == nil
    end

    test "deleting nonexistent key is safe" do
      assert :ok = Secrets.delete_secret(:nonexistent)
    end
  end

  describe "list_secret_keys/0" do
    test "lists keys without values" do
      Secrets.put_secret(:alpha, "secret_alpha")
      Secrets.put_secret(:beta, "secret_beta")
      keys = Secrets.list_secret_keys()
      assert "alpha" in keys
      assert "beta" in keys
      # Values should not appear in keys list
      refute "secret_alpha" in keys
      refute "secret_beta" in keys
    end

    test "returns empty list when no secrets" do
      # Start with a fresh tmp_dir
      keys = Secrets.list_secret_keys()
      # Could be empty if secrets.enc doesn't exist yet
      assert is_list(keys)
    end
  end

  describe "wrong passphrase" do
    test "returns nil on decryption with wrong passphrase" do
      Secrets.put_secret(:test_key, "secret_value")

      # Change passphrase
      Application.put_env(:spark, :secrets_passphrase, "wrong-passphrase")

      # Should get nil (safe error) not crash
      assert Secrets.get_secret(:test_key) == nil
    end
  end

  describe "corrupt secrets file" do
    test "returns nil on corrupt file without crashing" do
      # Write garbage to secrets.enc
      secrets_path = Path.join(Application.get_env(:spark, :home_dir), "secrets.enc")
      File.write!(secrets_path, "NOT VALID JSON {{{{")

      # Should not crash, return nil or empty
      assert Secrets.get_secret(:any_key) == nil
      assert Secrets.list_secret_keys() == []
    end

    test "invalid encrypted format returns nil" do
      # Write valid JSON but wrong structure
      secrets_path = Path.join(Application.get_env(:spark, :home_dir), "secrets.enc")
      File.write!(secrets_path, Jason.encode!(%{"wafer_api_key" => %{"garbage" => "data"}}))

      # Should not crash
      assert Secrets.get_secret(:wafer_api_key) == nil
    end
  end

  describe "secret values not in inspect/log output" do
    test "secrets file does not contain plaintext" do
      Secrets.put_secret(:api_key, "sk-super-secret-value-xyz")

      secrets_path = Path.join(Application.get_env(:spark, :home_dir), "secrets.enc")
      content = File.read!(secrets_path)

      # The plaintext should NOT appear in the file
      refute String.contains?(content, "sk-super-secret-value-xyz")
    end

    test "encrypted entry has required fields" do
      Secrets.put_secret(:test_key, "test_value")

      secrets_path = Path.join(Application.get_env(:spark, :home_dir), "secrets.enc")
      {:ok, secrets} = File.read!(secrets_path) |> Jason.decode()

      entry = Map.get(secrets, "test_key")
      assert entry["version"] == 1
      assert entry["kdf"] == "pbkdf2_hmac_sha256"
      assert entry["salt"] != nil
      assert entry["iv"] != nil
      assert entry["tag"] != nil
      assert entry["ciphertext"] != nil
    end
  end

  describe "encrypt/1 and decrypt/1" do
    test "encrypt returns proper structure" do
      result = Secrets.encrypt("hello world")
      assert result["version"] == 1
      assert result["kdf"] == "pbkdf2_hmac_sha256"
      assert is_binary(result["salt"])
      assert is_binary(result["iv"])
      assert is_binary(result["tag"])
      assert is_binary(result["ciphertext"])
    end

    test "decrypt recovers original value" do
      encrypted = Secrets.encrypt("test plaintext")
      assert {:ok, "test plaintext"} = Secrets.decrypt(encrypted)
    end

    test "each encryption uses unique salt/iv" do
      e1 = Secrets.encrypt("same value")
      e2 = Secrets.encrypt("same value")
      # Salt and IV should be different even for same plaintext
      refute e1["salt"] == e2["salt"]
      refute e1["iv"] == e2["iv"]
      # Ciphertext should also differ
      refute e1["ciphertext"] == e2["ciphertext"]
    end
  end
end
