defmodule Spark.Orchestrator.CheckpointTest do
  use ExUnit.Case, async: false

  alias Spark.Orchestrator.Checkpoint
  alias Spark.State
  alias Spark.Types.{Plan, WorkerResult}

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "spark_checkpoint_test_#{:erlang.unique_integer()}")
    File.mkdir_p!(tmp_dir)
    original_home = Application.get_env(:spark, :home_dir)
    Application.put_env(:spark, :home_dir, tmp_dir)

    # Ensure config agent is running for Spark.Config.home_dir/0
    if Process.whereis(Spark.Config) == nil do
      case Spark.Config.start_link([]) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
      end
    end

    on_exit(fn ->
      Application.put_env(:spark, :home_dir, original_home)
      File.rm_rf!(tmp_dir)
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  describe "save/1" do
    test "persists checkpoint file to disk" do
      state = State.new(session_id: "ckpt_save_test")
      state = %{state | phase: :awaiting_approval}

      assert :ok = Checkpoint.save(state)

      path = Path.join([Spark.Config.home_dir(), "sessions", "ckpt_save_test.checkpoint"])
      assert File.exists?(path)
    end

    test "writes atomically via tmp + rename (no leftover .tmp)" do
      state = State.new(session_id: "ckpt_atomic_test")
      state = %{state | phase: :executing}

      :ok = Checkpoint.save(state)

      sessions_dir = Path.join([Spark.Config.home_dir(), "sessions"])
      tmp_files = Path.wildcard(Path.join(sessions_dir, "*.tmp"))
      assert tmp_files == [], "Atomic write should not leave .tmp files behind"
    end

    test "creates sessions directory if it doesn't exist" do
      state = State.new(session_id: "ckpt_mkdir_test")
      state = %{state | phase: :reviewing}

      sessions_dir = Path.join([Spark.Config.home_dir(), "sessions"])
      File.rm_rf!(sessions_dir)

      assert :ok = Checkpoint.save(state)
      assert File.exists?(Path.join(sessions_dir, "ckpt_mkdir_test.checkpoint"))
    end

    test "saves with active_plan and results" do
      plan =
        Plan.new(%{
          id: "plan_abc",
          user_goal: "test goal",
          summary: "A test plan",
          tasks: [
            %{id: "task_1", title: "T1", description: "desc", plan_id: "plan_abc"}
          ]
        })

      plan = Plan.awaiting_approval(plan)

      completed = %{"task_1" => %WorkerResult{task_id: "task_1", worker_id: "w1", summary: "ok"}}

      failed = %{
        "task_2" => %WorkerResult{
          task_id: "task_2",
          worker_id: "w2",
          status: :failure,
          summary: "fail",
          errors: [%{reason: "x"}]
        }
      }

      state = State.new(session_id: "ckpt_with_data")

      state = %{
        state
        | phase: :executing,
          active_plan: plan,
          completed_results: completed,
          failed_results: failed
      }

      assert :ok = Checkpoint.save(state)

      assert {:ok, cp} = Checkpoint.restore("ckpt_with_data")
      assert cp.phase == :executing
      assert cp.active_plan.id == "plan_abc"
      assert Map.has_key?(cp.completed_results, "task_1")
      assert Map.has_key?(cp.failed_results, "task_2")
    end
  end

  describe "restore/1" do
    test "returns :no_checkpoint when no file exists" do
      assert :no_checkpoint = Checkpoint.restore("nonexistent_session")
    end

    test "restores saved checkpoint fields" do
      state = State.new(session_id: "ckpt_restore_test")
      state = %{state | phase: :awaiting_approval}
      :ok = Checkpoint.save(state)

      assert {:ok, cp} = Checkpoint.restore("ckpt_restore_test")
      assert cp.phase == :awaiting_approval
      assert cp.active_plan == nil
      assert cp.completed_results == %{}
      assert cp.failed_results == %{}
      assert %DateTime{} = cp.timestamp
    end

    test "returns stale_checkpoint if older than 60 seconds" do
      # Manually write a stale checkpoint
      old_timestamp = DateTime.add(DateTime.utc_now(), -61, :second)
      data = {:awaiting_approval, nil, %{}, %{}, old_timestamp}
      binary = :erlang.term_to_binary(data)

      sessions_dir = Path.join(Spark.Config.home_dir(), "sessions")
      File.mkdir_p!(sessions_dir)
      path = Path.join(sessions_dir, "stale_test.checkpoint")
      File.write!(path, binary)

      assert {:error, :stale_checkpoint} = Checkpoint.restore("stale_test")
    end

    test "restores fresh checkpoint (within 60s)" do
      state = State.new(session_id: "fresh_test")
      state = %{state | phase: :executing}
      :ok = Checkpoint.save(state)

      assert {:ok, cp} = Checkpoint.restore("fresh_test")
      assert cp.phase == :executing
    end

    test "returns error on corrupt checkpoint file" do
      sessions_dir = Path.join(Spark.Config.home_dir(), "sessions")
      File.mkdir_p!(sessions_dir)
      path = Path.join(sessions_dir, "corrupt_test.checkpoint")
      File.write!(path, "not a valid erlang binary")

      assert {:error, {:deserialization_failed, _}} = Checkpoint.restore("corrupt_test")
    end

    test "returns error on invalid checkpoint format" do
      # Valid binary but wrong tuple structure
      binary = :erlang.term_to_binary({:wrong, :format, :here})
      sessions_dir = Path.join(Spark.Config.home_dir(), "sessions")
      File.mkdir_p!(sessions_dir)
      path = Path.join(sessions_dir, "badfmt_test.checkpoint")
      File.write!(path, binary)

      assert {:error, :invalid_checkpoint_format} = Checkpoint.restore("badfmt_test")
    end
  end

  describe "checkpoint integration with Orchestrator" do
    setup do
      # Start Dispatcher (Orchestrator depends on it)
      unless Process.whereis(Spark.Dispatcher) do
        {:ok, _} =
          Spark.Dispatcher.start_link(session_id: "ckpt_int_test", plan_id: "ckpt_int_test")
      end

      Spark.EventBus.clear_hooks()
      ensure_pubsub()

      on_exit(fn ->
        Spark.EventBus.clear_hooks()

        for name <- [Spark.Orchestrator, Spark.Dispatcher] do
          try do
            if pid = Process.whereis(name), do: GenServer.stop(pid, :shutdown)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      :ok
    end

    test "Orchestrator restores from checkpoint on init" do
      # Save a checkpoint for a session
      plan =
        Plan.new(%{
          id: "plan_restore_int",
          user_goal: "restore integration",
          summary: "Plan to restore",
          tasks: [%{id: "t1", title: "T1", description: "d", plan_id: "plan_restore_int"}]
        })

      plan = Plan.awaiting_approval(plan)

      state = State.new(session_id: "ckpt_restore_int")
      state = %{state | phase: :awaiting_approval, active_plan: plan}
      :ok = Checkpoint.save(state)

      # Stop any existing orchestrator
      if pid = Process.whereis(Spark.Orchestrator) do
        GenServer.stop(pid, :shutdown)
      end

      # Start orchestrator with same session_id — should restore
      {:ok, _pid} = Spark.Orchestrator.start_link(session_id: "ckpt_restore_int")

      restored_state = Spark.Orchestrator.get_state()
      assert restored_state.phase == :awaiting_approval
      assert restored_state.active_plan.id == "plan_restore_int"
    end

    test "Orchestrator starts fresh when no checkpoint exists" do
      if pid = Process.whereis(Spark.Orchestrator) do
        GenServer.stop(pid, :shutdown)
      end

      {:ok, _pid} = Spark.Orchestrator.start_link(session_id: "brand_new_session")

      state = Spark.Orchestrator.get_state()
      assert state.phase == :awaiting_input
      assert state.active_plan == nil
    end

    test "Orchestrator starts fresh on stale checkpoint" do
      # Write a stale checkpoint
      old_ts = DateTime.add(DateTime.utc_now(), -120, :second)
      data = {:executing, nil, %{}, %{}, old_ts}
      binary = :erlang.term_to_binary(data)
      sessions_dir = Path.join(Spark.Config.home_dir(), "sessions")
      File.mkdir_p!(sessions_dir)
      path = Path.join(sessions_dir, "stale_init_test.checkpoint")
      File.write!(path, binary)

      if pid = Process.whereis(Spark.Orchestrator) do
        GenServer.stop(pid, :shutdown)
      end

      {:ok, _pid} = Spark.Orchestrator.start_link(session_id: "stale_init_test")

      state = Spark.Orchestrator.get_state()
      assert state.phase == :awaiting_input
    end

    test "Orchestrator saves checkpoint on periodic :checkpoint message" do
      if pid = Process.whereis(Spark.Orchestrator) do
        GenServer.stop(pid, :shutdown)
      end

      {:ok, pid} = Spark.Orchestrator.start_link(session_id: "periodic_ckpt")

      # Manually send a checkpoint message
      send(pid, :checkpoint)
      Process.sleep(50)

      path = Path.join([Spark.Config.home_dir(), "sessions", "periodic_ckpt.checkpoint"])
      assert File.exists?(path)
    end
  end

  # --- Helpers ---

  defp ensure_pubsub do
    if Process.whereis(Spark.PubSub) == nil do
      {:ok, _pid} = Phoenix.PubSub.PG2.start_link(Spark.PubSub)
    end
  end
end
