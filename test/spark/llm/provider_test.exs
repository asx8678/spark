defmodule Spark.LLM.ProviderTest do
  use ExUnit.Case, async: true

  alias Spark.LLM.Provider

  # A test module that implements the behaviour with all callbacks
  defmodule FullProvider do
    @behaviour Spark.LLM.Provider

    @impl true
    def complete(_messages, _opts) do
      {:ok,
       %{
         id: "chatcmpl-test",
         model: "test-model",
         choices: [%{message: %{role: "assistant", content: "hello"}}],
         usage: %{prompt_tokens: 10, completion_tokens: 5, total_tokens: 15}
       }}
    end

    @impl true
    def stream(messages, opts, callback) do
      callback.({:chunk, %{delta: %{content: "hel"}}})
      callback.({:chunk, %{delta: %{content: "lo"}}})
      result = complete(messages, opts)
      callback.({:done, result})
      result
    end
  end

  # A module with only required callbacks
  defmodule SyncOnlyProvider do
    @behaviour Spark.LLM.Provider

    @impl true
    def complete(_messages, _opts) do
      {:ok,
       %{
         id: "chatcmpl-sync",
         model: "sync-model",
         choices: [%{message: %{role: "assistant", content: "sync only"}}],
         usage: %{prompt_tokens: 5, completion_tokens: 3, total_tokens: 8}
       }}
    end
  end

  # A module that does NOT implement the behaviour
  defmodule NotAProvider do
    def something_else, do: :ok
  end

  describe "implements?/1" do
    test "returns true for a module implementing complete/2" do
      assert Provider.implements?(FullProvider)
    end

    test "returns true for sync-only provider" do
      assert Provider.implements?(SyncOnlyProvider)
    end

    test "returns false for a module not implementing the behaviour" do
      refute Provider.implements?(NotAProvider)
    end

    test "returns false for non-existent module" do
      refute Provider.implements?(NonExistentProviderXYZ)
    end
  end

  describe "supports_streaming?/1" do
    test "returns true for provider with stream/3" do
      assert Provider.supports_streaming?(FullProvider)
    end

    test "returns false for sync-only provider" do
      refute Provider.supports_streaming?(SyncOnlyProvider)
    end

    test "returns false for non-provider module" do
      refute Provider.supports_streaming?(NotAProvider)
    end
  end

  describe "behaviour contract - complete/2" do
    test "returns ok tuple with response map" do
      assert {:ok, response} = FullProvider.complete([], %{})
      assert Map.has_key?(response, :id)
      assert Map.has_key?(response, :model)
      assert Map.has_key?(response, :choices)
      assert Map.has_key?(response, :usage)
    end

    test "response has expected structure" do
      {:ok, response} = FullProvider.complete([], %{})
      assert is_binary(response.id)
      assert is_binary(response.model)
      assert is_list(response.choices)
      assert is_map(response.usage)
      assert Map.has_key?(response.usage, :prompt_tokens)
      assert Map.has_key?(response.usage, :completion_tokens)
      assert Map.has_key?(response.usage, :total_tokens)
    end
  end

  describe "behaviour contract - stream/3" do
    test "calls callback with chunks and done" do
      _chunks = []

      callback = fn event ->
        send(self(), {:stream_event, event})
      end

      {:ok, _response} = FullProvider.stream([], %{}, callback)

      assert_receive {:stream_event, {:chunk, %{delta: %{content: "hel"}}}}
      assert_receive {:stream_event, {:chunk, %{delta: %{content: "lo"}}}}
      assert_receive {:stream_event, {:done, {:ok, _}}}
    end
  end
end
