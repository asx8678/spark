defmodule Spark.LLM.ClientTest do
  use ExUnit.Case, async: false

  alias Spark.LLM.Client
  alias Spark.LLM.MockProvider
  alias Spark.EventBus
  alias Spark.Types.Event

  setup do
    # Reset config for test isolation
    tmp_dir = Path.join(System.tmp_dir!(), "spark_llm_client_test_#{:erlang.unique_integer()}")
    File.mkdir_p!(tmp_dir)

    original_home = Application.get_env(:spark, :home_dir)
    Application.put_env(:spark, :home_dir, tmp_dir)

    # Ensure config agent is available
    if pid = Process.whereis(Spark.Config) do
      Agent.stop(pid)
    end

    # Clear mock provider
    MockProvider.clear(self())
    EventBus.clear_hooks()

    on_exit(fn ->
      Application.put_env(:spark, :home_dir, original_home)
      MockProvider.clear(self())
      EventBus.clear_hooks()
      try do
        if pid = Process.whereis(Spark.Config), do: Agent.stop(pid)
      catch
        :exit, _ -> :ok
      end
    end)

    :ok
  end

  describe "complete/3 with mock provider" do
    test "returns default mock response" do
      assert {:ok, response} = Client.complete(:orchestrator, [%{role: "user", content: "Hello"}])
      assert response.id == "chatcmpl-mock"
    end

    test "returns queued mock response" do
      MockProvider.set_responses(self(), [
        {:ok, %{
          id: "custom-1",
          model: "test-model",
          choices: [%{message: %{role: "assistant", content: "Custom response"}}],
          usage: %{prompt_tokens: 5, completion_tokens: 3, total_tokens: 8}
        }}
      ])

      assert {:ok, response} = Client.complete(:orchestrator, [%{role: "user", content: "Hi"}])
      assert response.id == "custom-1"
      assert response.model == "test-model"
    end

    test "propagates mock errors" do
      MockProvider.set_responses(self(), [{:error, :rate_limited}])

      assert {:error, :rate_limited} = Client.complete(:worker, [%{role: "user", content: "Go"}])
    end

    test "works for all actor types" do
      for actor <- [:orchestrator, :worker, :prompt_refiner, :prompt_lab] do
        assert {:ok, _} = Client.complete(actor, [%{role: "user", content: "Test"}])
      end
    end

    test "rejects invalid actor type" do
      assert {:error, {:invalid_actor_type, :invalid}} =
               Client.complete(:invalid, [%{role: "user", content: "Test"}])
    end
  end

  describe "complete/3 config resolution" do
    test "resolves provider from config" do
      # Default should be mock
      assert Client.resolve_provider(:orchestrator) == Spark.LLM.MockProvider
    end

    test "resolves wafer provider" do
      Spark.Config.put([:llm, :orchestrator_provider], "wafer")
      assert Client.resolve_provider(:orchestrator) == Spark.LLM.WaferProvider
      Spark.Config.put([:llm, :orchestrator_provider], "mock")
    end

    test "falls back to mock for unknown provider" do
      Spark.Config.put([:llm, :worker_provider], "nonexistent")
      assert Client.resolve_provider(:worker) == Spark.LLM.MockProvider
      Spark.Config.put([:llm, :worker_provider], "mock")
    end
  end

  describe "complete/3 event emission" do
    test "emits llm_call_started and llm_call_completed on success" do
      EventBus.subscribe("spark:events")

      Client.complete(:orchestrator, [%{role: "user", content: "Hello"}])

      assert_receive %Event{type: :llm_call_started, payload: %{actor_type: :orchestrator}}, 500
      assert_receive %Event{type: :llm_call_completed}, 500
    after
      EventBus.unsubscribe("spark:events")
    end

    test "emits llm_call_failed on error" do
      MockProvider.set_responses(self(), [{:error, :timeout}])

      EventBus.subscribe("spark:events")

      Client.complete(:worker, [%{role: "user", content: "Go"}])

      assert_receive %Event{type: :llm_call_started}, 500
      assert_receive %Event{type: :llm_call_failed, payload: %{actor_type: :worker}}, 500
    after
      EventBus.unsubscribe("spark:events")
    end

    test "events include correct source" do
      EventBus.subscribe("spark:events")

      Client.complete(:orchestrator, [%{role: "user", content: "Hi"}])

      assert_receive %Event{type: :llm_call_started, source: :llm_client}, 500
    after
      EventBus.unsubscribe("spark:events")
    end
  end

  describe "stream/4 with mock provider" do
    test "streams chunks and done" do
      callback = fn event ->
        send(self(), {:stream, event})
      end

      assert {:ok, _} = Client.stream(:orchestrator, [%{role: "user", content: "Stream"}], %{}, callback)

      # Should receive chunk events
      assert_receive {:stream, {:chunk, %{delta: %{content: _}}}}, 1_000
    end

    test "rejects invalid actor type" do
      assert {:error, {:invalid_actor_type, :invalid}} =
               Client.stream(:invalid, [], %{}, fn _ -> :ok end)
    end
  end

  describe "actor_types/0" do
    test "returns all valid actor types" do
      types = Client.actor_types()
      assert :orchestrator in types
      assert :worker in types
      assert :prompt_refiner in types
      assert :prompt_lab in types
    end
  end
end
