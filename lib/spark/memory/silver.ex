defmodule Spark.Memory.Silver do
  @moduledoc """
  Silver memory — LLM-compacted summary of Bronze history.

  `compact/2` takes a session_id and history entries, sends them
  to an LLM for summarization, and returns a structured summary.

  The summary preserves:
    - Unresolved issues
    - Architectural decisions
    - User constraints
    - Tool outcomes

  The cached prefix (system prompt) is never compacted.

  Triggers: token threshold exceeded, milestone reached, /compact command.
  In tests, pass `mock_llm: true` or supply a `:llm_fn` to avoid real LLM calls.
  """

  alias Spark.Config
  alias Spark.LLM.Client

  @default_token_threshold 80_000

  @type compact_result :: %{
          session_id: String.t(),
          summary: String.t(),
          unresolved: [String.t()],
          decisions: [String.t()],
          constraints: [String.t()],
          tool_outcomes: [map()],
          compacted_at: String.t(),
          entry_count: non_neg_integer(),
          estimated_tokens: non_neg_integer()
        }

  # --- Public API ---

  @doc """
  Compacts Bronze history into a Silver summary.

  Options:
    - `:llm_fn` — custom function `(messages -> {:ok, response} | {:error, reason})`
    - `:mock_llm` — if true, uses a built-in mock summarizer
    - `:actor_type` — LLM actor type (default: :orchestrator)
  """
  @spec compact(String.t(), [map()], keyword()) ::
          {:ok, compact_result()} | {:error, term()}
  def compact(session_id, history, opts \\ []) do
    if not silver_enabled?() do
      {:error, :silver_disabled}
    else
      llm_fn = resolve_llm_fn(opts)
      actor_type = Keyword.get(opts, :actor_type, :orchestrator)

      estimated_tokens = estimate_tokens(history)
      entry_count = length(history)

      # Build the compaction prompt
      messages = build_compaction_messages(history, session_id)

      case llm_fn.(actor_type, messages, %{}) do
        {:ok, response} ->
          summary_text = extract_content(response)
          result = parse_summary(summary_text, session_id, entry_count, estimated_tokens)
          {:ok, result}

        {:error, reason} ->
          {:error, {:compaction_llm_error, reason}}
      end
    end
  end

  @doc """
  Returns true if the estimated tokens for history exceed the threshold.
  """
  @spec should_compact?([map()], keyword()) :: boolean()
  def should_compact?(history, opts \\ []) do
    threshold = Keyword.get(opts, :threshold, token_threshold())
    estimate_tokens(history) > threshold
  end

  @doc "Returns the token threshold for compaction."
  @spec token_threshold() :: non_neg_integer()
  def token_threshold, do: @default_token_threshold

  @doc "Returns whether Silver compaction is enabled."
  @spec silver_enabled?() :: boolean()
  def silver_enabled? do
    Config.get([:memory, :silver_enabled], true) in [true, "true"]
  end

  # --- Private ---

  defp resolve_llm_fn(opts) do
    cond do
      fn_opt = Keyword.get(opts, :llm_fn) -> fn_opt
      Keyword.get(opts, :mock_llm, false) -> &mock_llm/3
      true -> &Client.complete/3
    end
  end

  defp mock_llm(_actor_type, _messages, _opts) do
    {:ok,
     %{
       id: "mock-compact",
       model: "mock",
       choices: [%{message: %{role: "assistant", content: mock_summary()}}],
       usage: %{prompt_tokens: 100, completion_tokens: 50, total_tokens: 150}
     }}
  end

  defp mock_summary do
    Jason.encode!(%{
      summary: "Mock compaction summary of session history.",
      unresolved: ["Issue: mock-unresolved"],
      decisions: ["Decision: mock-decision"],
      constraints: ["Constraint: mock-constraint"],
      tool_outcomes: [%{tool: "mock_tool", status: "success"}]
    })
  end

  defp build_compaction_messages(history, session_id) do
    # Serialize history for the LLM
    history_text =
      history
      |> Enum.map(&Jason.encode!/1)
      |> Enum.join("\n")

    [
      %{
        role: "system",
        content: """
        You are a memory compaction agent. Summarize the following session history
        into a structured JSON object with these fields:
        - summary: concise paragraph summarizing what happened
        - unresolved: array of unresolved issues or errors
        - decisions: array of architectural decisions made
        - constraints: array of user constraints or preferences
        - tool_outcomes: array of {tool, status, note} objects

        Session ID: #{session_id}
        Respond ONLY with valid JSON. No markdown fences.
        """
      },
      %{
        role: "user",
        content: "History:\n#{history_text}"
      }
    ]
  end

  defp extract_content(%{choices: [%{message: %{content: content}} | _]}), do: content
  defp extract_content(%{"choices" => [%{"message" => %{"content" => content}} | _]}), do: content
  defp extract_content(content) when is_binary(content), do: content
  defp extract_content(_), do: "{}"

  defp parse_summary(text, session_id, entry_count, estimated_tokens) do
    parsed =
      case Jason.decode(text) do
        {:ok, json} ->
          json

        {:error, _} ->
          # Try to extract JSON from markdown fences
          case Regex.run(~r/```json\s*(.*?)\s*```/s, text) do
            [_, json_str] ->
              case Jason.decode(json_str) do
                {:ok, json} -> json
                {:error, _} -> %{"summary" => text}
              end

            _ ->
              %{"summary" => text}
          end
      end

    %{
      session_id: session_id,
      summary: Map.get(parsed, "summary", ""),
      unresolved: Map.get(parsed, "unresolved", []),
      decisions: Map.get(parsed, "decisions", []),
      constraints: Map.get(parsed, "constraints", []),
      tool_outcomes: Map.get(parsed, "tool_outcomes", []),
      compacted_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      entry_count: entry_count,
      estimated_tokens: estimated_tokens
    }
  end

  defp estimate_tokens(history) do
    # Rough estimate: ~4 chars per token
    history
    |> Enum.map(fn entry ->
      entry
      |> Jason.encode!()
      |> byte_size()
    end)
    |> Enum.sum()
    |> div(4)
  end
end
