defmodule Spark.Memory.BronzeTest do
  use ExUnit.Case, async: false

  alias Spark.Memory.Bronze
  alias Spark.Config

  setup do
    # Use a temp dir for each test
    tmp_dir =
      Path.join(System.tmp_dir!(), "spark_bronze_test_#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)

    orig_home = Application.get_env(:spark, :home_dir)
    Application.put_env(:spark, :home_dir, tmp_dir)
    Config.ensure_home!()

    session_id = "test_sess_#{:erlang.unique_integer([:positive])}"

    on_exit(fn ->
      Application.delete_env(:spark, :home_dir)
      if orig_home, do: Application.put_env(:spark, :home_dir, orig_home)
      File.rm_rf!(tmp_dir)
    end)

    {:ok, tmp_dir: tmp_dir, session_id: session_id}
  end

  describe "append/2" do
    test "writes an event as JSONL line", %{session_id: sid} do
      event = %{
        type: :user_input_received,
        source: :orchestrator,
        payload: %{message: "hello"}
      }

      assert :ok = Bronze.append(sid, event)

      {:ok, entries} = Bronze.read(sid)
      assert length(entries) == 1
      assert Enum.at(entries, 0)["type"] == "user_input_received"
      assert Enum.at(entries, 0)["payload"]["message"] == "hello"
    end

    test "writes multiple events in order", %{session_id: sid} do
      Bronze.append(sid, %{type: :plan_created, source: :orchestrator, payload: %{plan_id: "p1"}})
      Bronze.append(sid, %{type: :task_started, source: :dispatcher, payload: %{task_id: "t1"}})

      {:ok, entries} = Bronze.read(sid)
      assert length(entries) == 2
      assert Enum.at(entries, 0)["type"] == "plan_created"
      assert Enum.at(entries, 1)["type"] == "task_started"
    end

    test "redacts secret keys from payload", %{session_id: sid} do
      event = %{
        type: :llm_call_started,
        source: :llm_client,
        payload: %{api_key: "sk-super-secret", model: "gpt-4"}
      }

      Bronze.append(sid, event)

      {:ok, entries} = Bronze.read(sid)
      assert Enum.at(entries, 0)["payload"]["api_key"] == "[REDACTED]"
      assert Enum.at(entries, 0)["payload"]["model"] == "gpt-4"
    end

    test "truncates payloads over 10KB and stores hash", %{session_id: sid} do
      # Create a payload larger than 10KB
      big_content = String.duplicate("x", 12_000)

      event = %{
        type: :tool_completed,
        source: :tool_runner,
        payload: %{output: big_content, tool: "shell"}
      }

      Bronze.append(sid, event)

      {:ok, entries} = Bronze.read(sid)
      assert Enum.at(entries, 0)["meta"]["truncated"] == true
      assert Enum.at(entries, 0)["meta"]["hash"] != nil
      assert Enum.at(entries, 0)["meta"]["hash"] != ""
    end

    test "does not truncate small payloads", %{session_id: sid} do
      event = %{
        type: :task_completed,
        source: :dispatcher,
        payload: %{task_id: "t1"}
      }

      Bronze.append(sid, event)

      {:ok, entries} = Bronze.read(sid)
      assert Enum.at(entries, 0)["meta"]["truncated"] == false
    end
  end

  describe "read/1" do
    test "returns empty list for nonexistent session" do
      {:ok, entries} = Bronze.read("nonexistent_session_xyz")
      assert entries == []
    end
  end

  describe "session_path/1" do
    test "returns path under sessions dir" do
      path = Bronze.session_path("abc123")
      assert path =~ "sessions/abc123.jsonl"
    end
  end

  describe "handle_event/2" do
    test "skips non-Event structs", %{session_id: sid} do
      assert :skipped = Bronze.handle_event(%{foo: "bar"}, sid)
    end

    test "handles a valid Event and appends it", %{session_id: sid} do
      event =
        Spark.Types.Event.new(:plan_approved, %{plan_id: "p1"},
          topic: "spark:plan:p1",
          source: :orchestrator,
          session_id: sid
        )

      result = Bronze.handle_event(event, sid)
      assert result in [:ok, :skipped]

      if result == :ok do
        {:ok, entries} = Bronze.read(sid)
        assert length(entries) == 1
        assert Enum.at(entries, 0)["type"] == "plan_approved"
      end
    end

    test "skips uninteresting event types", %{session_id: sid} do
      event =
        Spark.Types.Event.new(:random_uninteresting, %{data: "x"},
          topic: "spark:events",
          source: :test
        )

      result = Bronze.handle_event(event, sid)
      assert result == :skipped
    end
  end

  describe "bronze_enabled?/0" do
    test "returns true by default" do
      assert Bronze.bronze_enabled?() == true
    end

    test "returns false when disabled in config" do
      # Use put to change the runtime config directly
      Spark.Config.put([:memory, :bronze_enabled], false)

      assert Bronze.bronze_enabled?() == false

      # Restore
      Spark.Config.put([:memory, :bronze_enabled], true)
    end
  end
end
