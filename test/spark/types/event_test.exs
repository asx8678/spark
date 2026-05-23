defmodule Spark.Types.EventTest do
  use ExUnit.Case, async: true

  alias Spark.Types.Event

  describe "new/3" do
    test "creates a valid event with defaults" do
      event = Event.new(:task_started)

      assert event.id != nil
      assert event.topic == "spark:events"
      assert event.type == :task_started
      assert event.source == :unknown
      assert event.session_id == ""
      assert event.payload == %{}
      assert match?(%DateTime{}, event.timestamp)
    end

    test "creates event with payload and opts" do
      event =
        Event.new(:task_completed, %{duration_ms: 500},
          source: :worker,
          session_id: "sess_123",
          task_id: "task_1"
        )

      assert event.source == :worker
      assert event.session_id == "sess_123"
      assert event.task_id == "task_1"
      assert event.payload == %{duration_ms: 500}
    end

    test "generates unique IDs" do
      e1 = Event.new(:test)
      e2 = Event.new(:test)
      refute e1.id == e2.id
    end

    test "payload defaults to empty map" do
      event = Event.new(:session_started)
      assert event.payload == %{}
    end
  end

  describe "validate/1" do
    test "valid event returns :ok" do
      event = Event.new(:task_started, %{}, source: :dispatcher)
      assert :ok = Event.validate(event)
    end

    test "missing topic rejected" do
      event = %{Event.new(:test, %{}, source: :x) | topic: ""}
      assert {:error, errors} = Event.validate(event)
      assert {:topic, "must not be empty"} in errors
    end

    test "nil topic rejected" do
      event = %{Event.new(:test, %{}, source: :x) | topic: nil}
      assert {:error, errors} = Event.validate(event)
      assert {:topic, "must not be empty"} in errors
    end

    test "missing source rejected" do
      event = %{Event.new(:test) | source: nil}
      assert {:error, errors} = Event.validate(event)
      assert {:source, "must not be nil"} in errors
    end

    test "nil type rejected" do
      event = %{Event.new(:test) | type: nil}
      assert {:error, errors} = Event.validate(event)
      assert {:type, "must not be nil"} in errors
    end

    test "empty id rejected" do
      event = %{Event.new(:test) | id: ""}
      assert {:error, errors} = Event.validate(event)
      assert {:id, "must not be empty"} in errors
    end
  end

  describe "hot_reload/3" do
    test "sets correct topic and source" do
      event = Event.hot_reload(:prompt_reloaded, %{prompt: "worker"})
      assert event.topic == "spark:hot_reload"
      assert event.source == :hot_reload
      assert event.type == :prompt_reloaded
    end

    test "allows overriding source" do
      event = Event.hot_reload(:tool_reloaded, %{}, source: :watcher)
      assert event.source == :watcher
    end
  end

  describe "task_event/4" do
    test "sets correct topic and task_id" do
      event = Event.task_event(:task_started, "task_abc")
      assert event.topic == "spark:task:task_abc"
      assert event.task_id == "task_abc"
      assert event.type == :task_started
    end

    test "passes payload" do
      event = Event.task_event(:task_completed, "t1", %{files_changed: 3})
      assert event.payload == %{files_changed: 3}
    end
  end

  describe "plan_event/4" do
    test "sets correct topic and plan_id" do
      event = Event.plan_event(:plan_approved, "plan_xyz")
      assert event.topic == "spark:plan:plan_xyz"
      assert event.plan_id == "plan_xyz"
      assert event.type == :plan_approved
    end

    test "passes payload" do
      event = Event.plan_event(:plan_created, "p1", %{task_count: 5})
      assert event.payload == %{task_count: 5}
    end
  end
end
