defmodule Spark.WorkerTest do
  use ExUnit.Case, async: false

  alias Spark.Worker
  alias Spark.Types.{Event, Task, WorkerResult}
  alias Spark.EventBus
  alias Spark.LLM.MockProvider

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "spark_worker_test_#{:erlang.unique_integer()}")

    File.mkdir_p!(tmp_dir)
    original_home = Application.get_env(:spark, :home_dir)
    Application.put_env(:spark, :home_dir, tmp_dir)

    if pid = Process.whereis(Spark.Config), do: Agent.stop(pid)
    EventBus.clear_hooks()
    MockProvider.clear(self())

    on_exit(fn ->
      Application.put_env(:spark, :home_dir, original_home)
      EventBus.clear_hooks()
      MockProvider.clear(self())

      try do
        if pid = Process.whereis(Spark.Config), do: Agent.stop(pid)
      catch
        :exit, _ -> :ok
      end

      File.rm_rf!(tmp_dir)
    end)

    :ok
  end

  # --- Helpers ---

  defp make_task(opts \\ %{}) do
    defaults = %{id: "t1", plan_id: "p1", title: "Test task", description: "Do stuff"}
    Task.new(Map.merge(defaults, opts))
  end

  defp success_response(content \\ "mock response") do
    {:ok, %{
      id: "chatcmpl-test",
      model: "mock-model",
      choices: [%{message: %{role: "assistant", content: content}}],
      usage: %{prompt_tokens: 10, completion_tokens: 5, total_tokens: 15}
    }}
  end

  defp tool_call_response do
    {:ok, %{
      id: "chatcmpl-test",
      model: "mock-model",
      choices: [
        %{
          message: %{
            role: "assistant",
            content: nil,
            tool_calls: [
              %{
                id: "tc1",
                type: "function",
                function: %{name: "read_file", arguments: "{\"path\": \"/tmp/test\"}"}
              }
            ]
          }
        }
      ],
      usage: %{prompt_tokens: 10, completion_tokens: 5, total_tokens: 15}
    }}
  end

  defp await_worker_exit(pid, timeout \\ 2000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    if Process.alive?(pid) and System.monotonic_time(:millisecond) < deadline do
      Process.sleep(10)
      await_worker_exit(pid, deadline - System.monotonic_time(:millisecond))
    end

    not Process.alive?(pid)
  end

  # --- spark-pvp.1: Worker startup/init ---

  describe "worker startup" do
    test "worker starts with valid task" do
      task = make_task()
      task_id = task.id
      EventBus.subscribe("spark:task:#{task_id}")

      # Use a slow LLM fn so the Worker is alive when we assert
      test_pid = self()

      llm_fn = fn :worker, _msgs, _opts ->
        send(test_pid, :worker_running)
        Process.sleep(100)
        success_response()
      end

      {:ok, pid} =
        Worker.start_link(task: task, session_id: "s1", plan_id: "p1", llm_call_fn: llm_fn)

      assert_receive :worker_running, 500
      assert Process.alive?(pid)
      assert_receive %Event{type: :task_started, task_id: ^task_id}, 500
    end

    test "worker rejects invalid task" do
      # Trap exits so the linked Worker crash doesn't kill the test
      Process.flag(:trap_exit, true)

      bad_task = %Task{id: "", plan_id: "", title: "bad"}

      assert {:error, {:invalid_task, _errors}} =
               Worker.start_link(task: bad_task, session_id: "s1", plan_id: "p1")

      # Flush any EXIT messages from the linked process
      receive do
        {:EXIT, _, _} -> :ok
      after
        100 -> :ok
      end
    end

    test "publishes task_started" do
      task = make_task()
      task_id = task.id
      EventBus.subscribe("spark:task:#{task_id}")

      Worker.start_link(
        task: task,
        session_id: "s1",
        plan_id: "p1",
        llm_call_fn: fn _, _, _ -> success_response() end
      )

      assert_receive %Event{
        type: :task_started,
        task_id: ^task_id,
        payload: %{worker_id: _, plan_id: "p1"}
      },
      500
    end
  end

  # --- spark-pvp.2: Worker LLM execution loop ---

  describe "worker LLM execution" do
    test "calls LLM (mock provider)" do
      test_pid = self()

      llm_fn = fn :worker, messages, opts ->
        send(test_pid, {:llm_called, messages, opts})
        success_response()
      end

      task = make_task()
      task_id = task.id
      EventBus.subscribe("spark:task:#{task_id}")

      {:ok, _pid} =
        Worker.start_link(task: task, session_id: "s1", plan_id: "p1", llm_call_fn: llm_fn)

      assert_receive {:llm_called, messages, opts}, 500
      assert is_list(messages)
      assert opts.task_id == task_id
    end

    test "publishes task_completed" do
      task = make_task()
      task_id = task.id
      EventBus.subscribe("spark:task:#{task_id}")

      {:ok, pid} =
        Worker.start_link(
          task: task,
          session_id: "s1",
          plan_id: "p1",
          llm_call_fn: fn _, _, _ -> success_response() end
        )

      assert_receive %Event{type: :task_started}, 500
      assert_receive %Event{type: :task_completed, task_id: ^task_id}, 1000

      await_worker_exit(pid)
    end

    test "publishes task_failed (simulate LLM error)" do
      task = make_task()
      task_id = task.id
      EventBus.subscribe("spark:task:#{task_id}")

      {:ok, pid} =
        Worker.start_link(
          task: task,
          session_id: "s1",
          plan_id: "p1",
          llm_call_fn: fn _, _, _ -> {:error, :rate_limited} end
        )

      assert_receive %Event{type: :task_started}, 500
      assert_receive %Event{type: :task_failed, task_id: ^task_id}, 1000

      await_worker_exit(pid)
    end

    test "handles tool calls and loops" do
      test_pid = self()
      call_count = :counters.new(1, [:atomics])

      llm_fn = fn :worker, _msgs, _opts ->
        n = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        if n == 0 do
          send(test_pid, :first_call)
          tool_call_response()
        else
          send(test_pid, :second_call)
          success_response("final answer")
        end
      end

      task = make_task()
      task_id = task.id
      EventBus.subscribe("spark:task:#{task_id}")

      {:ok, _pid} =
        Worker.start_link(task: task, session_id: "s1", plan_id: "p1", llm_call_fn: llm_fn)

      assert_receive :first_call, 500
      assert_receive :second_call, 1000
      assert_receive %Event{type: :task_completed, task_id: ^task_id}, 1000
    end

    test "stops after max iterations" do
      empty_fn = fn _, _, _ ->
        {:ok, %{
          id: "empty",
          model: "mock",
          choices: [%{message: %{role: "assistant", content: ""}}],
          usage: %{}
        }}
      end

      task = make_task()
      task_id = task.id
      EventBus.subscribe("spark:task:#{task_id}")

      {:ok, pid} =
        Worker.start_link(
          task: task,
          session_id: "s1",
          plan_id: "p1",
          llm_call_fn: empty_fn
        )

      assert_receive %Event{type: :task_failed, task_id: ^task_id}, 2000
      await_worker_exit(pid)
    end
  end

  # --- spark-pvp.3: Worker completion/failure ---

  describe "worker result structure" do
    test "success result includes WorkerResult" do
      task = make_task()
      task_id = task.id
      EventBus.subscribe("spark:task:#{task_id}")

      Worker.start_link(
        task: task,
        session_id: "s1",
        plan_id: "p1",
        llm_call_fn: fn _, _, _ -> success_response("did the thing") end
      )

      assert_receive %Event{
        type: :task_completed,
        payload: %{result: %WorkerResult{status: :success, summary: "did the thing"}}
      },
      1000
    end

    test "failure result includes WorkerResult with errors" do
      task = make_task()
      task_id = task.id
      EventBus.subscribe("spark:task:#{task_id}")

      Worker.start_link(
        task: task,
        session_id: "s1",
        plan_id: "p1",
        llm_call_fn: fn _, _, _ -> {:error, :connection_timeout} end
      )

      assert_receive %Event{
        type: :task_failed,
        payload: %{
          result: %WorkerResult{status: :failure, errors: [_ | _]},
          reason: :connection_timeout
        }
      },
      1000
    end
  end

  # --- spark-pvp.4: Worker hot reload behavior ---

  describe "worker hot reload behavior" do
    test "running worker survives prompt reload event" do
      test_pid = self()

      reload_notifier = fn event ->
        send(test_pid, {:reload_notified, event.type})
      end

      # Two-iteration flow so the Worker yields between steps,
      # allowing the hot reload event to be processed
      call_count = :counters.new(1, [:atomics])

      llm_fn = fn :worker, _msgs, _opts ->
        n = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        if n == 0 do
          send(test_pid, :first_iteration_done)
          # Tool call forces iteration 2, Worker yields to process other msgs
          tool_call_response()
        else
          success_response()
        end
      end

      task = make_task()
      task_id = task.id
      EventBus.subscribe("spark:task:#{task_id}")

      {:ok, pid} =
        Worker.start_link(
          task: task,
          session_id: "s1",
          plan_id: "p1",
          llm_call_fn: llm_fn,
          reload_notifier: reload_notifier
        )

      # Wait for first iteration to complete (Worker is idle between steps)
      assert_receive :first_iteration_done, 500
      Process.sleep(20)

      # Fire a hot reload event while the Worker is running
      EventBus.publish_hot_reload(:prompt_reloaded, %{new_version: "v2"})

      # Worker should still complete successfully — no crash
      assert_receive %Event{type: :task_completed, task_id: ^task_id}, 2000

      # If the reload notifier fired, great — worker processed it
      # If not, worker still didn't crash, which is the key assertion
      refute Process.alive?(pid)
    end

    test "captured versions don't change mid-task" do
      test_pid = self()

      # Two iterations to allow reload event between steps
      call_count = :counters.new(1, [:atomics])

      llm_fn = fn :worker, _msgs, _opts ->
        n = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        if n == 0 do
          send(test_pid, :yield_now)
          tool_call_response()
        else
          success_response()
        end
      end

      task = make_task()
      task_id = task.id
      EventBus.subscribe("spark:task:#{task_id}")

      {:ok, _pid} =
        Worker.start_link(
          task: task,
          session_id: "s1",
          plan_id: "p1",
          llm_call_fn: llm_fn
        )

      # Wait for first iteration to finish, then fire reload
      assert_receive :yield_now, 500
      Process.sleep(20)
      EventBus.publish_hot_reload(:prompt_reloaded, %{new_version: "v2"})

      # The task_completed event carries the captured prompt_version
      # from init — it must NOT be "v2"
      assert_receive %Event{
        type: :task_completed,
        payload: %{prompt_version: "unknown"}
      },
      2000
    end
  end
end
