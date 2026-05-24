defmodule Spark.EventsTest do
  use ExUnit.Case, async: true

  alias Spark.Events
  alias Spark.EventBus
  alias Spark.Types.Event

  setup do
    EventBus.clear_hooks()
    on_exit(fn -> EventBus.clear_hooks() end)
    :ok
  end

  describe "event macros" do
    test "session events expand to correct atoms" do
      import Spark.Events
      assert session_started() == :session_started
      assert user_input_received() == :user_input_received
    end

    test "plan events expand to correct atoms" do
      import Spark.Events
      assert plan_created() == :plan_created
      assert plan_awaiting_approval() == :plan_awaiting_approval
      assert plan_approved() == :plan_approved
      assert plan_rejected() == :plan_rejected
    end

    test "task events expand to correct atoms" do
      import Spark.Events
      assert task_queued() == :task_queued
      assert task_started() == :task_started
      assert task_completed() == :task_completed
      assert task_failed() == :task_failed
      assert task_retried() == :task_retried
    end

    test "worker events expand to correct atoms" do
      import Spark.Events
      assert worker_started() == :worker_started
      assert worker_stopped() == :worker_stopped
      assert worker_iteration_started() == :worker_iteration_started
      assert worker_llm_started() == :worker_llm_started
      assert worker_llm_completed() == :worker_llm_completed
      assert worker_llm_failed() == :worker_llm_failed
      assert worker_llm_timeout() == :worker_llm_timeout
    end

    test "tool events expand to correct atoms" do
      import Spark.Events
      assert tool_started() == :tool_started
      assert tool_completed() == :tool_completed
      assert tool_failed() == :tool_failed
    end

    test "orchestrator events expand to correct atoms" do
      import Spark.Events
      assert orchestrator_review_started() == :orchestrator_review_started
      assert orchestrator_review_completed() == :orchestrator_review_completed
    end

    test "memory events expand to correct atoms" do
      import Spark.Events
      assert memory_written() == :memory_written
    end

    test "hot reload events expand to correct atoms" do
      import Spark.Events
      assert hot_reload_started() == :hot_reload_started
      assert hot_reload_completed() == :hot_reload_completed
      assert hot_reload_failed() == :hot_reload_failed
      assert config_reloaded() == :config_reloaded
      assert prompt_reloaded() == :prompt_reloaded
      assert tool_reloaded() == :tool_reloaded
    end
  end

  describe "all/0" do
    test "returns all event types" do
      all = Events.all()
      assert :session_started in all
      assert :plan_approved in all
      assert :task_completed in all
      assert :worker_started in all
      assert :tool_started in all
      assert :hot_reload_started in all
      assert :memory_written in all
      assert :policy_reloaded in all
      assert :code_reloaded in all
      assert length(all) == 32
    end
  end

  describe "known?/1" do
    test "known events return true" do
      assert Events.known?(:session_started)
      assert Events.known?(:plan_approved)
      assert Events.known?(:task_completed)
    end

    test "unknown events return false" do
      refute Events.known?(:unknown_event)
      refute Events.known?(:made_up_thing)
    end
  end

  describe "publishing with event constants" do
    test "event constant can be used in publish and arrives at subscriber" do
      import Spark.Events
      EventBus.subscribe("spark:events")

      EventBus.publish_event(session_started(), %{user: "adam"}, topic: "spark:events")

      assert_receive %Event{type: :session_started, payload: %{user: "adam"}}, 500
    after
      EventBus.unsubscribe("spark:events")
    end

    test "plan event constant works end to end" do
      import Spark.Events
      EventBus.subscribe("spark:plan:plan_test")

      EventBus.publish_plan("plan_test", plan_approved(), %{task_count: 3})

      assert_receive %Event{type: :plan_approved, plan_id: "plan_test"}, 500
    after
      EventBus.unsubscribe("spark:plan:plan_test")
    end

    test "task event constant works end to end" do
      import Spark.Events
      EventBus.subscribe("spark:task:task_test")

      EventBus.publish_task("task_test", task_completed(), %{duration_ms: 200})

      assert_receive %Event{type: :task_completed, task_id: "task_test"}, 500
    after
      EventBus.unsubscribe("spark:task:task_test")
    end

    test "hot reload event constant works end to end" do
      import Spark.Events
      EventBus.subscribe("spark:hot_reload")

      EventBus.publish_hot_reload(hot_reload_completed(), %{component: :prompt})

      assert_receive %Event{type: :hot_reload_completed, source: :hot_reload}, 500
    after
      EventBus.unsubscribe("spark:hot_reload")
    end
  end

  describe "EventBus.normalize/1" do
    test "passes through Event structs" do
      event = Event.new(:test, %{}, topic: "spark:events")
      assert {:ok, ^event} = EventBus.normalize(event)
    end

    test "normalizes map with type and payload" do
      assert {:ok, event} =
               EventBus.normalize(%{
                 type: :task_started,
                 payload: %{task_id: "t1"},
                 topic: "spark:task:t1",
                 source: :dispatcher
               })

      assert %Event{} = event
      assert event.type == :task_started
      assert event.payload == %{task_id: "t1"}
      assert event.topic == "spark:task:t1"
      assert event.source == :dispatcher
    end

    test "normalizes 2-tuple" do
      assert {:ok, event} = EventBus.normalize({:task_completed, %{duration: 500}})
      assert %Event{} = event
      assert event.type == :task_completed
      assert event.payload == %{duration: 500}
    end

    test "normalizes 3-tuple with opts" do
      assert {:ok, event} =
               EventBus.normalize(
                 {:task_failed, %{error: "bad"}, [source: :worker, topic: "spark:events"]}
               )

      assert %Event{} = event
      assert event.type == :task_failed
      assert event.source == :worker
    end

    test "rejects unknown shapes" do
      assert {:error, :cannot_normalize} = EventBus.normalize("just a string")
      assert {:error, :cannot_normalize} = EventBus.normalize(42)
      assert {:error, :cannot_normalize} = EventBus.normalize({:too, :many, :parts, :here})
    end

    test "rejects map without type" do
      assert {:error, :cannot_normalize} = EventBus.normalize(%{payload: %{}})
    end

    test "rejects map without payload" do
      assert {:error, :cannot_normalize} = EventBus.normalize(%{type: :test})
    end
  end

  describe "EventBus.broadcast/2" do
    test "broadcasts a raw map after normalization" do
      EventBus.subscribe("spark:events")

      assert :ok =
               EventBus.broadcast("spark:events", %{
                 type: :session_started,
                 payload: %{session_id: "s1"},
                 topic: "spark:events"
               })

      assert_receive %Event{type: :session_started}, 500
    after
      EventBus.unsubscribe("spark:events")
    end

    test "broadcasts a 2-tuple after normalization" do
      EventBus.subscribe("spark:events")

      assert :ok = EventBus.broadcast("spark:events", {:worker_started, %{worker: "w1"}})

      assert_receive %Event{type: :worker_started}, 500
    after
      EventBus.unsubscribe("spark:events")
    end

    test "rejects un-normalizable input" do
      assert {:error, {:normalization_failed, :cannot_normalize}} =
               EventBus.broadcast("spark:events", "bad input")
    end

    test "rejects normalized event that fails validation" do
      # A map that normalizes but results in an invalid event
      # (e.g., missing required topic after normalization)
      # The default topic "spark:events" should be valid, so let's
      # test with a known-bad event struct directly
      bad_event = %{Event.new(:test, %{}) | id: ""}
      assert {:error, {:invalid_event, _}} = EventBus.broadcast("spark:events", bad_event)
    end
  end
end
