defmodule Spark.PolicyTest do
  use ExUnit.Case, async: false

  alias Spark.Policy
  alias Spark.Types.{Plan, Task}
  alias Spark.EventBus

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "spark_policy_test_#{:erlang.unique_integer()}")
    File.mkdir_p!(tmp_dir)
    File.mkdir_p!(Path.join(tmp_dir, "policy"))

    original_home = Application.get_env(:spark, :home_dir)
    Application.put_env(:spark, :home_dir, tmp_dir)

    if pid = Process.whereis(Spark.Config), do: Agent.stop(pid)
    if pid = Process.whereis(Policy), do: Agent.stop(pid)
    EventBus.clear_hooks()

    on_exit(fn ->
      Application.put_env(:spark, :home_dir, original_home)
      EventBus.clear_hooks()

      try do
        if pid = Process.whereis(Spark.Config), do: Agent.stop(pid)
      catch
        :exit, _ -> :ok
      end

      try do
        if pid = Process.whereis(Policy), do: Agent.stop(pid)
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

  defp make_plan(opts \\ %{}) do
    opts = Enum.into(opts, %{})
    task = Map.get(opts, :task, make_task())
    defaults = %{id: "p1", user_goal: "goal", summary: "test plan", tasks: [task]}
    Plan.new(Map.merge(defaults, Map.delete(opts, :task)))
  end

  defp write_policy(policy) do
    path = Path.join([Application.get_env(:spark, :home_dir), "policy", "policy.json"])
    File.write!(path, Jason.encode!(policy))
  end

  defp restart_policy_agent do
    if pid = Process.whereis(Policy), do: Agent.stop(pid)
    Policy.start_link()
  end

  # ============================================
  # spark-04w.1: Policy module basics
  # ============================================

  describe "validate_plan/2 (spark-04w.1)" do
    test "valid plan with approved status passes" do
      plan =
        make_plan()
        |> Plan.awaiting_approval()
        |> then(fn p -> %{p | approval_status: :approved} end)

      assert :ok = Policy.validate_plan(plan)
    end

    test "valid plan awaiting_approval passes structural check" do
      plan = make_plan() |> Plan.awaiting_approval()
      assert :ok = Policy.validate_plan(plan)
    end

    test "plan with high-risk task requires approval" do
      task = make_task(%{risk: :high})
      plan = make_plan(task: task)
      # Draft plan with high-risk task should fail when approval is required
      assert {:error, errors} = Policy.validate_plan(plan)

      assert Enum.any?(errors, fn
               {:requires_approval, _} -> true
               _ -> false
             end)
    end

    test "approved plan with high-risk task passes" do
      task = make_task(%{risk: :high})
      plan = make_plan(task: task) |> Plan.awaiting_approval()
      {:ok, approved} = Plan.approve(plan)
      assert :ok = Policy.validate_plan(approved)
    end

    test "structurally invalid plan fails" do
      plan = %Plan{id: "", user_goal: "", summary: "", tasks: []}
      assert {:error, _} = Policy.validate_plan(plan)
    end
  end

  describe "validate_task/2 (spark-04w.1)" do
    test "valid low-risk task passes" do
      task = make_task(%{risk: :low})
      assert :ok = Policy.validate_task(task)
    end

    test "high-risk task requires approval" do
      task = make_task(%{risk: :high})
      assert {:error, errors} = Policy.validate_task(task)

      assert Enum.any?(errors, fn
               {:high_risk_requires_approval, _} -> true
               _ -> false
             end)
    end

    test "task exceeding max_write_paths fails" do
      paths = Enum.map(1..20, &"/tmp/file#{&1}")
      task = make_task(%{write_paths: paths})
      assert {:error, errors} = Policy.validate_task(task)

      assert Enum.any?(errors, fn
               {:too_many_write_paths, _} -> true
               _ -> false
             end)
    end
  end

  describe "validate_tool_call/3 (spark-04w.1)" do
    test "low-risk tool passes" do
      state = %{task_id: "t1", task: make_task()}
      assert :ok = Policy.validate_tool_call("read_file", %{}, state)
    end

    test "medium-risk tool with task_id passes" do
      state = %{task_id: "t1", task: make_task()}
      assert :ok = Policy.validate_tool_call("write_file", %{}, state)
    end

    test "high-risk tool blocked when allow_shell is false" do
      state = %{task_id: "t1", task: make_task()}

      assert {:error, {:high_risk_blocked, "shell"}} =
               Policy.validate_tool_call("shell", %{}, state)
    end

    test "critical tool always blocked by default" do
      state = %{task_id: "t1", task: make_task()}

      assert {:error, {:critical_blocked, "rm_rf"}} =
               Policy.validate_tool_call("rm_rf", %{}, state)
    end

    test "medium-risk tool without task_id fails" do
      # no task_id
      state = %{worker_id: "w1"}

      assert {:error, {:missing_task_id, _}} =
               Policy.validate_tool_call("write_file", %{}, state)
    end

    test "blocked tool is rejected" do
      write_policy(%{"blocked_tools" => ["grep"]})
      restart_policy_agent()
      state = %{task_id: "t1", task: make_task()}

      assert {:error, {:blocked_by_policy, "grep"}} =
               Policy.validate_tool_call("grep", %{}, state)
    end

    test "allowlist blocks unlisted tools" do
      write_policy(%{"allowed_tools" => ["read_file", "grep"]})
      restart_policy_agent()
      state = %{task_id: "t1", task: make_task()}
      assert :ok = Policy.validate_tool_call("read_file", %{}, state)

      assert {:error, {:not_in_allowlist, "write_file"}} =
               Policy.validate_tool_call("write_file", %{}, state)
    end
  end

  describe "requires_approval?/2 (spark-04w.1)" do
    test "high-risk task requires approval" do
      assert Policy.requires_approval?(make_task(%{risk: :high}))
    end

    test "low-risk task does not require approval" do
      refute Policy.requires_approval?(make_task(%{risk: :low}))
    end

    test "shell tool requires approval" do
      assert Policy.requires_approval?(:shell)
    end

    test "read_file does not require approval" do
      refute Policy.requires_approval?(:read_file)
    end
  end

  describe "allowed?/2 (spark-04w.1)" do
    test "read_file is allowed by default" do
      assert Policy.allowed?(:read_file)
    end

    test "shell is blocked by default" do
      refute Policy.allowed?(:shell)
    end

    test "high-risk task allowed when context has approval" do
      task = make_task(%{risk: :high})
      assert Policy.allowed?(task, %{approved: true})
    end

    test "high-risk task blocked without approval" do
      task = make_task(%{risk: :high})
      refute Policy.allowed?(task, %{approved: false})
    end

    test "low-risk task always allowed" do
      task = make_task(%{risk: :low})
      assert Policy.allowed?(task)
    end
  end

  # ============================================
  # spark-04w.2: Approval gate enforcement
  # ============================================

  describe "approval gate (spark-04w.2)" do
    test "write tool without task_id is denied" do
      # missing task_id
      state = %{worker_id: "w1"}

      assert {:error, {:missing_task_id, _}} =
               Policy.validate_tool_call("write_file", %{}, state)
    end

    test "shell tool blocked unless policy allows" do
      state = %{task_id: "t1", task: make_task()}
      # Default: allow_shell = false
      assert {:error, {:high_risk_blocked, "shell"}} =
               Policy.validate_tool_call("shell", %{}, state)

      # Enable shell
      write_policy(%{"allow_shell" => true})
      restart_policy_agent()
      assert :ok = Policy.validate_tool_call("shell", %{}, state)
    end

    test "high-risk task on plan requires approval" do
      task = make_task(%{risk: :high})
      plan = make_plan(task: task)
      assert {:error, _} = Policy.validate_plan(plan)
    end
  end

  # ============================================
  # spark-04w.3: Worker isolation
  # ============================================

  describe "worker isolation (spark-04w.3)" do
    test "workers cannot spawn sub-workers" do
      assert Spark.Worker.isolation_violation?(Spark.Worker, :start_link)
      assert Spark.Worker.isolation_violation?(Spark.WorkerSupervisor, :start_link)
    end

    test "workers cannot call Orchestrator mutators" do
      assert Spark.Worker.isolation_violation?(Spark.Orchestrator, :approve_plan)
      assert Spark.Worker.isolation_violation?(Spark.Orchestrator, :reject_plan)
      assert Spark.Worker.isolation_violation?(Spark.Orchestrator, :run)
    end

    test "workers can read Orchestrator state" do
      refute Spark.Worker.isolation_violation?(Spark.Orchestrator, :get_state)
    end

    test "workers can call safe modules" do
      refute Spark.Worker.isolation_violation?(Spark.ToolRunner, :run)
      refute Spark.Worker.isolation_violation?(Spark.EventBus, :publish)
    end
  end

  # ============================================
  # spark-04w.4: Tool risk model
  # ============================================

  describe "tool risk model (spark-04w.4)" do
    test "low risk tools" do
      assert Policy.tool_risk("read_file") == :low
      assert Policy.tool_risk("list_dir") == :low
      assert Policy.tool_risk("grep") == :low
    end

    test "medium risk tools" do
      assert Policy.tool_risk("write_file") == :medium
      assert Policy.tool_risk("edit_file") == :medium
      assert Policy.tool_risk("web_fetch") == :medium
    end

    test "high risk tools" do
      assert Policy.tool_risk("shell") == :high
      assert Policy.tool_risk("forge_tool") == :high
    end

    test "critical risk tools" do
      assert Policy.tool_risk("rm_rf") == :critical
      assert Policy.tool_risk("destructive_shell") == :critical
      assert Policy.tool_risk("secret_access") == :critical
    end

    test "unknown tool defaults to medium" do
      assert Policy.tool_risk("unknown_tool") == :medium
    end

    test "atom tool names work" do
      assert Policy.tool_risk(:read_file) == :low
      assert Policy.tool_risk(:shell) == :high
    end

    test "risk_compare ordering" do
      assert Policy.risk_compare(:low, :high) == :lt
      assert Policy.risk_compare(:high, :low) == :gt
      assert Policy.risk_compare(:medium, :medium) == :eq
    end

    test "low-risk tools always allowed" do
      assert Policy.allowed?(:read_file)
      assert Policy.allowed?(:grep)
    end

    test "critical tools blocked by default" do
      refute Policy.allowed?(:rm_rf)
      refute Policy.allowed?(:secret_access)
    end

    test "critical tools allowed when policy enables" do
      write_policy(%{"allow_critical" => true})
      restart_policy_agent()
      assert Policy.allowed?(:rm_rf)
    end
  end

  # ============================================
  # spark-04w.5: Hot-reloadable policy config
  # ============================================

  describe "hot-reload policy config (spark-04w.5)" do
    test "loads policy from disk" do
      write_policy(%{"allow_shell" => true, "blocked_tools" => ["rm_rf"]})
      restart_policy_agent()
      policy = Policy.current()
      assert policy["allow_shell"] == true
      assert "rm_rf" in policy["blocked_tools"]
    end

    test "falls back to defaults when no policy file" do
      # No policy.json written
      restart_policy_agent()
      policy = Policy.current()
      assert policy["allow_shell"] == false
    end

    test "reload picks up new config" do
      # Start with default policy (allow_shell = false)
      restart_policy_agent()
      refute Policy.allowed?(:shell)

      # Write new policy allowing shell
      write_policy(%{"allow_shell" => true})
      assert {:ok, _} = Policy.reload()
      assert Policy.allowed?(:shell)
    end

    test "reload publishes :policy_reloaded event" do
      EventBus.subscribe("spark:hot_reload")
      write_policy(%{"allow_shell" => true})
      restart_policy_agent()

      assert {:ok, _} = Policy.reload()
      assert_receive %Spark.Types.Event{type: :policy_reloaded}, 500
    end

    test "invalid policy file does not overwrite current" do
      write_policy(%{"allow_shell" => true})
      restart_policy_agent()

      # Write invalid JSON
      path = Path.join([Application.get_env(:spark, :home_dir), "policy", "policy.json"])
      File.write!(path, "{invalid json")

      assert {:error, _} = Policy.reload()
      # Old policy should still be active
      assert Policy.current()["allow_shell"] == true
    end

    test "revalidate_plan checks drafts against new policy" do
      # High-risk task in draft plan
      task = make_task(%{risk: :high})
      plan = make_plan(task: task)

      # With default policy (require_approval_for_high_risk = true), draft fails
      restart_policy_agent()
      assert {:error, _} = Policy.revalidate_plan(plan)

      # Approve the plan
      plan = plan |> Plan.awaiting_approval()
      {:ok, approved} = Plan.approve(plan)
      assert {:ok, _} = Policy.revalidate_plan(approved)
    end

    test "revalidate_plan skips non-draft plans" do
      task = make_task(%{risk: :high})
      plan = make_plan(task: task) |> Plan.awaiting_approval()
      {:ok, approved} = Plan.approve(plan)
      assert {:ok, _} = Policy.revalidate_plan(approved)
    end

    test "reload with missing file uses defaults (rollback-safe)" do
      write_policy(%{"allow_shell" => true})
      restart_policy_agent()

      # Remove the file
      path = Path.join([Application.get_env(:spark, :home_dir), "policy", "policy.json"])
      File.rm!(path)

      # Reload should succeed with defaults
      assert {:ok, new_policy} = Policy.reload()
      assert new_policy["allow_shell"] == false
    end
  end
end
