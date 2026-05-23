defmodule Spark.Memory.SilverTest do
  use ExUnit.Case, async: false

  alias Spark.Memory.Silver
  alias Spark.Config

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "spark_silver_test_#{:erlang.unique_integer([:positive])}")
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

  describe "compact/2" do
    test "compacts history with mock LLM" do
      history = [
        %{"type" => "user_input_received", "payload" => %{"message" => "fix the bug"}},
        %{"type" => "task_completed", "payload" => %{"task_id" => "t1"}},
        %{"type" => "task_failed", "payload" => %{"task_id" => "t2", "error" => "timeout"}}
      ]

      {:ok, result} = Silver.compact("sess_test", history, mock_llm: true)

      assert result.session_id == "sess_test"
      assert is_binary(result.summary)
      assert result.summary != ""
      assert is_list(result.unresolved)
      assert is_list(result.decisions)
      assert is_list(result.constraints)
      assert is_list(result.tool_outcomes)
      assert result.entry_count == 3
      assert result.estimated_tokens > 0
    end

    test "compacts with custom llm_fn" do
      custom_fn = fn _actor, _messages, _opts ->
        {:ok, %{
          choices: [%{message: %{role: "assistant", content: Jason.encode!(%{
            summary: "Custom summary",
            unresolved: ["Custom issue"],
            decisions: ["Custom decision"],
            constraints: ["Custom constraint"],
            tool_outcomes: [%{tool: "custom", status: "ok"}]
          })}}]
        }}
      end

      {:ok, result} = Silver.compact("sess_custom", [%{"type" => "test"}], llm_fn: custom_fn)

      assert result.summary == "Custom summary"
      assert result.unresolved == ["Custom issue"]
      assert result.decisions == ["Custom decision"]
    end

    test "handles LLM error gracefully" do
      error_fn = fn _actor, _messages, _opts ->
        {:error, :timeout}
      end

      {:error, {:compaction_llm_error, :timeout}} =
        Silver.compact("sess_err", [%{"type" => "test"}], llm_fn: error_fn)
    end

    test "handles empty history" do
      {:ok, result} = Silver.compact("sess_empty", [], mock_llm: true)
      assert result.entry_count == 0
    end

    test "parses JSON from markdown fences" do
      fence_fn = fn _actor, _messages, _opts ->
        content = "```json\n#{Jason.encode!(%{
          summary: "Fenced summary",
          unresolved: [],
          decisions: [],
          constraints: [],
          tool_outcomes: []
        })}\n```"

        {:ok, %{choices: [%{message: %{role: "assistant", content: content}}]}}
      end

      {:ok, result} = Silver.compact("sess_fence", [%{"type" => "test"}], llm_fn: fence_fn)
      assert result.summary == "Fenced summary"
    end
  end

  describe "should_compact?/1" do
    test "returns false for small history" do
      # A few small entries won't exceed the threshold
      history = [%{"type" => "test", "payload" => %{"msg" => "hi"}}]
      refute Silver.should_compact?(history)
    end

    test "returns true for large history" do
      # Create lots of entries to exceed threshold
      history = for i <- 1..5000 do
        %{"type" => "test", "payload" => %{"msg" => "entry #{i} with some content"}}
      end

      assert Silver.should_compact?(history, threshold: 100)
    end

    test "respects custom threshold" do
      history = [%{"type" => "test"}]
      assert Silver.should_compact?(history, threshold: 0)
    end
  end

  describe "silver_enabled?/0" do
    test "returns true by default" do
      assert Silver.silver_enabled?() == true
    end
  end
end
