defmodule Spark.LLM.Cache do
  @moduledoc """
  Build cache-aware message arrays for LLM prefix caching.

  Splits messages into a static prefix (cacheable across requests)
  and a dynamic suffix (changes per request). The static prefix
  includes system prompts, project rules, and gold memory — content
  that only changes on prompt reload.

  Dynamic content (session history, current input) changes per request
  but must NOT alter the prefix hash.
  """

  @static_categories [:static_prefix, :project_rules, :gold_memory]
  @dynamic_categories [:silver_memory, :session_history, :current_user_input, :worker_result]

  @doc """
  Builds a flat message list from categorized parts, in correct order.

  Order: static_prefix → project_rules → gold_memory → silver_memory →
         session_history → current_user_input → worker_result

  Each part should be a list of `%{role: ..., content: ...}` maps.

  A boundary marker `[spark:dynamic_boundary]` is inserted between
  static and dynamic content. This enables `split_static_dynamic/1`
  and `prefix_hash/1` to work correctly even when dynamic content
  uses the `system` role (e.g., silver_memory summaries).

  Options:
    - `:prompt_version` — version string included in prefix hash calculation
  """
  @spec build_messages(keyword(), keyword()) :: [map()]
  def build_messages(parts, opts \\ []) do
    version = Keyword.get(opts, :prompt_version, "v1")

    static_msgs = build_static(parts)
    dynamic_msgs = build_dynamic(parts)

    messages = []

    messages =
      if static_msgs != [] do
        [%{role: "system", content: "[spark:prefix_version:#{version}]"} | static_msgs]
      else
        messages
      end

    messages =
      if static_msgs != [] and dynamic_msgs != [] do
        messages ++ [%{role: "system", content: "[spark:dynamic_boundary]"}]
      else
        messages
      end

    messages = messages ++ dynamic_msgs
    messages
  end

  @doc """
  Computes a SHA256 hash of the static prefix portion of the messages.

  This hash is stable as long as the static prefix content doesn't change,
  even if dynamic content (session history, user input) changes.
  """
  @spec prefix_hash([map()]) :: String.t()
  def prefix_hash(messages) do
    {static, _dynamic} = split_static_dynamic(messages)

    static
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc """
  Splits a message list at the boundary between static prefix
  and dynamic content.

  Returns `{static_prefix, dynamic_part}`.
  Uses the `[spark:dynamic_boundary]` marker to find the split point.
  """
  @spec split_static_dynamic([map()]) :: {[map()], [map()]}
  def split_static_dynamic(messages) when is_list(messages) do
    case Enum.split_while(messages, fn
      %{role: "system", content: "[spark:dynamic_boundary]"} -> false
      _ -> true
    end) do
      {static, [%{content: "[spark:dynamic_boundary]"} | dynamic]} ->
        {static, dynamic}

      {all, []} ->
        {all, []}
    end
  end

  def split_static_dynamic(_), do: {[], []}

  @doc """
  Returns metadata for cache invalidation.

  Used when prompts reload to bump the prefix version.
  """
  @spec invalidate(atom(), map()) :: {:ok, map()}
  def invalidate(reason, metadata \\ %{}) do
    {:ok, Map.merge(metadata, %{
      invalidated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      reason: reason,
      new_version: "v_#{:erlang.unique_integer([:positive])}"
    })}
  end

  # --- Private ---

  defp build_static(parts) do
    Enum.flat_map(@static_categories, fn key ->
      case Keyword.get(parts, key) do
        nil -> []
        msgs when is_list(msgs) -> msgs
        _ -> []
      end
    end)
  end

  defp build_dynamic(parts) do
    Enum.flat_map(@dynamic_categories, fn key ->
      case Keyword.get(parts, key) do
        nil -> []
        msgs when is_list(msgs) -> msgs
        _ -> []
      end
    end)
  end
end
