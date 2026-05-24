defmodule Spark.ToolRunnerTest.GoodTool do
  @behaviour Spark.Tool
  @impl true
  def name, do: "good_tool"
  @impl true
  def description, do: "A well-behaved tool"
  @impl true
  def schema, do: %{type: "object", required: ["path"], properties: %{path: %{type: "string"}}}
  @impl true
  def risk, do: :low
  @impl true
  def execute(%{path: path}, _ctx), do: {:ok, %{content: "data from #{path}"}}
  def execute(_args, _ctx), do: {:error, %{message: "missing path"}}
end

defmodule Spark.ToolRunnerTest.SlowTool do
  @behaviour Spark.Tool
  @impl true
  def name, do: "slow_tool"
  @impl true
  def description, do: "Takes forever"
  @impl true
  def schema, do: %{type: "object", properties: %{}}
  @impl true
  def risk, do: :low
  @impl true
  def execute(_args, _ctx) do
    Process.sleep(10_000)
    {:ok, %{}}
  end
end

defmodule Spark.ToolRunnerTest.CrashTool do
  @behaviour Spark.Tool
  @impl true
  def name, do: "crash_tool"
  @impl true
  def description, do: "Goes boom"
  @impl true
  def schema, do: %{type: "object", properties: %{}}
  @impl true
  def risk, do: :low
  @impl true
  def execute(_args, _ctx), do: raise("kaboom!")
end

defmodule Spark.ToolRunnerTest.LargeOutputTool do
  @behaviour Spark.Tool
  @impl true
  def name, do: "large_output_tool"
  @impl true
  def description, do: "Returns lots of data"
  @impl true
  def schema, do: %{type: "object", properties: %{}}
  @impl true
  def risk, do: :low
  @impl true
  def execute(_args, _ctx) do
    big = String.duplicate("x", 50_000)
    {:ok, %{content: big}}
  end
end

defmodule Spark.ToolRunnerTest do
  use ExUnit.Case, async: false

  alias Spark.ToolRegistry
  alias Spark.ToolRunner
  alias Spark.EventBus

  # Default context with task_id so policy doesn't block us
  @base_ctx %{task_id: "test_task_1"}

  setup do
    ToolRegistry.clear()
    EventBus.clear_hooks()

    on_exit(fn ->
      ToolRegistry.clear()
      EventBus.clear_hooks()
    end)

    :ok
  end

  describe "run/3 — happy path" do
    test "executes a registered tool with valid args" do
      ToolRegistry.register(Spark.ToolRunnerTest.GoodTool)
      assert {:ok, result} = ToolRunner.run("good_tool", %{path: "/tmp/test"}, @base_ctx)
      assert result.status == :ok
      assert result.tool == "good_tool"
      assert result.result.content == "data from /tmp/test"
    end

    test "accepts atom tool names" do
      ToolRegistry.register(Spark.ToolRunnerTest.GoodTool)
      assert {:ok, result} = ToolRunner.run(:good_tool, %{path: "/tmp/test"}, @base_ctx)
      assert result.status == :ok
    end
  end

  describe "run/3 — tool not found" do
    test "returns error for unknown tool" do
      assert {:error, reason} = ToolRunner.run("nonexistent", %{}, @base_ctx)
      assert reason.status == :not_found
    end
  end

  describe "run/3 — schema validation" do
    test "rejects args missing required fields" do
      ToolRegistry.register(Spark.ToolRunnerTest.GoodTool)
      assert {:error, reason} = ToolRunner.run("good_tool", %{}, @base_ctx)
      assert reason.status == :schema_error
    end
  end

  describe "run/3 — timeout" do
    test "returns timeout error when tool exceeds timeout" do
      ToolRegistry.register(Spark.ToolRunnerTest.SlowTool)

      assert {:error, reason} =
               ToolRunner.run("slow_tool", %{}, Map.put(@base_ctx, :timeout_ms, 100))

      assert reason.status == :timeout
    end
  end

  describe "run/3 — crash handling" do
    test "returns crashed error when tool raises" do
      ToolRegistry.register(Spark.ToolRunnerTest.CrashTool)
      assert {:error, reason} = ToolRunner.run("crash_tool", %{}, @base_ctx)
      assert reason.status == :crashed
    end
  end

  describe "run/3 — output truncation" do
    test "truncates large output" do
      ToolRegistry.register(Spark.ToolRunnerTest.LargeOutputTool)

      assert {:ok, result} =
               ToolRunner.run(
                 "large_output_tool",
                 %{},
                 Map.put(@base_ctx, :max_output_bytes, 500)
               )

      content = result.result.content
      # Should be truncated — much smaller than 50k chars
      assert String.contains?(content, "truncated")
    end
  end

  describe "run/3 — event publishing" do
    test "publishes tool_started and tool_completed on success" do
      ToolRegistry.register(Spark.ToolRunnerTest.GoodTool)
      EventBus.add_hook(:test_collector, fn event -> send(self(), {:event, event}) end)

      ToolRunner.run("good_tool", %{path: "/tmp/test"}, @base_ctx)

      assert_receive {:event, %{type: :tool_started}}
      assert_receive {:event, %{type: :tool_completed}}
    end

    test "publishes tool_failed on tool not found" do
      EventBus.add_hook(:test_fail_collector, fn event -> send(self(), {:event, event}) end)

      ToolRunner.run("nonexistent", %{}, @base_ctx)

      assert_receive {:event, %{type: :tool_failed}}
    end
  end

  describe "run/3 — structured results" do
    test "success result has tool, result, and status keys" do
      ToolRegistry.register(Spark.ToolRunnerTest.GoodTool)
      assert {:ok, result} = ToolRunner.run("good_tool", %{path: "/foo"}, @base_ctx)
      assert Map.has_key?(result, :tool)
      assert Map.has_key?(result, :result)
      assert Map.has_key?(result, :status)
    end

    test "error result has reason and status keys" do
      assert {:error, reason} = ToolRunner.run("nonexistent", %{}, @base_ctx)
      assert Map.has_key?(reason, :status)
    end
  end
end
