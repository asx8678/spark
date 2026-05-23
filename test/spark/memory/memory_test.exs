defmodule Spark.MemoryTest do
  use ExUnit.Case, async: false

  alias Spark.Memory

  describe "filter_secrets/1" do
    test "redacts known secret keys" do
      payload = %{
        "api_key" => "sk-secret-123",
        "model" => "gpt-4",
        "token" => "bearer-xyz",
        "data" => "safe"
      }

      filtered = Memory.filter_secrets(payload)

      assert filtered["api_key"] == "[REDACTED]"
      assert filtered["token"] == "[REDACTED]"
      assert filtered["model"] == "gpt-4"
      assert filtered["data"] == "safe"
    end

    test "redacts nested secret keys one level deep" do
      payload = %{
        "config" => %{
          "password" => "hunter2",
          "name" => "spark"
        },
        "secret" => "top"
      }

      filtered = Memory.filter_secrets(payload)

      assert filtered["secret"] == "[REDACTED]"
      assert filtered["config"]["password"] == "[REDACTED]"
      assert filtered["config"]["name"] == "spark"
    end

    test "passes through non-map values" do
      assert Memory.filter_secrets("just a string") == "just a string"
      assert Memory.filter_secrets(42) == 42
    end

    test "handles empty maps" do
      assert Memory.filter_secrets(%{}) == %{}
    end
  end

  describe "secret_keys/0" do
    test "returns the list of filtered keys" do
      keys = Memory.secret_keys()
      assert "api_key" in keys
      assert "secret" in keys
      assert "token" in keys
      assert "password" in keys
    end
  end
end
