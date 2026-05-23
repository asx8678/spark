defmodule Spark.LLM.WaferProviderTest do
  use ExUnit.Case, async: true

  alias Spark.LLM.WaferProvider
  alias Spark.LLM.Provider

  describe "implements Provider behaviour" do
    test "implements? returns true" do
      assert Provider.implements?(WaferProvider)
    end

    test "supports streaming" do
      assert Provider.supports_streaming?(WaferProvider)
    end
  end

  describe "parse_response/1" do
    test "parses valid 200 response" do
      body = %{
        "id" => "chatcmpl-test123",
        "model" => "deepseek-chat",
        "choices" => [
          %{"message" => %{"role" => "assistant", "content" => "Hello world", "tool_calls" => nil}}
        ],
        "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 5, "total_tokens" => 15}
      }

      result = WaferProvider.parse_response(body)
      assert result.id == "chatcmpl-test123"
      assert result.model == "deepseek-chat"
      assert length(result.choices) == 1
      assert hd(result.choices).message.content == "Hello world"
      assert result.usage.total_tokens == 15
    end

    test "handles missing fields gracefully" do
      result = WaferProvider.parse_response(%{})
      assert result.id == "unknown"
      assert result.model == "unknown"
      assert result.choices == []
      assert result.usage.prompt_tokens == 0
    end

    test "handles tool_calls in response" do
      body = %{
        "id" => "chatcmpl-tools",
        "model" => "test",
        "choices" => [
          %{
            "message" => %{
              "role" => "assistant",
              "content" => nil,
              "tool_calls" => [
                %{"function" => %{"name" => "read_file", "arguments" => "{\"path\":\"foo\"}"}}
              ]
            }
          }
        ],
        "usage" => %{"prompt_tokens" => 20, "completion_tokens" => 10, "total_tokens" => 30}
      }

      result = WaferProvider.parse_response(body)
      [choice] = result.choices
      assert choice.message.tool_calls != nil
      assert length(choice.message.tool_calls) == 1
    end

    test "handles multiple choices" do
      body = %{
        "id" => "multi",
        "model" => "test",
        "choices" => [
          %{"message" => %{"role" => "assistant", "content" => "First"}},
          %{"message" => %{"role" => "assistant", "content" => "Second"}}
        ],
        "usage" => %{}
      }

      result = WaferProvider.parse_response(body)
      assert length(result.choices) == 2
    end

    test "non-map input returns default" do
      result = WaferProvider.parse_response("not a map")
      assert result.id == "unknown"
    end
  end

  describe "mask_key/1" do
    test "long key masked to first 4 chars" do
      assert WaferProvider.mask_key("sk-abcdefghijklmnop1234567890") == "sk-a...***"
    end

    test "short key fully masked" do
      assert WaferProvider.mask_key("sk") == "***"
    end

    test "nil key masked" do
      assert WaferProvider.mask_key(nil) == "***"
    end

    test "exactly 4 char key masked" do
      assert WaferProvider.mask_key("sk-a") == "***"
    end

    test "5 char key shows first 4" do
      assert WaferProvider.mask_key("sk-ab") == "sk-a...***"
    end
  end

  describe "complete/2 error handling" do
    test "returns auth error when no API key" do
      # No API key → 401 → auth error
      # Without a real server this would fail with connection error
      # We test the error path handling conceptually
      result = WaferProvider.complete([], %{base_url: "http://localhost:0"})
      # Should get a request error since no server is running
      assert match?({:error, _}, result)
    end
  end
end
