defmodule Spark.Tools.ForgeTest do
  use ExUnit.Case, async: false

  alias Spark.Tools.CreateAndLoadTool
  alias Spark.ToolRegistry

  setup do
    # Start ToolRegistry if not running
    case Process.whereis(Spark.ToolRegistry) do
      nil ->
        {:ok, _pid} = Spark.ToolRegistry.start_link([])

      _pid ->
        :ok
    end

    ToolRegistry.clear()

    # Use a temp home dir for tool storage
    tmp_home =
      Path.join(System.tmp_dir!(), "spark_forge_test_#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(tmp_home, "tools"))

    original_home = Application.get_env(:spark, :home_dir)
    Application.put_env(:spark, :home_dir, tmp_home)

    on_exit(fn ->
      if original_home do
        Application.put_env(:spark, :home_dir, original_home)
      else
        Application.delete_env(:spark, :home_dir)
      end

      ToolRegistry.clear()
      File.rm_rf!(tmp_home)
    end)

    {:ok, home_dir: tmp_home}
  end

  @valid_tool_source """
  defmodule Spark.Tools.DynamicTestTool do
    @behaviour Spark.Tool

    @impl true
    def name, do: "dynamic_test_tool"

    @impl true
    def description, do: "A dynamically created test tool"

    @impl true
    def schema do
      %{type: "object", required: [], properties: %{}}
    end

    @impl true
    def risk, do: :low

    @impl true
    def execute(_args, _context) do
      {:ok, %{result: "dynamic!"}}
    end
  end
  """

  describe "CreateAndLoadTool.execute/2" do
    test "creates and loads a new tool", %{home_dir: _home} do
      assert {:ok, result} =
               CreateAndLoadTool.execute(
                 %{name: "my_tool", source_code: @valid_tool_source, task_id: "t1"},
                 %{}
               )

      assert result.status == :created
      assert result.name == "my_tool"
      assert result.task_id == "t1"
    end

    test "writes tool file to disk", %{home_dir: home} do
      CreateAndLoadTool.execute(
        %{name: "disk_tool", source_code: @valid_tool_source, task_id: "t1"},
        %{}
      )

      path = Path.join([home, "tools", "disk_tool.ex"])
      assert File.exists?(path)
      assert File.read!(path) == @valid_tool_source
    end

    test "rejects invalid tool name (uppercase)" do
      assert {:error, reason} =
               CreateAndLoadTool.execute(
                 %{name: "BadName", source_code: @valid_tool_source, task_id: "t1"},
                 %{}
               )

      assert reason.reason == :invalid_name_format
    end

    test "rejects invalid tool name (starts with number)" do
      assert {:error, reason} =
               CreateAndLoadTool.execute(
                 %{name: "1tool", source_code: @valid_tool_source, task_id: "t1"},
                 %{}
               )

      assert reason.reason == :invalid_name_format
    end

    test "rejects empty name" do
      assert {:error, reason} =
               CreateAndLoadTool.execute(
                 %{name: "", source_code: @valid_tool_source, task_id: "t1"},
                 %{}
               )

      assert reason.reason == :empty_name
    end

    test "requires task_id" do
      assert {:error, reason} =
               CreateAndLoadTool.execute(
                 %{name: "my_tool", source_code: @valid_tool_source},
                 %{}
               )

      assert reason.reason == :missing_task_id
    end

    test "rejects empty task_id" do
      assert {:error, reason} =
               CreateAndLoadTool.execute(
                 %{name: "my_tool", source_code: @valid_tool_source, task_id: ""},
                 %{}
               )

      assert reason.reason == :missing_task_id
    end

    test "returns error when name is missing" do
      assert {:error, reason} =
               CreateAndLoadTool.execute(
                 %{source_code: @valid_tool_source, task_id: "t1"},
                 %{}
               )

      assert reason.reason == :missing_required_fields
    end

    test "reports compile errors for invalid source" do
      assert {:error, result} =
               CreateAndLoadTool.execute(
                 %{name: "broken", source_code: "this is not valid elixir!", task_id: "t1"},
                 %{}
               )

      # Should have some error detail
      assert is_map(result)
      assert result.name == "broken"
    end

    test "has correct risk level" do
      assert CreateAndLoadTool.risk() == :high
    end

    test "has correct name" do
      assert CreateAndLoadTool.name() == "create_and_load_tool"
    end
  end
end
