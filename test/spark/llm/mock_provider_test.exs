defmodule Spark.LLM.MockProviderTest do
  use ExUnit.Case, async: true

  alias Spark.LLM.MockProvider
  alias Spark.LLM.Provider

  setup do
    MockProvider.clear(self())
    on_exit(fn -> MockProvider.clear(self()) end)
    :ok
  end

  describe "implements Provider behaviour" do
    test "implements? returns true" do
      assert Provider.implements?(MockProvider)
    end

    test "supports streaming" do
      assert Provider.supports_streaming?(MockProvider)
    end
  end

  describe "complete/2 - default responses" do
    test "returns default response when no queue set" do
      assert {:ok, response} = MockProvider.complete([], %{})
      assert response.id == "chatcmpl-mock"
      assert response.model == "mock-model"
      assert length(response.choices) == 1
    end

    test "default response has correct structure" do
      {:ok, response} = MockProvider.complete([], %{})
      assert Map.has_key?(response, :id)
      assert Map.has_key?(response, :model)
      assert Map.has_key?(response, :choices)
      assert Map.has_key?(response, :usage)
    end
  end

  describe "complete/2 - queued responses" do
    test "returns queued responses in order" do
      MockProvider.set_responses(self(), [
        {:ok, %{id: "resp-1", model: "test", choices: [], usage: %{}}},
        {:ok, %{id: "resp-2", model: "test", choices: [], usage: %{}}}
      ])

      assert {:ok, %{id: "resp-1"}} = MockProvider.complete([], %{})
      assert {:ok, %{id: "resp-2"}} = MockProvider.complete([], %{})
    end

    test "returns default after queue exhausted" do
      MockProvider.set_responses(self(), [
        {:ok, %{id: "only-one", model: "test", choices: [], usage: %{}}}
      ])

      assert {:ok, %{id: "only-one"}} = MockProvider.complete([], %{})
      assert {:ok, %{id: "chatcmpl-mock"}} = MockProvider.complete([], %{})
    end

    test "simulates errors" do
      MockProvider.set_responses(self(), [
        {:error, :rate_limited},
        {:error, :timeout},
        {:error, :api_error}
      ])

      assert {:error, :rate_limited} = MockProvider.complete([], %{})
      assert {:error, :timeout} = MockProvider.complete([], %{})
      assert {:error, :api_error} = MockProvider.complete([], %{})
    end

    test "mixed success and error" do
      MockProvider.set_responses(self(), [
        {:ok, %{id: "ok-1", model: "test", choices: [], usage: %{}}},
        {:error, :rate_limited},
        {:ok, %{id: "ok-2", model: "test", choices: [], usage: %{}}}
      ])

      assert {:ok, _} = MockProvider.complete([], %{})
      assert {:error, :rate_limited} = MockProvider.complete([], %{})
      assert {:ok, _} = MockProvider.complete([], %{})
    end
  end

  describe "stream/3" do
    test "calls callback with default chunks" do
      _events = []

      callback = fn event ->
        send(self(), {:mock_stream, event})
      end

      MockProvider.stream([], %{}, callback)

      assert_receive {:mock_stream, {:chunk, %{delta: %{content: "mock "}}}}
      assert_receive {:mock_stream, {:chunk, %{delta: %{content: "response"}}}}
      assert_receive {:mock_stream, {:done, {:ok, _}}}
    end

    test "uses queued stream chunks" do
      MockProvider.set_stream_chunks(self(), [
        {:chunk, %{delta: %{content: "custom "}}},
        {:chunk, %{delta: %{content: "stream"}}}
      ])

      callback = fn event ->
        send(self(), {:mock_stream, event})
      end

      MockProvider.stream([], %{}, callback)

      assert_receive {:mock_stream, {:chunk, %{delta: %{content: "custom "}}}}
      assert_receive {:mock_stream, {:chunk, %{delta: %{content: "stream"}}}}
      assert_receive {:mock_stream, {:done, _}}
    end
  end

  describe "queue_length/1" do
    test "returns 0 when no queue set" do
      assert MockProvider.queue_length(self()) == 0
    end

    test "returns queue length" do
      MockProvider.set_responses(self(), [
        {:ok, %{id: "1", model: "test", choices: [], usage: %{}}},
        {:ok, %{id: "2", model: "test", choices: [], usage: %{}}}
      ])

      assert MockProvider.queue_length(self()) == 2
    end

    test "decreases after each complete call" do
      MockProvider.set_responses(self(), [
        {:ok, %{id: "1", model: "test", choices: [], usage: %{}}},
        {:ok, %{id: "2", model: "test", choices: [], usage: %{}}}
      ])

      MockProvider.complete([], %{})
      assert MockProvider.queue_length(self()) == 1

      MockProvider.complete([], %{})
      assert MockProvider.queue_length(self()) == 0
    end
  end

  describe "clear/1" do
    test "clears queued responses" do
      MockProvider.set_responses(self(), [
        {:ok, %{id: "cleared", model: "test", choices: [], usage: %{}}}
      ])

      assert MockProvider.queue_length(self()) == 1
      MockProvider.clear(self())
      assert MockProvider.queue_length(self()) == 0
    end
  end

  describe "concurrent test isolation" do
    test "each process gets its own queue" do
      parent = self()
      test_ref = make_ref()

      MockProvider.set_responses(self(), [
        {:ok, %{id: "parent-response", model: "test", choices: [], usage: %{}}}
      ])

      spawn(fn ->
        # Child has its own queue (empty by default)
        assert {:ok, %{id: "chatcmpl-mock"}} = MockProvider.complete([], %{})
        send(parent, {:child_done, test_ref})
      end)

      assert_receive {:child_done, ^test_ref}, 1000

      # Parent still gets its queued response
      assert {:ok, %{id: "parent-response"}} = MockProvider.complete([], %{})
    end
  end
end
