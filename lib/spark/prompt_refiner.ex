defmodule Spark.PromptRefiner do
  @moduledoc """
  Analyzes Bronze log failures and suggests prompt improvements.

  Workflow:
    1. Analyze failures from Bronze log
    2. Suggest improvements to the current prompt
    3. Create a candidate prompt incorporating suggestions
    4. Run PromptLab replay for comparison
    5. Produce diff + recommendation
    6. Require approval before replacing the live prompt

  In tests, pass `mock_llm: true` to avoid real LLM calls.
  """

  alias Spark.Memory.Bronze
  alias Spark.Prompt.Store

  @type refinement :: %{
          session_id: String.t(),
          prompt_key: atom(),
          current_version: String.t(),
          candidate_version: String.t(),
          analysis: String.t(),
          suggestions: [String.t()],
          candidate_prompt: String.t(),
          lab_report: map() | nil,
          diff: String.t(),
          recommendation: :approve | :reject | :needs_review,
          approved: boolean()
        }

  # --- Public API ---

  @doc """
  Analyzes a session's Bronze log and produces a prompt refinement.

  Returns `{:ok, refinement}` or `{:error, reason}`.
  """
  @spec refine(String.t(), atom(), keyword()) :: {:ok, refinement()} | {:error, term()}
  def refine(session_id, prompt_key, opts \\ []) when prompt_key in [:orchestrator, :worker, :refiner] do
    mock_llm? = Keyword.get(opts, :mock_llm, false)

    with {:ok, entries} <- Bronze.read(session_id),
         {:ok, analysis} <- analyze_failures(entries, mock_llm?),
         {:ok, suggestions} <- generate_suggestions(analysis, prompt_key, mock_llm?),
         {:ok, candidate} <- create_candidate(prompt_key, suggestions, mock_llm?) do

      current = Store.get(prompt_key)
      current_version = Store.version(prompt_key)

      diff = compute_diff(current, candidate)

      # Run PromptLab if we have a log file
      lab_report = run_lab_if_possible(session_id, prompt_key, candidate, opts)

      recommendation = evaluate_recommendation(lab_report)

      refinement = %{
        session_id: session_id,
        prompt_key: prompt_key,
        current_version: current_version,
        candidate_version: "candidate-#{:erlang.unique_integer([:positive])}",
        analysis: analysis,
        suggestions: suggestions,
        candidate_prompt: candidate,
        lab_report: lab_report,
        diff: diff,
        recommendation: recommendation,
        approved: false
      }

      {:ok, refinement}
    end
  end

  @doc """
  Applies an approved refinement, replacing the prompt and triggering reload.
  Returns `{:ok, updated}` or `{:error, reason}`.

  Raises if the refinement was not approved.
  """
  @spec apply(refinement()) :: {:ok, map()} | {:error, term()}
  def apply(%{approved: false} = _refinement) do
    {:error, :not_approved}
  end

  def apply(%{approved: true, prompt_key: key, candidate_prompt: content}) do
    with {:ok, entry} <- Store.write(key, content) do
      # Trigger hot reload event so all subscribers update
      Spark.EventBus.publish_hot_reload(:prompt_reloaded, %{
        prompt: key,
        version: entry.version,
        hash: entry.hash
      })

      {:ok, entry}
    end
  end

  @doc """
  Marks a refinement as approved. Does NOT apply it yet — call `apply/1`.
  """
  @spec approve(refinement()) :: refinement()
  def approve(refinement), do: %{refinement | approved: true}

  @doc """
  Rejects a refinement.
  """
  @spec reject(refinement()) :: refinement()
  def reject(refinement), do: %{refinement | approved: false, recommendation: :reject}

  # --- Private ---

  defp analyze_failures(entries, true = _mock) do
    failures = filter_failures(entries)
    {:ok, "Found #{length(failures)} failure events. Mock analysis: failures detected in tool execution and task completion."}
  end

  defp analyze_failures(entries, false) do
    failures = filter_failures(entries)
    failure_text = failures |> Enum.map(&Jason.encode!/1) |> Enum.join("\n")

    messages = [
      %{role: "system", content: "Analyze these execution failures and identify root causes. Be specific and actionable."},
      %{role: "user", content: "Failures:\n#{failure_text}"}
    ]

    case Spark.LLM.Client.complete(:prompt_refiner, messages, %{}) do
      {:ok, response} ->
        content = extract_content(response)
        {:ok, content}

      {:error, reason} ->
        {:error, {:analysis_llm_error, reason}}
    end
  end

  defp generate_suggestions(_analysis, prompt_key, true = _mock) do
    {:ok, [
      "Consider adding explicit error handling instructions for #{prompt_key}",
      "Add examples of common failure patterns and recovery steps"
    ]}
  end

  defp generate_suggestions(analysis, prompt_key, false) do
    current = Store.get(prompt_key)

    messages = [
      %{role: "system", content: "Given this failure analysis and current prompt, suggest 3-5 specific improvements. Return as a JSON array of strings."},
      %{role: "user", content: "Analysis:\n#{analysis}\n\nCurrent prompt:\n#{current}"}
    ]

    case Spark.LLM.Client.complete(:prompt_refiner, messages, %{}) do
      {:ok, response} ->
        content = extract_content(response)
        case Jason.decode(content) do
          {:ok, list} when is_list(list) -> {:ok, list}
          {:error, _} -> {:ok, [content]}
        end

      {:error, reason} ->
        {:error, {:suggestions_llm_error, reason}}
    end
  end

  defp create_candidate(prompt_key, suggestions, true = _mock) do
    current = Store.get(prompt_key)
    additions = Enum.map(suggestions, fn s -> "\n- #{s}" end) |> Enum.join()
    candidate = current <> "\n\n## Suggested Improvements\n" <> additions
    {:ok, candidate}
  end

  defp create_candidate(prompt_key, suggestions, false) do
    current = Store.get(prompt_key)
    suggestions_text = Enum.map(suggestions, fn s -> "- #{s}" end) |> Enum.join("\n")

    messages = [
      %{role: "system", content: "Rewrite the given prompt incorporating these improvements. Output the full new prompt only."},
      %{role: "user", content: "Current prompt:\n#{current}\n\nImprovements:\n#{suggestions_text}"}
    ]

    case Spark.LLM.Client.complete(:prompt_refiner, messages, %{}) do
      {:ok, response} ->
        {:ok, extract_content(response)}

      {:error, reason} ->
        {:error, {:candidate_llm_error, reason}}
    end
  end

  defp run_lab_if_possible(session_id, prompt_key, candidate, opts) do
    log_path = Bronze.session_path(session_id)

    if File.exists?(log_path) do
      # Write candidate to a temp file for PromptLab
      tmp_path = Path.join(System.tmp_dir!(), "spark_candidate_#{prompt_key}_#{:erlang.unique_integer([:positive])}.md")
      File.write!(tmp_path, candidate)

      try do
        {:ok, report} = Spark.PromptLab.run(log_path, tmp_path, opts)
        report
      after
        File.rm(tmp_path)
      end
    else
      nil
    end
  rescue
    _ -> nil
  end

  defp evaluate_recommendation(nil), do: :needs_review
  defp evaluate_recommendation(report) do
    if report.failure_count == 0 and report.policy_violations == 0 do
      :approve
    else
      :needs_review
    end
  end

  defp compute_diff(current, candidate) do
    current_lines = String.split(current, "\n")
    candidate_lines = String.split(candidate, "\n")

    diff_lines =
      diff_lists(current_lines, candidate_lines)
      |> Enum.map(fn
        {:equal, line} -> "  #{line}"
        {:add, line} -> "+ #{line}"
        {:remove, line} -> "- #{line}"
      end)
      |> Enum.join("\n")

    diff_lines
  end

  # Simple LCS-based diff
  defp diff_lists(old, new) do
    {result, _} = lcs_diff(old, new, 0, 0, %{})
    result
  end

  defp lcs_diff([], new, _oi, ni, _cache) do
    {Enum.map(new, fn l -> {:add, l} end), ni}
  end

  defp lcs_diff(old, [], _oi, ni, _cache) do
    {Enum.map(old, fn l -> {:remove, l} end), ni}
  end

  defp lcs_diff([h | t1], [h | t2], _oi, ni, _cache) do
    {rest, ni2} = lcs_diff(t1, t2, 0, ni + 1, %{})
    {[{:equal, h} | rest], ni2}
  end

  defp lcs_diff([_h1 | t1] = old, [_h2 | t2] = new, _oi, ni, cache) do
    # Try removing from old
    {remove_result, _} = lcs_diff(t1, new, 0, ni, cache)
    # Try adding from new
    {add_result, _} = lcs_diff(old, t2, 0, ni, cache)

    if length(remove_result) <= length(add_result) do
      {[{:remove, hd(old)} | remove_result], ni}
    else
      {[{:add, hd(new)} | add_result], ni}
    end
  end

  defp filter_failures(entries) do
    Enum.filter(entries, fn entry ->
      type = to_string(Map.get(entry, "type", ""))
      type in ["tool_failed", "task_failed", "llm_call_failed"]
    end)
  end

  defp extract_content(%{choices: [%{message: %{content: content}} | _]}), do: content
  defp extract_content(%{"choices" => [%{"message" => %{"content" => content}} | _]}), do: content
  defp extract_content(content) when is_binary(content), do: content
  defp extract_content(_), do: ""
end
