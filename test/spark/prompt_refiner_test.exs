defmodule Spark.PromptRefinerTest do
  use ExUnit.Case, async: false

  alias Spark.PromptRefiner
  alias Spark.Prompt.Store
  alias Spark.Memory.Bronze
  alias Spark.Config

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "spark_refiner_test_#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)

    orig_home = Application.get_env(:spark, :home_dir)
    Application.put_env(:spark, :home_dir, tmp_dir)
    Config.ensure_home!()

    # Start the Store agent
    case Store.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    session_id = "refine_sess_#{:erlang.unique_integer([:positive])}"

    on_exit(fn ->
      Application.delete_env(:spark, :home_dir)
      if orig_home, do: Application.put_env(:spark, :home_dir, orig_home)

      try do
        pid = Process.whereis(Store)
        if pid, do: GenServer.stop(pid)
      rescue
        _ -> :ok
      end

      File.rm_rf!(tmp_dir)
    end)

    {:ok, tmp_dir: tmp_dir, session_id: session_id}
  end

  describe "refine/3" do
    test "produces a refinement with mock LLM", %{session_id: sid} do
      # Write some Bronze entries with failures
      Bronze.append(sid, %{type: :task_failed, source: :dispatcher, payload: %{task_id: "t1"}})
      Bronze.append(sid, %{type: :tool_failed, source: :tool_runner, payload: %{tool: "shell"}})
      Bronze.append(sid, %{type: :task_completed, source: :dispatcher, payload: %{task_id: "t2"}})

      {:ok, refinement} = PromptRefiner.refine(sid, :orchestrator, mock_llm: true)

      assert refinement.session_id == sid
      assert refinement.prompt_key == :orchestrator
      assert is_binary(refinement.analysis)
      assert is_list(refinement.suggestions)
      assert length(refinement.suggestions) > 0
      assert is_binary(refinement.candidate_prompt)
      assert refinement.candidate_prompt != ""
      assert is_binary(refinement.diff)
      assert refinement.approved == false
      assert refinement.recommendation in [:approve, :reject, :needs_review]
    end

    test "refinement includes current version info", %{session_id: sid} do
      Bronze.append(sid, %{type: :task_failed, source: :dispatcher, payload: %{}})

      {:ok, refinement} = PromptRefiner.refine(sid, :worker, mock_llm: true)

      assert is_binary(refinement.current_version)
      assert refinement.current_version != ""
      assert is_binary(refinement.candidate_version)
    end

    test "diff contains + and - markers", %{session_id: sid} do
      Bronze.append(sid, %{type: :tool_failed, source: :tool_runner, payload: %{}})

      {:ok, refinement} = PromptRefiner.refine(sid, :refiner, mock_llm: true)

      # Diff should show additions since we only add suggestions
      assert refinement.diff =~ "+"
    end
  end

  describe "approve/1 and reject/1" do
    test "approve sets approved to true" do
      refinement = %{
        session_id: "test",
        prompt_key: :orchestrator,
        current_version: "1",
        candidate_version: "2",
        analysis: "",
        suggestions: [],
        candidate_prompt: "test",
        lab_report: nil,
        diff: "",
        recommendation: :needs_review,
        approved: false
      }

      approved = PromptRefiner.approve(refinement)
      assert approved.approved == true
    end

    test "reject sets recommendation to reject" do
      refinement = %{
        session_id: "test",
        prompt_key: :orchestrator,
        current_version: "1",
        candidate_version: "2",
        analysis: "",
        suggestions: [],
        candidate_prompt: "test",
        lab_report: nil,
        diff: "",
        recommendation: :needs_review,
        approved: false
      }

      rejected = PromptRefiner.reject(refinement)
      assert rejected.approved == false
      assert rejected.recommendation == :reject
    end
  end

  describe "apply/1" do
    test "fails for unapproved refinement" do
      refinement = %{
        approved: false,
        prompt_key: :orchestrator,
        candidate_prompt: "test"
      }

      assert {:error, :not_approved} = PromptRefiner.apply(refinement)
    end

    test "applies approved refinement and triggers reload" do
      # First, set up the store with a known prompt
      Store.write(:worker, "Original worker prompt")

      # Create an approved refinement
      refinement = %{
        approved: true,
        prompt_key: :worker,
        candidate_prompt: "Improved worker prompt with better error handling"
      }

      {:ok, entry} = PromptRefiner.apply(refinement)

      assert entry.content == "Improved worker prompt with better error handling"

      # Verify the file was written
      {:ok, disk} = File.read(Store.path(:worker))
      assert disk == "Improved worker prompt with better error handling"
    end
  end
end
