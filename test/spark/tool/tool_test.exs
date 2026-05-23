defmodule Spark.ToolTest.FullStub do
  @behaviour Spark.Tool
  @impl true
  def name, do: "full_stub"
  @impl true
  def description, do: "A complete stub tool"
  @impl true
  def schema, do: %{type: "object", properties: %{}}
  @impl true
  def risk, do: :low
  @impl true
  def execute(_args, _ctx), do: {:ok, %{result: "ok"}}
end

defmodule Spark.ToolTest do
  use ExUnit.Case, async: true

  describe "implements?/1" do
    test "returns true for a module implementing all callbacks" do
      assert Spark.Tool.implements?(Spark.ToolTest.FullStub)
    end

    test "returns false for a module missing callbacks" do
      # String has none of the Spark.Tool callbacks
      refute Spark.Tool.implements?(String)
    end

    test "returns false for non-existent module" do
      refute Spark.Tool.implements?(NonExistentModuleXYZ123)
    end

    test "returns false for nil" do
      refute Spark.Tool.implements?(nil)
    end
  end
end
