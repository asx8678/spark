defmodule Spark.ToolRegistryTest.StubTool do
  @behaviour Spark.Tool
  @impl true
  def name, do: "stub_tool"
  @impl true
  def description, do: "A stub for registry tests"
  @impl true
  def schema, do: %{type: "object", properties: %{path: %{type: "string"}}}
  @impl true
  def risk, do: :low
  @impl true
  def execute(_args, _ctx), do: {:ok, %{result: "stubbed"}}
end

defmodule Spark.ToolRegistryTest.StubTool2 do
  @behaviour Spark.Tool
  @impl true
  def name, do: "stub_tool_2"
  @impl true
  def description, do: "Another stub"
  @impl true
  def schema, do: %{type: "object", properties: %{}}
  @impl true
  def risk, do: :medium
  @impl true
  def execute(_args, _ctx), do: {:ok, %{}}
end

defmodule Spark.ToolRegistryTest do
  use ExUnit.Case, async: false

  setup do
    Spark.ToolRegistry.clear()
    :ok
  end

  describe "register/2" do
    test "registers a valid tool module" do
      assert :ok = Spark.ToolRegistry.register(Spark.ToolRegistryTest.StubTool)
    end

    test "rejects duplicate names without replace" do
      Spark.ToolRegistry.register(Spark.ToolRegistryTest.StubTool)

      assert {:error, {:already_registered, "stub_tool"}} =
               Spark.ToolRegistry.register(Spark.ToolRegistryTest.StubTool)
    end

    test "allows duplicate names with replace: true" do
      Spark.ToolRegistry.register(Spark.ToolRegistryTest.StubTool)
      assert :ok = Spark.ToolRegistry.register(Spark.ToolRegistryTest.StubTool, replace: true)
    end

    test "rejects module not implementing Spark.Tool" do
      assert {:error, {:not_a_tool, String}} = Spark.ToolRegistry.register(String)
    end
  end

  describe "unregister/1" do
    test "removes a registered tool" do
      Spark.ToolRegistry.register(Spark.ToolRegistryTest.StubTool)
      assert :ok = Spark.ToolRegistry.unregister("stub_tool")
      assert {:error, {:not_found, "stub_tool"}} = Spark.ToolRegistry.lookup("stub_tool")
    end

    test "returns :ok for non-existent tool" do
      assert :ok = Spark.ToolRegistry.unregister("no_such_tool")
    end
  end

  describe "lookup/1" do
    test "finds a registered tool" do
      Spark.ToolRegistry.register(Spark.ToolRegistryTest.StubTool)
      assert {:ok, entry} = Spark.ToolRegistry.lookup("stub_tool")
      assert entry.module == Spark.ToolRegistryTest.StubTool
    end

    test "returns error for unknown tool" do
      assert {:error, {:not_found, "missing"}} = Spark.ToolRegistry.lookup("missing")
    end
  end

  describe "list/0" do
    test "returns all registered tools" do
      Spark.ToolRegistry.register(Spark.ToolRegistryTest.StubTool)
      Spark.ToolRegistry.register(Spark.ToolRegistryTest.StubTool2)
      tools = Spark.ToolRegistry.list()
      assert Map.has_key?(tools, "stub_tool")
      assert Map.has_key?(tools, "stub_tool_2")
    end
  end

  describe "schemas/0" do
    test "returns aggregated schemas" do
      Spark.ToolRegistry.register(Spark.ToolRegistryTest.StubTool)
      Spark.ToolRegistry.register(Spark.ToolRegistryTest.StubTool2)
      schemas = Spark.ToolRegistry.schemas()
      names = Enum.map(schemas, & &1.name)
      assert "stub_tool" in names
      assert "stub_tool_2" in names
    end
  end

  describe "version/1" do
    test "returns version starting at 1" do
      Spark.ToolRegistry.register(Spark.ToolRegistryTest.StubTool)
      assert {:ok, 1} = Spark.ToolRegistry.version("stub_tool")
    end

    test "increments on replace" do
      Spark.ToolRegistry.register(Spark.ToolRegistryTest.StubTool)
      Spark.ToolRegistry.register(Spark.ToolRegistryTest.StubTool, replace: true)
      assert {:ok, 2} = Spark.ToolRegistry.version("stub_tool")
    end

    test "returns error for unknown tool" do
      assert {:error, {:not_found, "nope"}} = Spark.ToolRegistry.version("nope")
    end
  end
end
