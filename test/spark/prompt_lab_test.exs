defmodule Spark.PromptLabTest do
  use ExUnit.Case, async: false

  alias Spark.PromptLab
  alias Spark.Config

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "spark_lab_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)

    orig_home = Application.get_env(:spark, :home_dir)
    Application.put_env(:spark, :home_dir, tmp_dir)
    Config.ensure_home!()

    on_exit(fn ->
      Application.delete_env(:spark, :home_dir)
      if orig_home, do: Application.put_env(:spark, :home_dir, orig_home)
      File.rm_rf!(tmp_dir)
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  describe "run/3" do
    test "produces a comparison report from Bronze JSONL", %{tmp_dir: tmp_dir} do
      # Create a Bronze log file
      entries = [
        %{"ts" => "2025-01-01T00:00:00Z", "type" => "user_input_received", "source" => "orchestrator", "payload" => %{}},
        %{"ts" => "2025-01-01T00:01:00Z", "type" => "tool_started", "source" => "tool_runner", "payload" => %{"tool" => "shell"}},
        %{"ts" => "2025-01-01T00:02:00Z", "type" => "tool_completed", "source" => "tool_runner", "payload" => %{"tool" => "shell"}},
        %{"ts" => "2025-01-01T00:03:00Z", "type" => "tool_failed", "source" => "tool_runner", "payload" => %{"tool" => "file"}},
        %{"ts" => "2025-01-01T00:04:00Z", "type" => "task_failed", "source" => "dispatcher", "payload" => %{}},
        %{"ts" => "2025-01-01T00:05:00Z", "type" => "task_retried", "source" => "dispatcher", "payload" => %{}}
      ]

      log_path = Path.join(tmp_dir, "test_session.jsonl")
      log_content = Enum.map(entries, &Jason.encode!/1) |> Enum.join("\n")
      File.write!(log_path, log_content)

      # Create a candidate prompt file
      prompt_path = Path.join(tmp_dir, "candidate.md")
      File.write!(prompt_path, "# Candidate Prompt\nDo things better.")

      {:ok, report} = PromptLab.run(log_path, prompt_path)

      assert report.log_file == log_path
      assert report.prompt_file == prompt_path
      assert report.tool_call_count == 3  # tool_started + tool_completed + tool_failed
      assert report.failure_count == 2   # tool_failed + task_failed
      assert report.retry_count == 1     # task_retried
      assert report.token_estimate > 0
      assert report.policy_violations == 0
    end

    test "counts policy violations with custom policy_fn", %{tmp_dir: tmp_dir} do
      log_path = Path.join(tmp_dir, "policy_test.jsonl")
      entries = [
        %{"ts" => "2025-01-01T00:00:00Z", "type" => "tool_started", "source" => "tool_runner", "payload" => %{"tool" => "shell"}}
      ]
      File.write!(log_path, Enum.map(entries, &Jason.encode!/1) |> Enum.join("\n"))

      prompt_path = Path.join(tmp_dir, "prompt.md")
      File.write!(prompt_path, "Test prompt")

      # Custom policy fn that flags every event
      policy_fn = fn _entry -> 1 end

      {:ok, report} = PromptLab.run(log_path, prompt_path, policy_fn: policy_fn)
      assert report.policy_violations == 1
    end

    test "returns error for missing log file" do
      {:error, {:log_read_error, :enoent}} =
        PromptLab.run("/nonexistent/path.jsonl", "/nonexistent/prompt.md")
    end

    test "returns error for missing prompt file" do
      log_path = Path.join(System.tmp_dir!(), "spark_lab_noprompt_#{:erlang.unique_integer([:positive])}.jsonl")
      File.write!(log_path, "{}")

      {:error, {:prompt_read_error, :enoent}} =
        PromptLab.run(log_path, "/nonexistent/prompt.md")

      File.rm(log_path)
    end

    test "handles empty log file", %{tmp_dir: tmp_dir} do
      log_path = Path.join(tmp_dir, "empty.jsonl")
      File.write!(log_path, "")

      prompt_path = Path.join(tmp_dir, "prompt.md")
      File.write!(prompt_path, "Test")

      {:ok, report} = PromptLab.run(log_path, prompt_path)
      assert report.tool_call_count == 0
      assert report.failure_count == 0
    end
  end

  describe "compare/2" do
    test "compares two reports" do
      baseline = %{
        tool_call_count: 10, failure_count: 3, retry_count: 2,
        token_estimate: 1000, policy_violations: 1
      }

      candidate = %{
        tool_call_count: 8, failure_count: 1, retry_count: 0,
        token_estimate: 800, policy_violations: 0
      }

      diff = PromptLab.compare(baseline, candidate)

      assert diff.tool_call_count == -2
      assert diff.failure_count == -2
      assert diff.retry_count == -2
      assert diff.token_estimate == -200
      assert diff.policy_violations == -1
      assert diff.improved? == true
    end

    test "marks as not improved when failures increase" do
      baseline = %{tool_call_count: 5, failure_count: 1, retry_count: 0, token_estimate: 500, policy_violations: 0}
      candidate = %{tool_call_count: 5, failure_count: 3, retry_count: 0, token_estimate: 500, policy_violations: 0}

      diff = PromptLab.compare(baseline, candidate)
      assert diff.improved? == false
    end
  end
end
