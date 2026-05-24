defmodule Spark.Types.ProgressTest do
  use ExUnit.Case, async: true

  alias Spark.Types.Progress

  describe "new/1" do
    test "creates a progress report with defaults" do
      prog = Progress.new(%{task_id: "task_1", phase: :coding, detail: "Writing code"})

      assert prog.task_id == "task_1"
      assert prog.phase == :coding
      assert prog.detail == "Writing code"
      assert prog.percent == 0.0
      assert prog.timestamp != nil
    end

    test "allows overriding percent" do
      prog =
        Progress.new(%{
          task_id: "task_1",
          phase: :testing,
          detail: "Running tests",
          percent: 75.0
        })

      assert prog.percent == 75.0
    end

    test "accepts all valid phases" do
      for phase <- [:investigating, :coding, :testing, :reviewing] do
        prog = Progress.new(%{task_id: "t1", phase: phase, detail: "Working"})
        assert prog.phase == phase
      end
    end
  end
end
