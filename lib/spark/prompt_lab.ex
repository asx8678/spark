defmodule Spark.PromptLab do
  @moduledoc """
  Prompt experimentation lab — replay Bronze JSONL against candidate prompts.

  `run/3` replays a Bronze JSONL log against a candidate prompt using
  a mock LLM, then produces a comparison report with metrics:

    - tool call count
    - failure count
    - retry count
    - token estimate
    - policy violations

  This is for offline prompt evaluation — no real LLM calls needed.
  """

  @type report :: %{
          log_file: String.t(),
          prompt_file: String.t(),
          tool_call_count: non_neg_integer(),
          failure_count: non_neg_integer(),
          retry_count: non_neg_integer(),
          token_estimate: non_neg_integer(),
          policy_violations: non_neg_integer(),
          notes: [String.t()]
        }

  # --- Public API ---

  @doc """
  Runs a prompt replay experiment.

  - `log_file` — path to a Bronze JSONL session log
  - `prompt_file` — path to a candidate prompt .md file
  - `opts` — options:
    - `:mock_llm_fn` — custom mock function (default: built-in mock)
    - `:policy_fn` — custom policy check fn (default: no-op)

  Returns `{:ok, report}` or `{:error, reason}`.
  """
  @spec run(String.t(), String.t(), keyword()) :: {:ok, report()} | {:error, term()}
  def run(log_file, prompt_file, opts \\ []) do
    with {:ok, entries} <- read_log(log_file),
         {:ok, prompt} <- read_prompt(prompt_file) do
      mock_fn = Keyword.get(opts, :mock_llm_fn, &default_mock_llm/2)
      policy_fn = Keyword.get(opts, :policy_fn, fn _ -> 0 end)

      metrics = replay_entries(entries, prompt, mock_fn, policy_fn)

      report = %{
        log_file: log_file,
        prompt_file: prompt_file,
        tool_call_count: metrics.tool_call_count,
        failure_count: metrics.failure_count,
        retry_count: metrics.retry_count,
        token_estimate: metrics.token_estimate,
        policy_violations: metrics.policy_violations,
        notes: metrics.notes
      }

      {:ok, report}
    end
  end

  @doc """
  Compares two PromptLab reports and returns a diff.
  Lower is better for all metrics except token_estimate (which is informational).
  """
  @spec compare(report(), report()) :: map()
  def compare(baseline, candidate) do
    %{
      tool_call_count: candidate.tool_call_count - baseline.tool_call_count,
      failure_count: candidate.failure_count - baseline.failure_count,
      retry_count: candidate.retry_count - baseline.retry_count,
      token_estimate: candidate.token_estimate - baseline.token_estimate,
      policy_violations: candidate.policy_violations - baseline.policy_violations,
      improved?: candidate.failure_count <= baseline.failure_count and
                 candidate.policy_violations <= baseline.policy_violations,
      baseline: Map.take(baseline, ~w(tool_call_count failure_count retry_count token_estimate policy_violations)a),
      candidate: Map.take(candidate, ~w(tool_call_count failure_count retry_count token_estimate policy_violations)a)
    }
  end

  # --- Private ---

  defp read_log(path) do
    case File.read(path) do
      {:ok, content} ->
        entries =
          content
          |> String.trim_trailing()
          |> String.split("\n")
          |> Enum.map(fn line ->
            case Jason.decode(line) do
              {:ok, entry} -> entry
              {:error, _} -> nil
            end
          end)
          |> Enum.reject(&is_nil/1)

        {:ok, entries}

      {:error, reason} -> {:error, {:log_read_error, reason}}
    end
  end

  defp read_prompt(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, {:prompt_read_error, reason}}
    end
  end

  defp replay_entries(entries, _prompt, mock_fn, policy_fn) do
    initial = %{
      tool_call_count: 0,
      failure_count: 0,
      retry_count: 0,
      token_estimate: 0,
      policy_violations: 0,
      notes: []
    }

    Enum.reduce(entries, initial, fn entry, acc ->
      type = to_string(Map.get(entry, "type", ""))
      _payload = Map.get(entry, "payload", %{})

      # Simulate mock LLM processing
      mock_result = mock_fn.(entry, %{})
      token_cost = estimate_entry_tokens(entry)

      # Check policy violations
      violations = policy_fn.(entry)

      acc
      |> count_tool_calls(type)
      |> count_failures(type)
      |> count_retries(type)
      |> add_tokens(token_cost)
      |> add_policy_violations(violations)
      |> add_note_if_relevant(type, mock_result)
    end)
  end

  defp count_tool_calls(acc, type) when type in ["tool_started", "tool_completed", "tool_failed"] do
    %{acc | tool_call_count: acc.tool_call_count + 1}
  end
  defp count_tool_calls(acc, _type), do: acc

  defp count_failures(acc, "tool_failed") do
    %{acc | failure_count: acc.failure_count + 1}
  end
  defp count_failures(acc, "task_failed") do
    %{acc | failure_count: acc.failure_count + 1}
  end
  defp count_failures(acc, _type), do: acc

  defp count_retries(acc, "task_retried") do
    %{acc | retry_count: acc.retry_count + 1}
  end
  defp count_retries(acc, _type), do: acc

  defp add_tokens(acc, tokens) do
    %{acc | token_estimate: acc.token_estimate + tokens}
  end

  defp add_policy_violations(acc, violations) when is_integer(violations) do
    %{acc | policy_violations: acc.policy_violations + violations}
  end
  defp add_policy_violations(acc, _), do: acc

  defp add_note_if_relevant(acc, type, _result) when type in ["tool_failed", "task_failed", "task_retried"] do
    %{acc | notes: acc.notes ++ ["Event: #{type}"]}
  end
  defp add_note_if_relevant(acc, _type, _result), do: acc

  defp estimate_entry_tokens(entry) do
    entry
    |> Jason.encode!()
    |> byte_size()
    |> div(4)
  rescue
    _ -> 10
  end

  defp default_mock_llm(_entry, _opts) do
    # Default mock always succeeds
    {:ok, %{content: "mock response"}}
  end
end
