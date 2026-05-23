defmodule Spark.Memory.GoldTest do
  use ExUnit.Case, async: false

  alias Spark.Memory.Gold
  alias Spark.Config

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "spark_gold_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)

    orig_home = Application.get_env(:spark, :home_dir)
    Application.put_env(:spark, :home_dir, tmp_dir)
    Config.ensure_home!()

    on_exit(fn ->
      Application.delete_env(:spark, :home_dir)
      if orig_home, do: Application.put_env(:spark, :home_dir, orig_home)
      File.rm_rf!(tmp_dir)
    end)

    :ok
  end

  describe "append_gold/1" do
    test "appends a timestamped note to gold.md" do
      assert :ok = Gold.append_gold("Use Elixir for this project.")

      {:ok, content} = Gold.read_gold()
      assert content =~ "Use Elixir for this project."
      assert content =~ "---"
    end

    test "appends multiple notes" do
      Gold.append_gold("First note.")
      Gold.append_gold("Second note.")

      {:ok, content} = Gold.read_gold()
      assert content =~ "First note."
      assert content =~ "Second note."
    end

    test "each note has a timestamp" do
      Gold.append_gold("Timestamped note.")

      {:ok, content} = Gold.read_gold()
      # ISO8601 timestamp pattern
      assert content =~ ~r/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/
    end
  end

  describe "read_gold/0" do
    test "returns empty string when file doesn't exist" do
      {:ok, content} = Gold.read_gold()
      assert content == ""
    end

    test "returns full content after writes" do
      Gold.append_gold("Knowledge entry.")
      {:ok, content} = Gold.read_gold()
      assert content =~ "Knowledge entry."
    end
  end

  describe "gold_path/0" do
    test "returns path to memory/gold.md" do
      assert Gold.gold_path() =~ "memory/gold.md"
    end
  end

  describe "gold_enabled?/0" do
    test "returns true by default" do
      assert Gold.gold_enabled?() == true
    end
  end
end
