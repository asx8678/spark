defmodule Spark.EventBusTest do
  use ExUnit.Case, async: false

  alias Spark.EventBus
  alias Spark.Types.Event

  setup do
    EventBus.clear_hooks()
    on_exit(fn -> EventBus.clear_hooks() end)
    :ok
  end

  describe "subscribe/1 and unsubscribe/1" do
    test "subscribe enables receiving events on topic" do
      EventBus.subscribe("spark:events")
      EventBus.publish_event(:test_event, %{hello: "world"}, topic: "spark:events")
      assert_receive %Event{type: :test_event, payload: %{hello: "world"}}, 500
    after
      EventBus.unsubscribe("spark:events")
    end

    test "unsubscribe stops receiving events" do
      EventBus.subscribe("spark:events")
      EventBus.unsubscribe("spark:events")
      EventBus.publish_event(:test_event, %{}, topic: "spark:events")
      refute_receive %Event{}, 100
    end

    test "subscribe to session-scoped topic" do
      EventBus.subscribe("spark:session:sess_abc123")
      EventBus.publish_session("sess_abc123", :session_started, %{user: "test"})
      assert_receive %Event{type: :session_started, session_id: "sess_abc123"}, 500
    after
      EventBus.unsubscribe("spark:session:sess_abc123")
    end
  end

  describe "publish/2" do
    test "publishes valid event to subscribers" do
      EventBus.subscribe("spark:events")
      event = Event.new(:test_published, %{data: 42}, topic: "spark:events")
      assert :ok = EventBus.publish("spark:events", event)
      assert_receive %Event{type: :test_published, payload: %{data: 42}}, 500
    after
      EventBus.unsubscribe("spark:events")
    end

    test "rejects non-Event structs" do
      assert {:error, :not_an_event} = EventBus.publish("spark:events", {:raw, :tuple})
    end

    test "rejects invalid Event" do
      bad_event = %{Event.new(:test, %{}, topic: "spark:events") | topic: nil}
      assert {:error, {:invalid_event, _}} = EventBus.publish("spark:events", bad_event)
    end

    test "subscribers on other topics don't receive" do
      # Subscribe to the global topic only
      EventBus.subscribe("spark:events")

      # Publish to a different topic
      event = Event.new(:only_reload, %{}, topic: "spark:hot_reload")
      EventBus.publish("spark:hot_reload", event)

      # The spark:events subscriber should NOT get the hot_reload event
      refute_receive %Event{type: :only_reload}, 100
    after
      EventBus.unsubscribe("spark:events")
    end
  end

  describe "publish_event/3" do
    test "builds event and publishes" do
      EventBus.subscribe("spark:events")
      assert :ok = EventBus.publish_event(:task_started, %{task_id: "t1"}, topic: "spark:events")
      assert_receive %Event{type: :task_started, payload: %{task_id: "t1"}}, 500
    after
      EventBus.unsubscribe("spark:events")
    end

    test "uses default topic when not specified" do
      EventBus.subscribe("spark:events")
      assert :ok = EventBus.publish_event(:something, %{})
      assert_receive %Event{type: :something}, 500
    after
      EventBus.unsubscribe("spark:events")
    end
  end

  describe "publish_session/4" do
    test "publishes to correct topic with metadata" do
      EventBus.subscribe("spark:session:sess_xyz")
      assert :ok = EventBus.publish_session("sess_xyz", :user_input_received, %{msg: "hi"})

      assert_receive %Event{
                       type: :user_input_received,
                       topic: "spark:session:sess_xyz",
                       session_id: "sess_xyz"
                     },
                     500
    after
      EventBus.unsubscribe("spark:session:sess_xyz")
    end
  end

  describe "publish_plan/4" do
    test "publishes to plan topic with metadata" do
      EventBus.subscribe("spark:plan:plan_123")
      assert :ok = EventBus.publish_plan("plan_123", :plan_approved, %{task_count: 5})

      assert_receive %Event{
                       type: :plan_approved,
                       topic: "spark:plan:plan_123",
                       plan_id: "plan_123"
                     },
                     500
    after
      EventBus.unsubscribe("spark:plan:plan_123")
    end
  end

  describe "publish_task/4" do
    test "publishes to task topic with metadata" do
      EventBus.subscribe("spark:task:task_456")
      assert :ok = EventBus.publish_task("task_456", :task_completed, %{duration_ms: 100})

      assert_receive %Event{
                       type: :task_completed,
                       topic: "spark:task:task_456",
                       task_id: "task_456"
                     },
                     500
    after
      EventBus.unsubscribe("spark:task:task_456")
    end
  end

  describe "publish_worker/4" do
    test "publishes to worker topic" do
      EventBus.subscribe("spark:worker:worker_789")
      assert :ok = EventBus.publish_worker("worker_789", :worker_started, %{task: "t1"})

      assert_receive %Event{
                       type: :worker_started,
                       topic: "spark:worker:worker_789"
                     },
                     500
    after
      EventBus.unsubscribe("spark:worker:worker_789")
    end
  end

  describe "publish_hot_reload/3" do
    test "publishes to hot_reload topic" do
      EventBus.subscribe("spark:hot_reload")
      assert :ok = EventBus.publish_hot_reload(:prompt_reloaded, %{prompt: :worker})

      assert_receive %Event{
                       type: :prompt_reloaded,
                       topic: "spark:hot_reload",
                       source: :hot_reload
                     },
                     500
    after
      EventBus.unsubscribe("spark:hot_reload")
    end
  end

  describe "multiple subscribers" do
    test "all subscribers on same topic receive event" do
      parent = self()
      test_ref = make_ref()

      spawn(fn ->
        EventBus.subscribe("spark:events")
        send(parent, {:ready, test_ref, :sub1})

        receive do
          %Event{type: :multi_test} -> send(parent, {:received, test_ref, :sub1})
        after
          500 -> send(parent, {:timeout, test_ref, :sub1})
        end
      end)

      spawn(fn ->
        EventBus.subscribe("spark:events")
        send(parent, {:ready, test_ref, :sub2})

        receive do
          %Event{type: :multi_test} -> send(parent, {:received, test_ref, :sub2})
        after
          500 -> send(parent, {:timeout, test_ref, :sub2})
        end
      end)

      assert_receive {:ready, ^test_ref, :sub1}, 1000
      assert_receive {:ready, ^test_ref, :sub2}, 1000

      EventBus.publish_event(:multi_test, %{}, topic: "spark:events")

      assert_receive {:received, ^test_ref, :sub1}, 1000
      assert_receive {:received, ^test_ref, :sub2}, 1000
    end
  end

  describe "hooks" do
    test "add_hook registers a named hook" do
      assert :ok = EventBus.add_hook(:test_hook, fn _event -> :ok end)
      assert :test_hook in EventBus.hooks()
    end

    test "remove_hook deregisters a hook" do
      EventBus.add_hook(:removable_hook, fn _event -> :ok end)
      assert :removable_hook in EventBus.hooks()

      assert :ok = EventBus.remove_hook(:removable_hook)
      refute :removable_hook in EventBus.hooks()
    end

    test "hooks/0 lists all registered hooks" do
      EventBus.add_hook(:hook_a, fn _ -> :ok end)
      EventBus.add_hook(:hook_b, fn _ -> :ok end)

      hooks = EventBus.hooks()
      assert :hook_a in hooks
      assert :hook_b in hooks
    end

    test "clear_hooks/0 removes all hooks" do
      EventBus.add_hook(:hook_x, fn _ -> :ok end)
      EventBus.add_hook(:hook_y, fn _ -> :ok end)

      assert EventBus.hooks() != []
      EventBus.clear_hooks()
      assert EventBus.hooks() == []
    end

    test "hooks receive events on publish" do
      test_pid = self()
      test_ref = make_ref()

      EventBus.add_hook(:spy_hook, fn event ->
        send(test_pid, {:hook_fired, test_ref, event.type, event.payload})
      end)

      EventBus.subscribe("spark:events")
      EventBus.publish_event(:task_completed, %{duration: 500}, topic: "spark:events")

      # Hook should fire
      assert_receive {:hook_fired, ^test_ref, :task_completed, %{duration: 500}}, 500
      # Subscriber should also receive
      assert_receive %Event{type: :task_completed}, 500
    after
      EventBus.unsubscribe("spark:events")
    end

    test "hooks fire before subscribers receive" do
      test_pid = self()
      test_ref = make_ref()

      EventBus.add_hook(:order_hook, fn event ->
        send(test_pid, {:hook_first, test_ref, event.type})
      end)

      EventBus.subscribe("spark:events")
      EventBus.publish_event(:order_test, %{}, topic: "spark:events")

      # Hook fires first
      assert_receive {:hook_first, ^test_ref, :order_test}, 500
    after
      EventBus.unsubscribe("spark:events")
    end

    test "invalid events don't trigger hooks" do
      test_pid = self()
      test_ref = make_ref()

      EventBus.add_hook(:no_fire_hook, fn _event ->
        send(test_pid, {:should_not_fire, test_ref})
      end)

      # Publish a non-Event
      assert {:error, :not_an_event} = EventBus.publish("spark:events", {:bad, :data})

      refute_receive {:should_not_fire, ^test_ref}, 100
    end

    test "hook errors don't crash publish" do
      EventBus.add_hook(:bad_hook, fn _event -> raise "kaboom!" end)

      EventBus.subscribe("spark:events")

      # Should still succeed despite hook crashing
      assert :ok = EventBus.publish_event(:resilient_test, %{}, topic: "spark:events")

      # Subscriber should still receive
      assert_receive %Event{type: :resilient_test}, 500
    after
      EventBus.unsubscribe("spark:events")
    end

    test "multiple hooks all fire" do
      test_pid = self()
      test_ref = make_ref()

      EventBus.add_hook(:hook_1, fn event ->
        send(test_pid, {:hook_1, test_ref, event.type})
      end)

      EventBus.add_hook(:hook_2, fn event ->
        send(test_pid, {:hook_2, test_ref, event.type})
      end)

      EventBus.publish_event(:multi_hook, %{}, topic: "spark:events")

      assert_receive {:hook_1, ^test_ref, :multi_hook}, 500
      assert_receive {:hook_2, ^test_ref, :multi_hook}, 500
    end

    test "duplicate hook name does not replace existing" do
      test_pid = self()
      test_ref = make_ref()

      EventBus.add_hook(:dedup_hook, fn event ->
        send(test_pid, {:first_hook, test_ref, event.type})
      end)

      EventBus.add_hook(:dedup_hook, fn event ->
        send(test_pid, {:second_hook, test_ref, event.type})
      end)

      EventBus.publish_event(:dedup_test, %{}, topic: "spark:events")

      # Should only fire once, and it should be the first registration
      assert_receive {:first_hook, ^test_ref, :dedup_test}, 500
      refute_receive {:second_hook, ^test_ref, :dedup_test}, 100
    end
  end
end
