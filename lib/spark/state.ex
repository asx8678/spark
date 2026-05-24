defmodule Spark.State do
  @moduledoc """
  Orchestrator state struct tracking session, phase, plan, and results.

  Phases: :awaiting_input → :planning → :awaiting_approval → :executing → :reviewing → :completed
  """

  @type phase ::
          :awaiting_input
          | :planning
          | :awaiting_approval
          | :executing
          | :reviewing
          | :completed

  @default_max_history 50
  @compaction_threshold 40

  @type t :: %__MODULE__{
          session_id: String.t(),
          phase: phase(),
          model: String.t() | nil,
          prompt_version: String.t() | nil,
          cached_prefix: [map()],
          cached_prefix_hash: String.t() | nil,
          history: [map()],
          max_history: pos_integer(),
          active_plan: Spark.Types.Plan.t() | nil,
          completed_results: %{String.t() => Spark.Types.WorkerResult.t()},
          failed_results: %{String.t() => Spark.Types.WorkerResult.t()},
          memory_refs: [String.t()],
          schema_version: pos_integer(),
          pending_reply: {pid(), reference()} | nil,
          metadata: map()
        }

  defstruct [
    :session_id,
    :phase,
    :model,
    :prompt_version,
    :cached_prefix,
    :cached_prefix_hash,
    :history,
    :max_history,
    :active_plan,
    :completed_results,
    :failed_results,
    :memory_refs,
    :schema_version,
    :pending_reply,
    :metadata
  ]

  @defaults [
    phase: :awaiting_input,
    cached_prefix: [],
    cached_prefix_hash: nil,
    history: [],
    max_history: @default_max_history,
    active_plan: nil,
    completed_results: %{},
    failed_results: %{},
    memory_refs: [],
    schema_version: 1,
    pending_reply: nil,
    metadata: %{}
  ]

  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    id =
      opts[:session_id] ||
        "sess_" <> Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)

    model = opts[:model] || Spark.Config.get([:llm, :orchestrator_model])
    defaults = Keyword.put(@defaults, :session_id, id)
    defaults = Keyword.put(defaults, :model, model)
    defaults = Keyword.put(defaults, :prompt_version, opts[:prompt_version] || "1")

    struct!(__MODULE__, Keyword.merge(defaults, opts))
  end

  @spec add_result(t(), Spark.Types.WorkerResult.t()) :: t()
  def add_result(state, result) do
    %{
      state
      | completed_results: Map.put(state.completed_results, result.task_id, result),
        failed_results: Map.delete(state.failed_results, result.task_id)
    }
  end

  @spec add_failed(t(), Spark.Types.WorkerResult.t()) :: t()
  def add_failed(state, result) do
    %{
      state
      | failed_results: Map.put(state.failed_results, result.task_id, result),
        completed_results: Map.delete(state.completed_results, result.task_id)
    }
  end

  @spec all_results(t()) :: %{String.t() => Spark.Types.WorkerResult.t()}
  def all_results(state), do: Map.merge(state.completed_results, state.failed_results)

  @spec phase(t()) :: phase()
  def phase(state), do: state.phase

  @doc """
  Adds an entry to history using O(1) prepend with ring-buffer eviction.

  History is stored newest-first. When length exceeds max_history,
  oldest entries (at the tail) are evicted. When history crosses the
  compaction threshold (80% of max), Silver compaction is triggered
  asynchronously to preserve a summary before eviction begins.
  """
  @spec add_history(t(), map()) :: t()
  def add_history(state, entry) do
    old_len = length(state.history)
    max = state.max_history || @default_max_history
    new_history = [entry | state.history] |> trim_to(max)
    state = %{state | history: new_history}
    new_len = length(new_history)

    if new_len >= @compaction_threshold and old_len < @compaction_threshold do
      trigger_silver_compaction(state)
    end

    state
  end

  @doc "Returns history in chronological (oldest-first) order."
  @spec history_chronological(t()) :: [map()]
  def history_chronological(state), do: Enum.reverse(state.history)

  # --- Private ---

  defp trim_to(list, max) when length(list) > max do
    Enum.take(list, max)
  end

  defp trim_to(list, _max), do: list

  defp trigger_silver_compaction(state) do
    session_id = state.session_id
    chronological = Enum.reverse(state.history)

    spawn(fn ->
      try do
        Spark.Memory.Silver.compact(session_id, chronological)
      rescue
        _ -> :ok
      catch
        :exit, _ -> :ok
      end
    end)

    :ok
  end
end
